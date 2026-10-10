import AVFoundation
import UniformTypeIdentifiers

enum AudioFormatOption: String, CaseIterable, Identifiable {
    case m4a, mp3, wav

    var id: String { rawValue }
    var fileExtension: String { rawValue }

    var title: String {
        switch self {
        case .m4a: return "M4A (AAC) — компактный, отличное качество"
        case .mp3: return "MP3 — открывается везде"
        case .wav: return "WAV — без сжатия, максимальное качество"
        }
    }

    var utType: UTType {
        switch self {
        case .m4a: return .mpeg4Audio
        case .mp3: return .mp3
        case .wav: return .wav
        }
    }
}

enum ExportError: LocalizedError {
    case noTracks
    case mp3EncoderMissing
    case encoderFailed(String)

    var errorDescription: String? {
        switch self {
        case .noTracks: return "Запись пуста."
        case .mp3EncoderMissing:
            return "Для сохранения в MP3 нужен кодировщик lame или ffmpeg. Установите его командой в Терминале: brew install lame"
        case let .encoderFailed(log): return "Ошибка кодирования MP3: \(log)"
        }
    }
}

/// Mixes the microphone and system tracks into one file in the chosen format.
enum AudioExporter {
    static var mp3Encoder: URL? { ExternalTools.find(["lame", "ffmpeg"]) }

    static func export(tracks: [URL], format: AudioFormatOption, to destination: URL,
                       progress: @escaping (Double) -> Void) throws {
        guard !tracks.isEmpty else { throw ExportError.noTracks }
        let fm = FileManager.default
        var mp3Encoder: URL?
        if format == .mp3 {
            mp3Encoder = Self.mp3Encoder
            guard mp3Encoder != nil else { throw ExportError.mp3EncoderMissing }
        }

        let target: URL
        if format == .mp3 {
            target = fm.temporaryDirectory.appendingPathComponent("ListenAndRecord-\(UUID().uuidString).wav")
        } else {
            target = destination
        }
        try? fm.removeItem(at: target)
        defer { if format == .mp3 { try? fm.removeItem(at: target) } }

        let mixProgress: (Double) -> Void = { progress(format == .mp3 ? $0 * 0.6 : $0) }
        try mix(tracks: tracks, into: target, settings: settings(for: format), progress: mixProgress)

        if let encoder = mp3Encoder {
            try? fm.removeItem(at: destination)
            try encodeMP3(wav: target, to: destination, encoder: encoder)
        }
        progress(1)
    }

    private static func settings(for format: AudioFormatOption) -> [String: Any] {
        switch format {
        case .m4a:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: TrackWriter.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        case .wav, .mp3:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: TrackWriter.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
    }

    /// Two passes: find the peak of the sum, then write the sum with a gain that brings
    /// quiet recordings up and keeps loud ones from clipping.
    private static func mix(tracks: [URL], into destination: URL, settings: [String: Any],
                            progress: (Double) -> Void) throws {
        let format = TrackWriter.format
        let chunk: AVAudioFrameCount = 48_000
        func openAll() throws -> [AVAudioFile] {
            try tracks.map { try AVAudioFile(forReading: $0, commonFormat: .pcmFormatFloat32, interleaved: false) }
        }
        var files = try openAll()
        let total = files.map(\.length).max() ?? 0
        guard total > 0 else { throw ExportError.noTracks }
        let readBuffers = files.map { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)! }
        let mixBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!

        func readMixed(at done: AVAudioFramePosition) throws -> AVAudioFrameCount {
            let n = AVAudioFrameCount(min(AVAudioFramePosition(chunk), total - done))
            let mix = mixBuffer.floatChannelData![0]
            memset(mix, 0, Int(n) * MemoryLayout<Float>.size)
            for (i, file) in files.enumerated() where file.framePosition < file.length {
                let buffer = readBuffers[i]
                try file.read(into: buffer, frameCount: min(n, AVAudioFrameCount(file.length - file.framePosition)))
                let src = buffer.floatChannelData![0]
                for k in 0..<Int(buffer.frameLength) { mix[k] += src[k] }
            }
            mixBuffer.frameLength = n
            return n
        }

        // Pass 1: peak.
        var peak: Float = 0
        var done: AVAudioFramePosition = 0
        while done < total {
            let n = try readMixed(at: done)
            let mix = mixBuffer.floatChannelData![0]
            for k in 0..<Int(n) { peak = max(peak, abs(mix[k])) }
            done += AVAudioFramePosition(n)
            progress(0.3 * Double(done) / Double(total))
        }
        let gain: Float = peak > 0 ? min(4, 0.89 / peak) : 1  // ≈ -1 dBFS ceiling

        // Pass 2: write.
        files = try openAll()
        let output = try AVAudioFile(forWriting: destination, settings: settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        done = 0
        while done < total {
            let n = try readMixed(at: done)
            let mix = mixBuffer.floatChannelData![0]
            for k in 0..<Int(n) { mix[k] = max(-1, min(1, mix[k] * gain)) }
            try output.write(from: mixBuffer)
            done += AVAudioFramePosition(n)
            progress(0.3 + 0.7 * Double(done) / Double(total))
        }
    }

    private static func encodeMP3(wav: URL, to destination: URL, encoder: URL) throws {
        let args: [String]
        if encoder.lastPathComponent == "lame" {
            args = ["--silent", "-b", "128", "-m", "m", wav.path, destination.path]
        } else {
            args = ["-y", "-loglevel", "error", "-i", wav.path, "-codec:a", "libmp3lame", "-b:a", "128k", destination.path]
        }
        let log = ExternalTools.run(encoder.path, args, timeout: 3600) ?? ""
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw ExportError.encoderFailed(log.isEmpty ? "кодировщик не создал файл" : log)
        }
    }
}
