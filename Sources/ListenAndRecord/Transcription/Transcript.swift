import Foundation

struct TranscriptSegment: Equatable {
    var start: Double   // seconds
    var end: Double
    var text: String

    var wordCount: Int { TranscriptCleaner.wordCount(text) }
}

struct Transcript {
    var sourceName: String
    var duration: Double
    var language: String
    var createdAt = Date()
    var segments: [TranscriptSegment]

    struct Paragraph {
        var start: Double
        var text: String
    }

    /// Groups segments into readable paragraphs: a new paragraph starts after a pause
    /// or when the current one grows too long.
    func paragraphs(pause: Double = 2.0, maxCharacters: Int = 700) -> [Paragraph] {
        var result: [Paragraph] = []
        var current: Paragraph?
        var lastEnd = 0.0
        for seg in segments {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var p = current {
                let longPause = seg.start - lastEnd >= pause
                let tooLong = p.text.count >= maxCharacters && Self.endsSentence(p.text)
                if longPause || tooLong {
                    result.append(p)
                    current = Paragraph(start: seg.start, text: text)
                } else {
                    p.text += " " + text
                    current = p
                }
            } else {
                current = Paragraph(start: seg.start, text: text)
            }
            lastEnd = max(lastEnd, seg.end)
        }
        if let p = current { result.append(p) }
        return result
    }

    var plainText: String { paragraphs().map(\.text).joined(separator: "\n\n") }

    private static func endsSentence(_ s: String) -> Bool {
        guard let c = s.last else { return false }
        return ".!?…".contains(c)
    }
}

/// Removes typical Whisper artefacts: hallucinated captions in silence, loops of the
/// same phrase, and non-speech annotations.
enum TranscriptCleaner {
    private static let hallucinationMarkers = [
        "субтитр", "dimatorzok", "amara.org", "продолжение следует",
        "спасибо за просмотр", "подписывайтесь на канал", "ставьте лайк",
        "редактор субтитров", "корректор а.", "thanks for watching",
        "thank you for watching", "please subscribe", "like and subscribe",
    ]

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    static func normalized(_ text: String) -> String {
        let lowered = text.lowercased()
        let kept = lowered.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "." ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    static func isAnnotationOnly(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first, let last = t.last else { return true }
        if "[(*♪".contains(first) && "])*♪".contains(last) { return true }
        return !t.contains(where: { $0.isLetter || $0.isNumber })
    }

    static func isHallucination(_ text: String) -> Bool {
        let n = normalized(text)
        guard wordCount(text) <= 14 else { return false }
        return hallucinationMarkers.contains { n.contains($0) }
    }

    /// - Parameter collapseLoops: drop a phrase repeated 3+ times back to back. Only safe within one
    ///   Whisper call: across chunks the same words can legitimately recur (e.g. "Да." … "Да.").
    static func clean(_ segments: [TranscriptSegment], collapseLoops: Bool = true) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var repeatCount = 0
        for var seg in segments {
            seg.text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if seg.text.isEmpty || isAnnotationOnly(seg.text) || isHallucination(seg.text) { continue }
            if collapseLoops, let prev = out.last, seg.start - prev.end < 1.5,
               normalized(prev.text) == normalized(seg.text) {
                repeatCount += 1
                // A phrase repeated 3+ times in a row is a decoding loop, not speech.
                if repeatCount >= 2 { out[out.count - 1].end = max(prev.end, seg.end); continue }
            } else {
                repeatCount = 0
            }
            out.append(seg)
        }
        return out
    }
}
