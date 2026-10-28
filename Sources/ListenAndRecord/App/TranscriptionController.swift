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
    // Keep cancelled workers until they actually finish: whisper's abort is cooperative.
    private var pendingWork: [UUID: Task<(Transcript, WhisperEngine), Error>] = [:]
    private var engine: WhisperEngine?

    var isRunning: Bool { phase == .running }
    // The cached model owns Metal buffers even when no transcription is running.
    var needsTerminationCleanup: Bool { engine != nil || task != nil || !pendingWork.isEmpty }

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
                guard let model = ModelManager.shared.selectedModelURL else {
                    throw SetupError("Не выбрана модель распознавания. Скачайте или выберите её на вкладке «Модели».")
                }
                let vadURL = ModelManager.vadModelURL
                let useVAD = settings.useVAD && FileManager.default.fileExists(atPath: vadURL.path)
                let options = WhisperDecodeOptions(
                    language: settings.language,
                    threads: max(4, min(8, ProcessInfo.processInfo.activeProcessorCount)),
                    beamSize: settings.highAccuracy ? 5 : 1,
                    vadModelPath: useVAD ? vadURL.path : nil)
                let recover = settings.recoverGaps
                let cached = engine?.modelPath == model.path ? engine : nil
                if cached == nil { stageText = TranscriptionStage.loadingModel.title }
                let workID = UUID()
                let work = Task.detached(priority: .userInitiated) { () -> (Transcript, WhisperEngine) in
                    // Loading a model takes a few seconds; keep it for the next transcription.
                    let engine = try cached ?? WhisperEngine(modelPath: model.path)
                    let pipeline = TranscriptionPipeline(engine: engine, options: options, recoverGaps: recover,
                                                         prepare: AudioPreparer.prepare)
                    let transcript = try await pipeline.run(source: source) { stage in
                        Task { @MainActor in
                            let c = TranscriptionController.shared
                            guard c.isRunning else { return }
                            c.stageText = stage.title
                            c.progress = max(c.progress, stage.fraction)
                        }
                    }
                    return (transcript, engine)
                }
                pendingWork[workID] = work
                defer { pendingWork.removeValue(forKey: workID) }
                // Cancelling the UI task must also stop whisper running in the detached task.
                let (result, usedEngine) = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                engine = usedEngine
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

    /// Do not tear down AppKit/Metal while a detached whisper worker is still using them.
    func stopForTermination() async {
        let currentTask = task
        currentTask?.cancel()
        let workers = Array(pendingWork.values)
        for worker in workers { worker.cancel() }
        await currentTask?.value
        for worker in workers { _ = await worker.result }
        task = nil
        engine = nil
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
