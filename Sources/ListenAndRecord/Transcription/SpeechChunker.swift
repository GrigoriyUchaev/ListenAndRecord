import Foundation

/// A contiguous range of samples in the 16 kHz source audio.
struct AudioPiece: Equatable {
    var start: Int
    var length: Int
}

/// A unit of work for Whisper: one or more source pieces glued together.
/// Long silences between pieces are removed, which keeps Whisper from
/// "losing" the conversation after a pause.
struct SpeechChunk {
    var pieces: [AudioPiece]
    var speechRuns: [Range<Int>]       // 10 ms frame ranges inside the source

    var totalSamples: Int { pieces.reduce(0) { $0 + $1.length } }
    var duration: Double { Double(totalSamples) / SpeechChunker.sampleRate }
    var sourceStart: Double { Double(pieces.first?.start ?? 0) / SpeechChunker.sampleRate }
    var sourceEnd: Double {
        guard let p = pieces.last else { return 0 }
        return Double(p.start + p.length) / SpeechChunker.sampleRate
    }

    /// Converts a timestamp inside the chunk file into a timestamp in the source audio.
    func sourceTime(local t: Double) -> Double {
        var remaining = max(0, Int((t * SpeechChunker.sampleRate).rounded()))
        for p in pieces {
            if remaining <= p.length { return Double(p.start + remaining) / SpeechChunker.sampleRate }
            remaining -= p.length
        }
        return sourceEnd
    }
}

enum SpeechChunker {
    static let sampleRate = 16_000.0
    static let frameSamples = 160          // 10 ms
    static let framesPerSecond = 100

    /// Conservative energy-based voice activity detection. It is tuned to never drop
    /// quiet speech: it only removes clearly silent stretches. Fine-grained filtering
    /// is left to Whisper's own Silero VAD.
    /// - Parameter energies: RMS (0...1) of consecutive 10 ms frames.
    static func detectSpeech(energies: [Float]) -> [Range<Int>] {
        let n = energies.count
        guard n > 0 else { return [] }
        let db = energies.map { 20 * log10(max(Double($0), 1e-7)) }
        let audible = db.filter { $0 > -90 }.sorted()
        guard audible.count >= 10 else { return [] }
        func percentile(_ p: Double) -> Double { audible[min(audible.count - 1, Int(Double(audible.count - 1) * p))] }
        let noise = percentile(0.10)
        let loud = percentile(0.95)
        guard loud > -75 else { return [] }
        // Little dynamic range: cannot tell speech from background reliably — keep everything audible.
        if loud - noise < 10 {
            guard let first = db.firstIndex(where: { $0 > -90 }), let last = db.lastIndex(where: { $0 > -90 }) else { return [] }
            return [first..<(last + 1)]
        }
        let threshold = noise + min(15, max(6, (loud - noise) * 0.25))

        var raw: [Range<Int>] = []
        var i = 0
        while i < n {
            if db[i] > threshold {
                let s = i
                while i < n && db[i] > threshold { i += 1 }
                if i - s >= 5 { raw.append(s..<i) }        // ignore clicks < 50 ms
            } else {
                i += 1
            }
        }

        let padBefore = 25, padAfter = 45, mergeGap = 30   // frames
        var merged: [Range<Int>] = []
        for r in raw {
            let p = max(0, r.lowerBound - padBefore)..<min(n, r.upperBound + padAfter)
            if let last = merged.last, p.lowerBound - last.upperBound <= mergeGap {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, p.upperBound)
            } else {
                merged.append(p)
            }
        }
        return merged
    }

    /// Splits runs longer than `maxFrames` at the quietest moment found between
    /// `minFrames` and `maxFrames` from the run's start.
    static func splitLongRuns(_ runs: [Range<Int>], energies: [Float], maxFrames: Int, minFrames: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        let window = 20
        for r in runs {
            var start = r.lowerBound
            while r.upperBound - start > maxFrames {
                let lo = start + minFrames
                let hi = min(start + maxFrames, energies.count)
                var best = hi
                var bestEnergy = Float.greatestFiniteMagnitude
                var f = lo
                while f + window <= hi {
                    var sum: Float = 0
                    for k in f..<(f + window) { sum += energies[k] }
                    if sum < bestEnergy { bestEnergy = sum; best = f + window / 2 }
                    f += 5
                }
                if best <= start { best = min(start + maxFrames, r.upperBound) }
                out.append(start..<best)
                start = best
            }
            if start < r.upperBound { out.append(start..<r.upperBound) }
        }
        return out
    }

    /// Groups speech runs into chunks of at most `maxSeconds`, preferring to cut at
    /// long pauses. Pauses longer than `keepGapSeconds` are cut out of the chunk audio.
    static func makeChunks(runs: [Range<Int>],
                           totalSamples: Int,
                           maxSeconds: Double,
                           splitGapSeconds: Double,
                           minSecondsBeforeGapSplit: Double,
                           keepGapSeconds: Double = 1.2) -> [SpeechChunk] {
        let fps = Double(framesPerSecond)
        var chunks: [SpeechChunk] = []
        var current: [Range<Int>] = []

        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(build(current, totalSamples: totalSamples, keepGapSeconds: keepGapSeconds))
            current = []
        }

        for r in runs {
            if let first = current.first, let last = current.last {
                let gap = Double(r.lowerBound - last.upperBound) / fps
                let span = Double(r.upperBound - first.lowerBound) / fps
                let currentSpan = Double(last.upperBound - first.lowerBound) / fps
                if span > maxSeconds || (gap >= splitGapSeconds && currentSpan >= minSecondsBeforeGapSplit) {
                    flush()
                }
            }
            current.append(r)
        }
        flush()
        return chunks.filter { $0.totalSamples > Int(0.2 * sampleRate) }
    }

    private static func build(_ runs: [Range<Int>], totalSamples: Int, keepGapSeconds: Double) -> SpeechChunk {
        var pieces: [AudioPiece] = []
        var previousEnd: Int?
        for r in runs {
            let s = min(r.lowerBound * frameSamples, totalSamples)
            let e = min(r.upperBound * frameSamples, totalSamples)
            guard e > s else { continue }
            if let pe = previousEnd, !pieces.isEmpty, Double(s - pe) / sampleRate <= keepGapSeconds {
                pieces[pieces.count - 1].length = e - pieces[pieces.count - 1].start
            } else {
                pieces.append(AudioPiece(start: s, length: e - s))
            }
            previousEnd = e
        }
        return SpeechChunk(pieces: pieces, speechRuns: runs)
    }

    /// Heuristic detector of the "Whisper stopped transcribing" failure: too few words for
    /// the amount of speech, or a long stretch of the chunk with no text at all.
    static func looksIncomplete(_ segments: [TranscriptSegment], chunkDuration: Double) -> Bool {
        guard chunkDuration >= 8 else { return false }
        let words = segments.reduce(0) { $0 + $1.wordCount }
        if Double(words) < chunkDuration * 0.5 { return true }
        var cursor = 0.0
        for s in segments.sorted(by: { $0.start < $1.start }) {
            if s.start - cursor > 8 { return true }
            cursor = max(cursor, s.end)
        }
        return chunkDuration - cursor > 8
    }
}

/// Computes RMS energy of consecutive 10 ms frames while audio is streamed through.
struct EnergyAccumulator {
    private(set) var energies: [Float] = []
    private var sum: Double = 0
    private var count = 0
    let frameSize: Int

    init(frameSize: Int = SpeechChunker.frameSamples) { self.frameSize = frameSize }

    mutating func add<C: Collection>(_ samples: C) where C.Element == Int16 {
        for s in samples {
            let v = Double(s) / 32768
            sum += v * v
            count += 1
            if count == frameSize { flushFrame() }
        }
    }

    mutating func finish() { if count > 0 { flushFrame() } }

    private mutating func flushFrame() {
        energies.append(Float((sum / Double(count)).squareRoot()))
        sum = 0
        count = 0
    }
}
