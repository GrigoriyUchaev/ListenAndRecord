import AVFoundation
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case microphoneDenied
    case noMicrophone
    case screenCaptureDenied(String)
    case noDisplay
    case nothingToRecord

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Нет доступа к микрофону. Разрешите его в Системных настройках → Конфиденциальность и безопасность → Микрофон."
        case .noMicrophone:
            return "Микрофон не найден."
        case let .screenCaptureDenied(reason):
            return "Нет доступа к записи системного звука (\(reason)). Разрешите ListenAndRecord в Системных настройках → Конфиденциальность и безопасность → «Запись экрана и системного звука», затем перезапустите приложение."
        case .noDisplay:
            return "Не найден дисплей для захвата звука."
        case .nothingToRecord:
            return "Выберите хотя бы один источник: микрофон или звук созвона."
        }
    }
}

/// One recording: system audio via ScreenCaptureKit (everything other participants say,
/// from any app — Zoom, Meet, Telegram, FaceTime…) plus the local microphone.
final class CaptureSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let directory: URL
    let clock = RecordingClock()
    let startedAt = Date()
    private(set) var micWriter: TrackWriter?
    private(set) var systemWriter: TrackWriter?

    private var engine: AVAudioEngine?
    private var engineObserver: NSObjectProtocol?
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "ListenAndRecord.system-audio", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "ListenAndRecord.video-ignored", qos: .background)

    var onError: ((Error) -> Void)?

    init(directory: URL) {
        self.directory = directory
    }

    func start(microphone: Bool, systemAudio: Bool) async throws {
        guard microphone || systemAudio else { throw RecorderError.nothingToRecord }
        clock.start()
        do {
            if systemAudio { try await startSystemAudio() }
            if microphone { try startMicrophone() }
        } catch {
            await stop()
            throw error
        }
    }

    func pause() { clock.pause() }
    func resume() { clock.resume() }

    var levels: (mic: Float, system: Float) {
        (micWriter?.level ?? 0, systemWriter?.level ?? 0)
    }

    /// Stops capture and finalises both files. Returns the recorded duration.
    @discardableResult
    func stop() async -> Double {
        let duration = clock.elapsed()
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        if let engineObserver {
            NotificationCenter.default.removeObserver(engineObserver)
            self.engineObserver = nil
        }
        micWriter?.finish(duration: duration)
        systemWriter?.finish(duration: duration)
        return duration
    }

    // MARK: - System audio

    private func startSystemAudio() async throws {
        if !CGPreflightScreenCaptureAccess() {
            // Registers the app in System Settings and shows the system prompt.
            _ = CGRequestScreenCaptureAccess()
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecorderError.screenCaptureDenied(error.localizedDescription)
        }
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video is required by the API but unused: keep it as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        systemWriter = try TrackWriter(url: directory.appendingPathComponent("system.caf"), clock: clock)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        do {
            try await stream.startCapture()
        } catch {
            throw RecorderError.screenCaptureDenied(error.localizedDescription)
        }
        self.stream = stream
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let writer = systemWriter,
              let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        writer.append(pcm, hostTime: pts.isNumeric ? pts.seconds : HostClock.now())
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    // MARK: - Microphone

    private func startMicrophone() throws {
        let writer = try TrackWriter(url: directory.appendingPathComponent("mic.caf"), clock: clock)
        micWriter = writer
        let engine = AVAudioEngine()
        try installTap(on: engine, writer: writer)
        engine.prepare()
        try engine.start()
        self.engine = engine
        // Headphones plugged in / AirPods connected: the engine stops and must be rebuilt.
        engineObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.restartMicrophone()
        }
    }

    private func installTap(on engine: AVAudioEngine, writer: TrackWriter) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in
            let host = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : HostClock.now()
            writer.append(buffer, hostTime: host)
        }
    }

    private func restartMicrophone() {
        guard let engine, let writer = micWriter else { return }
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTap(on: engine, writer: writer)
            engine.prepare()
            try engine.start()
        } catch {
            onError?(error)
        }
    }
}
