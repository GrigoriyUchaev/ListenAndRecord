import AppKit
import Foundation
import UniformTypeIdentifiers

/// A Whisper model from the official whisper.cpp collection on Hugging Face.
struct WhisperModelInfo: Identifiable, Equatable {
    let id: String              // e.g. "large-v3-turbo"
    let title: String
    let sizeMB: Int
    let note: String
    var fileName: String { "ggml-\(id).bin" }
    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")! }
    var sizeText: String { sizeMB >= 1000 ? String(format: "%.1f ГБ", Double(sizeMB) / 1024) : "\(sizeMB) МБ" }
}

/// Downloads, imports and selects Whisper models. Everything is stored locally;
/// the internet is needed only once to download a model.
@MainActor
final class ModelManager: NSObject, ObservableObject {
    static let shared = ModelManager()

    static let catalog: [WhisperModelInfo] = [
        .init(id: "large-v3-turbo", title: "Large v3 Turbo", sizeMB: 1624,
              note: "Рекомендуется для Mac M1–M4: высокая точность и быстро."),
        .init(id: "large-v3-turbo-q5_0", title: "Large v3 Turbo (сжатая)", sizeMB: 574,
              note: "Почти та же точность, в 3 раза меньше места и памяти."),
        .init(id: "large-v3", title: "Large v3", sizeMB: 3095,
              note: "Максимальная точность, в 3–4 раза медленнее Turbo."),
        .init(id: "large-v3-q5_0", title: "Large v3 (сжатая)", sizeMB: 1081,
              note: "Максимальная точность при меньшем размере."),
        .init(id: "medium", title: "Medium", sizeMB: 1533, note: "Хорошая точность, средняя скорость."),
        .init(id: "small", title: "Small", sizeMB: 488, note: "Быстрая, точность заметно ниже."),
        .init(id: "base", title: "Base", sizeMB: 148, note: "Очень быстрая, только для пробы."),
    ]

    nonisolated static let vadFileName = "ggml-silero-v5.1.2.bin"
    nonisolated static let vadURL = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!

    @Published var selectedPath: String { didSet { UserDefaults.standard.set(selectedPath, forKey: "selectedModelPath") } }
    @Published private(set) var customPaths: [String] { didSet { UserDefaults.standard.set(customPaths, forKey: "customModelPaths") } }
    @Published private(set) var foundOnDisk: [String] = []
    @Published private(set) var downloads: [String: Double] = [:]   // id -> progress
    @Published var downloadError: String?
    @Published private(set) var revision = 0                        // bumps when files change

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    nonisolated static var modelsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ListenAndRecord/Models", isDirectory: true)
    }

    nonisolated static var vadModelURL: URL { modelsDirectory.appendingPathComponent(vadFileName) }

    private override init() {
        let d = UserDefaults.standard
        selectedPath = d.string(forKey: "selectedModelPath") ?? ""
        customPaths = d.stringArray(forKey: "customModelPaths") ?? []
        super.init()
        try? FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
        // Migrate the model chosen in version 1 (external whisper-cli setup).
        if selectedPath.isEmpty, let old = d.string(forKey: "modelPath"), FileManager.default.fileExists(atPath: old) {
            addCustom(path: old)
        }
        if selectedModelURL == nil { selectFirstAvailable() }
        Task { await scanDisk() }
    }

    // MARK: - State

    func localURL(for model: WhisperModelInfo) -> URL { Self.modelsDirectory.appendingPathComponent(model.fileName) }

    func isInstalled(_ model: WhisperModelInfo) -> Bool { FileManager.default.fileExists(atPath: localURL(for: model).path) }

    struct InstalledModel: Identifiable, Equatable {
        let title: String
        let path: String
        var id: String { path }
    }

    var installedModels: [InstalledModel] {
        _ = revision
        var list = Self.catalog.filter(isInstalled).map { InstalledModel(title: $0.title, path: localURL(for: $0).path) }
        for p in customPaths where FileManager.default.fileExists(atPath: p) {
            list.append(InstalledModel(title: (p as NSString).lastPathComponent, path: p))
        }
        return list
    }

    var selectedModelURL: URL? {
        selectedPath.isEmpty || !FileManager.default.fileExists(atPath: selectedPath) ? nil : URL(fileURLWithPath: selectedPath)
    }

    var selectedTitle: String {
        installedModels.first(where: { $0.path == selectedPath })?.title ?? "не выбрана"
    }

    var vadInstalled: Bool { _ = revision; return FileManager.default.fileExists(atPath: Self.vadModelURL.path) }

    private func selectFirstAvailable() {
        if let first = installedModels.first { selectedPath = first.path }
    }

    // MARK: - Import

    func addCustom(path: String) {
        if !customPaths.contains(path) { customPaths.append(path) }
        selectedPath = path
        revision += 1
    }

    func removeCustom(path: String) {
        customPaths.removeAll { $0 == path }
        if selectedPath == path { selectedPath = ""; selectFirstAvailable() }
        revision += 1
    }

    func importFile() {
        let panel = NSOpenPanel()
        panel.title = "Выберите файл модели Whisper (ggml-*.bin)"
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { addCustom(path: url.path) }
    }

    /// Finds ggml models already on the Mac (for example from a previous whisper.cpp install).
    func scanDisk() async {
        let known = Set(installedModels.map(\.path))
        let found = await Task.detached { () -> [String] in
            let out = ExternalTools.run("/usr/bin/mdfind", ["kMDItemFSName == 'ggml-*.bin'"], timeout: 10) ?? ""
            return out.split(separator: "\n").map(String.init)
                .filter { !$0.contains("silero") && !$0.contains("encoder") && !$0.contains("/.Trash/") }
        }.value
        foundOnDisk = found.filter { !known.contains($0) && !$0.hasPrefix(Self.modelsDirectory.path) }
    }

    // MARK: - Download

    func download(_ model: WhisperModelInfo) { start(id: model.id, url: model.url) }
    func downloadVAD() { start(id: "vad", url: Self.vadURL) }

    func cancelDownload(id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        downloads[id] = nil
    }

    func delete(_ model: WhisperModelInfo) {
        try? FileManager.default.removeItem(at: localURL(for: model))
        if selectedPath == localURL(for: model).path { selectedPath = ""; selectFirstAvailable() }
        revision += 1
    }

    private func start(id: String, url: URL) {
        guard tasks[id] == nil else { return }
        downloadError = nil
        let task = session.downloadTask(with: url)
        task.taskDescription = id
        tasks[id] = task
        downloads[id] = 0
        task.resume()
    }

    private func destination(for id: String) -> URL {
        if id == "vad" { return Self.vadModelURL }
        let model = Self.catalog.first { $0.id == id }!
        return localURL(for: model)
    }

    fileprivate func finished(id: String, error: String?) {
        tasks[id] = nil
        downloads[id] = nil
        if let error { downloadError = error }
        if id != "vad", error == nil, selectedModelURL == nil || selectedPath.isEmpty {
            selectedPath = destination(for: id).path
        }
        revision += 1
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor in
            if ModelManager.shared.downloads[id] != nil { ModelManager.shared.downloads[id] = p }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        var error: String?
        if status != 200 {
            error = "Сервер вернул ошибку \(status)."
        } else {
            // The temporary file disappears when this method returns: move it synchronously.
            let dest: URL = id == "vad"
                ? Self.vadModelURL
                : Self.modelsDirectory.appendingPathComponent("ggml-\(id).bin")
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: location, to: dest)
            } catch let e {
                error = e.localizedDescription
            }
        }
        Task { @MainActor in ModelManager.shared.finished(id: id, error: error) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        let message = "Не удалось скачать: \(error.localizedDescription)"
        Task { @MainActor in ModelManager.shared.finished(id: id, error: message) }
    }
}
