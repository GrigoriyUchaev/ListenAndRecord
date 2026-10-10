import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class TranscriptionController: ObservableObject {
    static let shared = TranscriptionController()

    enum Phase: Equatable {
        case idle, running, finished, failed(String)
    }

    @Published private(set) var inputURL: URL?
    @Published private(set) var inputDuration: Double?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var stageText = ""
    @Published private(set) var progress: Double = 0
    @Published private(set) var transcript: Transcript?
    @Published private(set) var savedURL: URL?
    @Published private(set) var startedAt: Date?

    private var task: Task<Void, Never>?

    var isRunning: Bool { phase == .running }

    func select(_ url: URL) {
        guard !isRunning else { return }
        inputURL = url
        inputDuration = nil
        transcript = nil
        savedURL = nil
        phase = .idle
        Task {
            let d = await AudioPreparer.duration(of: url)
            if inputURL == url { inputDuration = d }
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Выберите аудио- или видеофайл"
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let dir = AppSettings.shared.lastSaveDirectory { panel.directoryURL = dir }
        if panel.runModal() == .OK, let url = panel.url { select(url) }
    }

    func start() {
        guard let source = inputURL, !isRunning else { return }
        let settings = AppSettings.shared
        task = Task {
            phase = .running
            progress = 0
            stageText = "Запуск…"
            transcript = nil
            savedURL = nil
            startedAt = Date()
            do {
                guard let exe = settings.whisperURL else {
                    throw SetupError("Не найден whisper-cli. Укажите путь на вкладке «Настройки» (установка: brew install whisper-cpp).")
                }
                guard let model = settings.modelURL else {
                    throw SetupError("Не найдена модель Whisper (например, ggml-large-v3-turbo.bin). Укажите её на вкладке «Настройки».")
                }
                guard let caps = await settings.loadCapabilities() else { throw SetupError("Не удалось запустить whisper-cli.") }
                let vad = settings.useVAD && settings.vadModelInstalled && caps.supportsVAD
                let whisper = WhisperRunner(settings: WhisperSettings(
                    executable: exe, model: model,
                    vadModel: vad ? AppSettings.vadModelURL : nil,
                    language: settings.language,
                    threads: max(4, min(8, ProcessInfo.processInfo.activeProcessorCount)),
                    capabilities: caps))
                let pipeline = TranscriptionPipeline(whisper: whisper, useVAD: vad, recoverGaps: settings.recoverGaps,
                                                     prepare: AudioPreparer.prepare)
                let work = Task.detached(priority: .userInitiated) {
                    try await pipeline.run(source: source) { stage in
                        Task { @MainActor in
                            let c = TranscriptionController.shared
                            guard c.isRunning else { return }
                            c.stageText = stage.title
                            c.progress = max(c.progress, stage.fraction)
                        }
                    }
                }
                // Cancelling the UI task must also stop whisper running in the detached task.
                let result = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                transcript = result
                progress = 1
                phase = .finished
                stageText = "Готово"
            } catch is CancellationError {
                phase = .idle
                stageText = "Отменено"
            } catch {
                phase = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        stageText = "Отменено"
    }

    func save(format: TranscriptFormat, timestamps: Bool) {
        guard let transcript, let source = inputURL else { return }
        let panel = NSSavePanel()
        panel.title = "Сохранить расшифровку"
        panel.prompt = "Сохранить"
        panel.nameFieldLabel = "Имя файла:"
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent + "." + format.fileExtension
        let type: UTType = format == .txt ? .plainText : (UTType(filenameExtension: "docx") ?? .data)
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.directoryURL = source.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TranscriptExporter.data(for: transcript, format: format, timestamps: timestamps).write(to: url, options: .atomic)
            savedURL = url
        } catch {
            phase = .failed("Не удалось сохранить файл: \(error.localizedDescription)")
        }
    }
}

struct SetupError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
