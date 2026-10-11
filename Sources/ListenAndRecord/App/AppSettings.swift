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
    @Published var useVAD: Bool { didSet { defaults.set(useVAD, forKey: "useVAD") } }
    @Published var recoverGaps: Bool { didSet { defaults.set(recoverGaps, forKey: "recoverGaps") } }
    @Published var highAccuracy: Bool { didSet { defaults.set(highAccuracy, forKey: "highAccuracy") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var transcriptFormat: TranscriptFormat { didSet { defaults.set(transcriptFormat.rawValue, forKey: "transcriptFormat") } }
    @Published var includeTimestamps: Bool { didSet { defaults.set(includeTimestamps, forKey: "includeTimestamps") } }

    struct Language: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    static let languages: [Language] = [
        Language(code: "ru", name: "Русский"), Language(code: "auto", name: "Определять автоматически"),
        Language(code: "en", name: "English"), Language(code: "uk", name: "Українська"),
        Language(code: "de", name: "Deutsch"), Language(code: "fr", name: "Français"),
        Language(code: "es", name: "Español"), Language(code: "it", name: "Italiano"),
        Language(code: "kk", name: "Қазақша"), Language(code: "be", name: "Беларуская"),
        Language(code: "pl", name: "Polski"),
    ]

    private init() {
        let d = UserDefaults.standard
        captureMicrophone = d.object(forKey: "captureMicrophone") as? Bool ?? true
        captureSystemAudio = d.object(forKey: "captureSystemAudio") as? Bool ?? true
        audioFormat = AudioFormatOption(rawValue: d.string(forKey: "audioFormat") ?? "") ?? .m4a
        lastSaveDirectory = d.string(forKey: "lastSaveDirectory").map { URL(fileURLWithPath: $0) }
        useVAD = d.object(forKey: "useVAD") as? Bool ?? true
        recoverGaps = d.object(forKey: "recoverGaps") as? Bool ?? true
        highAccuracy = d.object(forKey: "highAccuracy") as? Bool ?? true
        language = d.string(forKey: "language") ?? "ru"
        transcriptFormat = TranscriptFormat(rawValue: d.string(forKey: "transcriptFormat") ?? "") ?? .docx
        includeTimestamps = d.object(forKey: "includeTimestamps") as? Bool ?? true
    }
}
