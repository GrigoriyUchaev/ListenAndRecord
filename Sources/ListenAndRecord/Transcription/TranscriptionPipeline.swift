import Foundation

enum TranscriptionStage {
    case loadingModel
    case preparing(Double)
    case transcribing(done: Int, total: Int)
    case recovering(done: Int, total: Int)

    var title: String {
        switch self {
        case .loadingModel: return "Загрузка модели…"
        case .preparing: return "Подготовка аудио…"
        case let .transcribing(done, total): return "Распознавание речи: фрагмент \(min(done + 1, total)) из \(total)"
        case let .recovering(done, total): return "Проверка пропусков: повторное распознавание \(min(done + 1, total)) из \(total)"
        }
    }

    var fraction: Double {
        switch self {
        case .loadingModel: return 0
        case let .preparing(p): return 0.08 * p
        case let .transcribing(done, total): return 0.08 + 0.84 * Double(done) / Double(max(total, 1))
        case let .recovering(done, total): return 0.92 + 0.08 * Double(done) / Double(max(total, 1))
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

    let engine: WhisperEngine
    let options: WhisperDecodeOptions
    let recoverGaps: Bool
    private let prepare: Prepare
    private let cancel = CancelFlag()

    init(engine: WhisperEngine, options: WhisperDecodeOptions, recoverGaps: Bool, prepare: @escaping Prepare) {
        self.engine = engine
        self.options = options
        self.recoverGaps = recoverGaps
        self.prepare = prepare
    }

    func run(source: URL, progress: @escaping (TranscriptionStage) -> Void) async throws -> Transcript {
        try await withTaskCancellationHandler {
            try await self.runInner(source: source, progress: progress)
        } onCancel: {
            self.cancel.cancel()
        }
    }

    private func runInner(source: URL, progress: @escaping (TranscriptionStage) -> Void) async throws -> Transcript {
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
        var local: [[TranscriptSegment]] = []
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(.transcribing(done: i, total: chunks.count))
            let samples = try reader.floats(pieces: chunk.pieces)
            local.append(TranscriptCleaner.clean(try engine.transcribe(samples, options: options, cancel: cancel)))
        }
        progress(.transcribing(done: chunks.count, total: chunks.count))

        var perChunk: [[TranscriptSegment]] = zip(chunks, local).map { chunk, segs in
            segs.map { toSource($0, through: chunk) }
        }

        if recoverGaps {
            let suspicious = chunks.indices.filter { SpeechChunker.looksIncomplete(local[$0], chunkDuration: chunks[$0].duration) }
            for (n, i) in suspicious.enumerated() {
                try Task.checkCancellation()
                progress(.recovering(done: n, total: suspicious.count))
                if let better = try retranscribe(chunks[i], reader: reader, energies: audio.energies, current: perChunk[i]) {
                    perChunk[i] = better
                }
            }
        }

        let segments = TranscriptCleaner.clean(perChunk.flatMap { $0 }.sorted { $0.start < $1.start })
        return Transcript(sourceName: source.lastPathComponent, duration: audio.duration,
                          language: options.language, segments: segments)
    }

    /// Re-runs a suspicious chunk as several short pieces without VAD. The result is kept
    /// only if it recovers noticeably more speech.
    private func retranscribe(_ chunk: SpeechChunk, reader: WavSliceReader, energies: [Float],
                              current: [TranscriptSegment]) throws -> [TranscriptSegment]? {
        let runs = SpeechChunker.splitLongRuns(chunk.speechRuns, energies: energies, maxFrames: 15 * 100, minFrames: 8 * 100)
        let subChunks = SpeechChunker.makeChunks(runs: runs, totalSamples: reader.sampleCount,
                                                 maxSeconds: 20, splitGapSeconds: 1.0, minSecondsBeforeGapSplit: 5)
        guard !subChunks.isEmpty else { return nil }
        var noVAD = options
        noVAD.vadModelPath = nil
        var candidate: [TranscriptSegment] = []
        for sub in subChunks {
            try Task.checkCancellation()
            let segs = try engine.transcribe(try reader.floats(pieces: sub.pieces), options: noVAD, cancel: cancel)
            candidate += TranscriptCleaner.clean(segs).map { toSource($0, through: sub) }
        }
        let before = current.reduce(0) { $0 + $1.wordCount }
        let after = candidate.reduce(0) { $0 + $1.wordCount }
        return Double(after) > Double(before) * 1.15 + 3 ? candidate : nil
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
