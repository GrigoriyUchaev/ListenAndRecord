import AppKit
import AVFoundation
import Foundation

/// A finished (stopped) recording waiting to be saved.
struct FinishedRecording: Identifiable, Equatable {
    let id = UUID()
    let directory: URL
    let tracks: [URL]
    let duration: Double
    let startedAt: Date
    var savedTo: URL?
}

enum RecorderState: Equatable {
    case idle, starting, recording, paused, stopping
}

@MainActor
final class CallRecorder: ObservableObject {
    static let shared = CallRecorder()

    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published var finished: FinishedRecording?
    @Published var errorMessage: String?
    @Published private(set) var exportProgress: Double?

    private var session: CaptureSession?
    private var timer: Timer?

    var isActive: Bool { state == .recording || state == .paused }
    var hasUnsaved: Bool { finished != nil && finished?.savedTo == nil }

    static var recordingsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ListenAndRecord/Recordings", isDirectory: true)
    }

    private init() {
        finished = Self.findUnsavedRecording()
    }

    // MARK: - Controls

    func start() async {
        guard state == .idle, !hasUnsaved else { return }
        let settings = AppSettings.shared
        errorMessage = nil
        cleanupSaved()
        state = .starting
        do {
            if settings.captureMicrophone { try await Self.ensureMicrophoneAccess() }
            let dir = Self.recordingsRoot.appendingPathComponent(
                "\(TimeFormat.fileStamp()) \(UUID().uuidString.prefix(6))", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let session = CaptureSession(directory: dir)
            session.onError = { [weak self] error in
                Task { @MainActor in self?.errorMessage = "Сбой захвата звука: \(error.localizedDescription)" }
            }
            do {
                try await session.start(microphone: settings.captureMicrophone, systemAudio: settings.captureSystemAudio)
            } catch {
                try? FileManager.default.removeItem(at: dir)
                throw error
            }
            self.session = session
            finished = nil
            elapsed = 0
            state = .recording
            startTimer()
        } catch {
            state = .idle
            errorMessage = error.localizedDescription
        }
    }

    func pause() {
        guard state == .recording else { return }
        session?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        session?.resume()
        state = .recording
    }

    func togglePause() {
        if state == .recording { pause() } else if state == .paused { resume() }
    }

    func stop() async {
        guard isActive, let session else { return }
        state = .stopping
        timer?.invalidate()
        timer = nil
        let duration = await session.stop()
        let tracks = [session.systemWriter?.url, session.micWriter?.url].compactMap { $0 }
        finished = FinishedRecording(directory: session.directory, tracks: tracks,
                                     duration: duration, startedAt: session.startedAt)
        self.session = nil
        micLevel = 0
        systemLevel = 0
        elapsed = duration
        state = .idle
    }

    func discard() {
        guard let finished else { return }
        try? FileManager.default.removeItem(at: finished.directory)
        self.finished = nil
        elapsed = 0
    }

    // MARK: - Saving

    /// Asks where to save, then mixes and encodes. Returns the saved file.
    @discardableResult
    func save(name: String, format: AudioFormatOption) async -> URL? {
        guard let recording = finished, exportProgress == nil else { return nil }
        let settings = AppSettings.shared
        let panel = NSSavePanel()
        panel.title = "Сохранить запись созвона"
        panel.prompt = "Сохранить"
        panel.nameFieldLabel = "Имя файла:"
        panel.nameFieldStringValue = "\(Self.sanitize(name)).\(format.fileExtension)"
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let dir = settings.lastSaveDirectory { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        settings.lastSaveDirectory = url.deletingLastPathComponent()

        exportProgress = 0
        errorMessage = nil
        defer { exportProgress = nil }
        do {
            try await Task.detached(priority: .userInitiated) {
                try AudioExporter.export(tracks: recording.tracks, format: format, to: url) { p in
                    Task { @MainActor in CallRecorder.shared.exportProgress = p }
                }
            }.value
            FileManager.default.createFile(atPath: recording.directory.appendingPathComponent(".saved").path, contents: nil)
            finished?.savedTo = url
            return url
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Созвон \(TimeFormat.fileStamp())" : cleaned
    }

    // MARK: - Helpers

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in CallRecorder.shared.tick() }
        }
    }

    private func tick() {
        guard let session else { return }
        elapsed = session.clock.elapsed()
        let levels = session.levels
        let paused = state == .paused
        micLevel = paused ? 0 : max(levels.mic, micLevel * 0.7)
        systemLevel = paused ? 0 : max(levels.system, systemLevel * 0.7)
    }

    private static func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw RecorderError.microphoneDenied
        default:
            throw RecorderError.microphoneDenied
        }
    }

    /// Recordings already saved can be removed when a new one starts.
    private func cleanupSaved() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Self.recordingsRoot, includingPropertiesForKeys: nil) else { return }
        for dir in dirs where fm.fileExists(atPath: dir.appendingPathComponent(".saved").path) || Self.tracks(in: dir).isEmpty {
            try? fm.removeItem(at: dir)
        }
        finished = nil
    }

    private static func tracks(in dir: URL) -> [URL] {
        ["system.caf", "mic.caf"].map { dir.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// After a crash or quit, offer the last unsaved recording again.
    private static func findUnsavedRecording() -> FinishedRecording? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: recordingsRoot, includingPropertiesForKeys: [.creationDateKey]) else { return nil }
        let candidates = dirs.filter { !fm.fileExists(atPath: $0.appendingPathComponent(".saved").path) && !tracks(in: $0).isEmpty }
        let dated = candidates.map { dir -> (URL, Date) in
            (dir, (try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        guard let latest = dated.max(by: { $0.1 < $1.1 }) else { return nil }
        let (dir, date) = latest
        let tracks = tracks(in: dir)
        let duration = tracks.compactMap { url -> Double? in
            guard let f = try? AVAudioFile(forReading: url) else { return nil }
            return Double(f.length) / f.fileFormat.sampleRate
        }.max() ?? 0
        guard duration > 0.5 else { return nil }
        return FinishedRecording(directory: dir, tracks: tracks, duration: duration, startedAt: date)
    }
}
