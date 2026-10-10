import AVFoundation

/// Writes one audio source (mic or system) to a CAF file in a fixed format
/// (48 kHz mono float), placing every buffer at its timeline position so that
/// gaps become silence and both tracks line up.
final class TrackWriter: @unchecked Sendable {
    static let sampleRate: Double = 48_000
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    let url: URL
    private let clock: RecordingClock
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private let silence: AVAudioPCMBuffer
    private var rms: Float = 0

    init(url: URL, clock: RecordingClock) throws {
        self.url = url
        self.clock = clock
        file = try AVAudioFile(forWriting: url, settings: Self.format.settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        silence = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 48_000)!
        silence.frameLength = silence.frameCapacity
        memset(silence.floatChannelData![0], 0, Int(silence.frameCapacity) * MemoryLayout<Float>.size)
    }

    /// Current input level (RMS, 0...1), for the UI meters.
    var level: Float { lock.locked { rms } }

    func append(_ buffer: AVAudioPCMBuffer, hostTime: Double) {
        let now = HostClock.now()
        // Guard against timestamps from an unexpected clock.
        let t = abs(hostTime - now) > 2 ? now : hostTime
        guard let position = clock.position(forHostTime: t) else {
            lock.locked { rms = 0 }
            return
        }
        lock.locked {
            guard let file, let converted = convert(buffer), converted.frameLength > 0 else { return }
            rms = Self.rms(converted)
            let target = AVAudioFramePosition(position * Self.sampleRate)
            let tolerance = AVAudioFramePosition(0.1 * Self.sampleRate)
            if target - framesWritten > tolerance {
                writeSilence(frames: target - framesWritten, to: file)
            } else if framesWritten - target > tolerance {
                return // device clock running ahead: drop a buffer to stay in sync
            }
            do {
                try file.write(from: converted)
                framesWritten += AVAudioFramePosition(converted.frameLength)
            } catch {
                NSLog("ListenAndRecord: write failed: \(error)")
            }
        }
    }

    /// Pads the track to `duration` seconds and closes the file.
    func finish(duration: Double) {
        lock.locked {
            guard let file else { return }
            let target = AVAudioFramePosition(duration * Self.sampleRate)
            if target > framesWritten { writeSilence(frames: target - framesWritten, to: file) }
            self.file = nil
        }
    }

    private func writeSilence(frames: AVAudioFramePosition, to file: AVAudioFile) {
        var remaining = frames
        while remaining > 0 {
            let n = AVAudioFrameCount(min(remaining, AVAudioFramePosition(silence.frameCapacity)))
            silence.frameLength = n
            do { try file.write(from: silence) } catch { return }
            framesWritten += AVAudioFramePosition(n)
            remaining -= AVAudioFramePosition(n)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let target = Self.format
        if buffer.format == target { return buffer }
        if converter == nil || converterSource != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
            converterSource = buffer.format
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : out
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}
