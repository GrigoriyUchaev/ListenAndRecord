import Foundation

enum TranscriptionStage {
    case preparing(Double)
    case transcribing(done: Int, total: Int)
    case recovering(done: Int, total: Int)

    var title: String {
        switch self {
        case .preparing: return "Подготовка аудио…"
        case let .transcribing(done, total): return "Распознавание речи: фрагмент \(min(done + 1, total)) из \(total)"
        case let .recovering(done, total): return "Проверка пропусков: повторное распознавание \(min(done + 1, total)) из \(total)"
        }
    }

    var fraction: Double {
        switch self {
        case let .preparing(p): return 0.1 * p
        case let .transcribing(done, total): return 0.1 + 0.8 * Double(done) / Double(max(total, 1))
        case let .recovering(done, total): return 0.9 + 0.1 * Double(done) / Double(max(total, 1))
        }
    }
}

enum TranscriptionError: LocalizedError {
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .noSpeech: return "В файле не найдено речи (или он пустой)."
        }
    }
}

/// Full pipeline: decode → split at pauses → whisper → detect & re-run lost fragments → clean up.
final class TranscriptionPipeline {
    typealias Prepare = (_ source: URL, _ workDirectory: URL, _ progress: @escaping (Double) -> Void) async throws -> PreparedAudio

    let whisper: WhisperRunner
    let useVAD: Bool
    let recoverGaps: Bool
    private let prepare: Prepare

    init(whisper: WhisperRunner, useVAD: Bool, recoverGaps: Bool, prepare: @escaping Prepare) {
        self.whisper = whisper
        self.useVAD = useVAD
        self.recoverGaps = recoverGaps
        self.prepare = prepare
    }

    func run(source: URL, progress: @escaping (TranscriptionStage) -> Void) async throws -> Transcript {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("ListenAndRecord-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let audio = try await prepare(source, work) { progress(.preparing($0)) }
        try Task.checkCancellation()

        var runs = SpeechChunker.detectSpeech(energies: audio.energies)
        guard !runs.isEmpty else { throw TranscriptionError.noSpeech }
        runs = SpeechChunker.splitLongRuns(runs, energies: audio.energies, maxFrames: 30 * 100, minFrames: 15 * 100)
        let chunks = SpeechChunker.makeChunks(runs: runs, totalSamples: audio.sampleCount,
                                              maxSeconds: 60, splitGapSeconds: 2.0, minSecondsBeforeGapSplit: 15)
        guard !chunks.isEmpty else { throw TranscriptionError.noSpeech }

        let reader = try WavSliceReader(url: audio.wavURL, sampleCount: audio.sampleCount)
        let files = try write(chunks, prefix: "chunk", into: work, reader: reader)

        progress(.transcribing(done: 0, total: chunks.count))
        let local = try await whisper.transcribe(files: files, useVAD: useVAD) { done in
            progress(.transcribing(done: done, total: chunks.count))
        }

        var perChunk: [[TranscriptSegment]] = zip(chunks, local).map { chunk, segs in
            TranscriptCleaner.clean(segs).map { toSource($0, through: chunk) }
        }

        if recoverGaps {
            let suspicious = chunks.indices.filter { i in
                SpeechChunker.looksIncomplete(TranscriptCleaner.clean(local[i]), chunkDuration: chunks[i].duration)
            }
            for (n, i) in suspicious.enumerated() {
                try Task.checkCancellation()
                progress(.recovering(done: n, total: suspicious.count))
                if let better = try await retranscribe(chunks[i], index: i, into: work, reader: reader, energies: audio.energies,
                                                        current: perChunk[i]) {
                    perChunk[i] = better
                }
            }
        }

        let segments = TranscriptCleaner.clean(perChunk.flatMap { $0 }.sorted { $0.start < $1.start })
        return Transcript(sourceName: source.lastPathComponent, duration: audio.duration,
                          language: whisper.settings.language, segments: segments)
    }

    /// Re-runs a suspicious chunk as several short pieces without VAD. The result is kept
    /// only if it recovers noticeably more speech.
    private func retranscribe(_ chunk: SpeechChunk, index: Int, into work: URL, reader: WavSliceReader,
                              energies: [Float], current: [TranscriptSegment]) async throws -> [TranscriptSegment]? {
        let runs = SpeechChunker.splitLongRuns(chunk.speechRuns, energies: energies, maxFrames: 15 * 100, minFrames: 8 * 100)
        let subChunks = SpeechChunker.makeChunks(runs: runs, totalSamples: reader.sampleCount,
                                                 maxSeconds: 20, splitGapSeconds: 1.0, minSecondsBeforeGapSplit: 5)
        guard subChunks.count > 0 else { return nil }
        let files = try write(subChunks, prefix: "retry\(index)", into: work, reader: reader)
        let local = try await whisper.transcribe(files: files, useVAD: false) { _ in }
        let candidate = zip(subChunks, local).flatMap { sub, segs in TranscriptCleaner.clean(segs).map { toSource($0, through: sub) } }
        let before = current.reduce(0) { $0 + $1.wordCount }
        let after = candidate.reduce(0) { $0 + $1.wordCount }
        return Double(after) > Double(before) * 1.15 + 3 ? candidate : nil
    }

    private func write(_ chunks: [SpeechChunk], prefix: String, into dir: URL, reader: WavSliceReader) throws -> [URL] {
        try chunks.enumerated().map { i, chunk in
            let url = dir.appendingPathComponent("\(prefix)_\(String(format: "%04d", i)).wav")
            try reader.write(pieces: chunk.pieces, to: url)
            return url
        }
    }

    private func toSource(_ s: TranscriptSegment, through chunk: SpeechChunk) -> TranscriptSegment {
        TranscriptSegment(start: chunk.sourceTime(local: s.start), end: chunk.sourceTime(local: s.end), text: s.text)
    }
}

struct PreparedAudio {
    var wavURL: URL          // 16 kHz mono 16-bit
    var sampleCount: Int
    var energies: [Float]    // RMS per 10 ms
    var duration: Double { Double(sampleCount) / SpeechChunker.sampleRate }
}
