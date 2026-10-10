import Foundation

/// Minimal helpers for 16-bit PCM WAV files (the format whisper.cpp expects).
enum WavFile {
    static let headerSize = 44

    static func header(sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16, dataBytes: Int) -> Data {
        var d = Data(capacity: headerSize)
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        d.append(contentsOf: Array("RIFF".utf8))
        d.appendLE(UInt32(truncatingIfNeeded: 36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.appendLE(UInt32(16))
        d.appendLE(UInt16(1)) // PCM
        d.appendLE(UInt16(channels))
        d.appendLE(UInt32(sampleRate))
        d.appendLE(UInt32(byteRate))
        d.appendLE(UInt16(blockAlign))
        d.appendLE(UInt16(bitsPerSample))
        d.append(contentsOf: Array("data".utf8))
        d.appendLE(UInt32(truncatingIfNeeded: dataBytes))
        return d
    }
}

/// Random access to the samples of a 16 kHz mono 16-bit WAV written by `AudioPreparer`.
final class WavSliceReader {
    let url: URL
    let sampleCount: Int
    private let handle: FileHandle

    init(url: URL, sampleCount: Int) throws {
        self.url = url
        self.sampleCount = sampleCount
        self.handle = try FileHandle(forReadingFrom: url)
    }

    deinit { try? handle.close() }

    func samples(start: Int, length: Int) throws -> Data {
        let s = max(0, min(start, sampleCount))
        let e = max(s, min(start + length, sampleCount))
        try handle.seek(toOffset: UInt64(WavFile.headerSize + s * 2))
        return try handle.read(upToCount: (e - s) * 2) ?? Data()
    }

    /// Writes the concatenation of `pieces` as a standalone WAV file.
    func write(pieces: [AudioPiece], to destination: URL, sampleRate: Int = 16_000) throws {
        var body = Data()
        for piece in pieces {
            body.append(try samples(start: piece.start, length: piece.length))
        }
        var file = WavFile.header(sampleRate: sampleRate, dataBytes: body.count)
        file.append(body)
        try file.write(to: destination, options: .atomic)
    }
}

extension Data {
    mutating func appendLE(_ value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
