import AVFoundation
import CoreMedia

enum AudioPreparerError: LocalizedError {
    case noAudioTrack
    case readFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "В выбранном файле нет звуковой дорожки."
        case let .readFailed(reason): return "Не удалось прочитать аудио: \(reason)"
        }
    }
}

/// Decodes any audio/video file macOS understands (m4a, mp3, wav, aiff, flac, mp4, mov…)
/// into a 16 kHz mono 16-bit WAV, measuring frame energies on the way.
enum AudioPreparer {
    static func prepare(source: URL, into directory: URL, progress: @escaping (Double) -> Void) async throws -> PreparedAudio {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioPreparerError.noAudioTrack }
        let duration = (try? await asset.load(.duration).seconds) ?? 0

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioPreparerError.readFailed("неподдерживаемый формат") }
        reader.add(output)
        guard reader.startReading() else {
            throw AudioPreparerError.readFailed(reader.error?.localizedDescription ?? "неизвестная ошибка")
        }

        let wavURL = directory.appendingPathComponent("source.wav")
        FileManager.default.createFile(atPath: wavURL.path, contents: WavFile.header(sampleRate: 16_000, dataBytes: 0))
        let handle = try FileHandle(forWritingTo: wavURL)
        defer { try? handle.close() }
        try handle.seekToEnd()

        var energy = EnergyAccumulator()
        var samples = 0
        var lastReported = -1.0

        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            guard status == noErr else { continue }
            try handle.write(contentsOf: data)
            data.withUnsafeBytes { raw in energy.add(raw.bindMemory(to: Int16.self)) }
            samples += length / 2

            if duration > 0 {
                let p = min(1, Double(samples) / 16_000 / duration)
                if p - lastReported >= 0.01 { lastReported = p; progress(p) }
            }
        }
        if reader.status == .failed {
            throw AudioPreparerError.readFailed(reader.error?.localizedDescription ?? "ошибка декодирования")
        }
        energy.finish()

        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WavFile.header(sampleRate: 16_000, dataBytes: samples * 2))
        progress(1)
        return PreparedAudio(wavURL: wavURL, sampleCount: samples, energies: energy.energies)
    }

    static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration), d.isNumeric else { return nil }
        return d.seconds
    }
}
