import Foundation

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    // Recording
    @Published var captureMicrophone: Bool { didSet { defaults.set(captureMicrophone, forKey: "captureMicrophone") } }
    @Published var captureSystemAudio: Bool { didSet { defaults.set(captureSystemAudio, forKey: "captureSystemAudio") } }
    @Published var audioFormat: AudioFormatOption { didSet { defaults.set(audioFormat.rawValue, forKey: "audioFormat") } }
    @Published var lastSaveDirectory: URL? { didSet { defaults.set(lastSaveDirectory?.path, forKey: "lastSaveDirectory") } }

    // Transcription
    @Published var whisperPath: String { didSet { defaults.set(whisperPath, forKey: "whisperPath"); capabilities = nil } }
    @Published var modelPath: String { didSet { defaults.set(modelPath, forKey: "modelPath") } }
    @Published var useVAD: Bool { didSet { defaults.set(useVAD, forKey: "useVAD") } }
    @Published var recoverGaps: Bool { didSet { defaults.set(recoverGaps, forKey: "recoverGaps") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var transcriptFormat: TranscriptFormat { didSet { defaults.set(transcriptFormat.rawValue, forKey: "transcriptFormat") } }
    @Published var includeTimestamps: Bool { didSet { defaults.set(includeTimestamps, forKey: "includeTimestamps") } }

    @Published private(set) var capabilities: WhisperCapabilities?
    @Published private(set) var isDetecting = false
    @Published private(set) var vadDownloadState: String?

    struct Language: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let languages: [Language] = [
        Language(code: "ru", name: "Русский"), Language(code: "auto", name: "Определять автоматически"), Language(code: "en", name: "English"),
        Language(code: "uk", name: "Українська"), Language(code: "de", name: "Deutsch"), Language(code: "fr", name: "Français"), Language(code: "es", name: "Español"),
        Language(code: "it", name: "Italiano"), Language(code: "kk", name: "Қазақша"), Language(code: "be", name: "Беларуская"), Language(code: "pl", name: "Polski"),
    ]

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ListenAndRecord", isDirectory: true)
    }

    static var vadModelURL: URL { supportDirectory.appendingPathComponent("ggml-silero-v5.1.2.bin") }
    static let vadDownloadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!

    var vadModelInstalled: Bool { FileManager.default.fileExists(atPath: Self.vadModelURL.path) }

    private init() {
        let d = UserDefaults.standard
        captureMicrophone = d.object(forKey: "captureMicrophone") as? Bool ?? true
        captureSystemAudio = d.object(forKey: "captureSystemAudio") as? Bool ?? true
        audioFormat = AudioFormatOption(rawValue: d.string(forKey: "audioFormat") ?? "") ?? .m4a
        lastSaveDirectory = d.string(forKey: "lastSaveDirectory").map { URL(fileURLWithPath: $0) }
        whisperPath = d.string(forKey: "whisperPath") ?? ""
        modelPath = d.string(forKey: "modelPath") ?? ""
        useVAD = d.object(forKey: "useVAD") as? Bool ?? true
        recoverGaps = d.object(forKey: "recoverGaps") as? Bool ?? true
        language = d.string(forKey: "language") ?? "ru"
        transcriptFormat = TranscriptFormat(rawValue: d.string(forKey: "transcriptFormat") ?? "") ?? .docx
        includeTimestamps = d.object(forKey: "includeTimestamps") as? Bool ?? true

        if whisperPath.isEmpty || modelPath.isEmpty {
            Task { await autodetect(onlyMissing: true) }
        }
    }

    var whisperURL: URL? {
        whisperPath.isEmpty || !FileManager.default.isExecutableFile(atPath: whisperPath) ? nil : URL(fileURLWithPath: whisperPath)
    }

    var modelURL: URL? {
        modelPath.isEmpty || !FileManager.default.fileExists(atPath: modelPath) ? nil : URL(fileURLWithPath: modelPath)
    }

    func loadCapabilities() async -> WhisperCapabilities? {
        if let capabilities { return capabilities }
        guard let exe = whisperURL else { return nil }
        let caps = await Task.detached { WhisperCapabilities.probe(executable: exe) }.value
        capabilities = caps
        return caps
    }

    // MARK: - Auto-detection

    func autodetect(onlyMissing: Bool) async {
        guard !isDetecting else { return }
        isDetecting = true
        defer { isDetecting = false }
        let needWhisper = !onlyMissing || whisperURL == nil
        let needModel = !onlyMissing || modelURL == nil
        let found = await Task.detached { () -> (URL?, URL?) in
            (needWhisper ? ExternalTools.find(["whisper-cli", "whisper-cpp"]) : nil,
             needModel ? Self.findModel() : nil)
        }.value
        if let w = found.0 { whisperPath = w.path }
        if let m = found.1 { modelPath = m.path }
        _ = await loadCapabilities()
    }

    nonisolated static func findModel() -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        // Spotlight knows where the user put the model.
        if let out = ExternalTools.run("/usr/bin/mdfind", ["kMDItemFSName == 'ggml-*.bin'"], timeout: 10) {
            candidates += out.split(separator: "\n").map(String.init)
        }
        let dirs = ["\(home)/whisper.cpp/models", "\(home)/Developer/whisper.cpp/models", "\(home)/models",
                    "\(home)/Models", "\(home)/Downloads", "\(home)/.cache/whisper", "\(home)/Library/Application Support/ListenAndRecord",
                    "/opt/homebrew/share/whisper-cpp", "/opt/homebrew/share/whisper-cpp/models", "/usr/local/share/whisper-cpp"]
        for dir in dirs {
            if let items = try? fm.contentsOfDirectory(atPath: dir) {
                candidates += items.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }.map { "\(dir)/\($0)" }
            }
        }
        let models = candidates.filter { fm.fileExists(atPath: $0) && !$0.contains("silero") && !$0.contains("encoder") }
        func score(_ path: String) -> Int {
            let name = (path as NSString).lastPathComponent
            if name == "ggml-large-v3-turbo.bin" { return 100 }
            if name.contains("large-v3-turbo") { return 90 }
            if name.contains("large-v3") { return 80 }
            if name.contains("large") { return 70 }
            if name.contains("medium") { return 50 }
            return 10
        }
        return models.max(by: { score($0) < score($1) }).map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Silero VAD model

    func downloadVADModel() async {
        vadDownloadState = "Скачивание…"
        do {
            let (tmp, response) = try await URLSession.shared.download(from: Self.vadDownloadURL)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            let fm = FileManager.default
            try fm.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            try? fm.removeItem(at: Self.vadModelURL)
            try fm.moveItem(at: tmp, to: Self.vadModelURL)
            vadDownloadState = nil
        } catch {
            vadDownloadState = "Не удалось скачать: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }
}
