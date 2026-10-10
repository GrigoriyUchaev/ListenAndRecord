import Foundation

struct WhisperCapabilities {
    var supportsVAD = false
    var supportsSuppressNST = false
    var supportsMaxContext = true
    var versionLine = ""

    static func probe(executable: URL) -> WhisperCapabilities {
        let help = ExternalTools.run(executable.path, ["--help"], timeout: 10) ?? ""
        var caps = WhisperCapabilities()
        caps.supportsVAD = help.contains("--vad-model")
        caps.supportsSuppressNST = help.contains("--suppress-nst")
        caps.supportsMaxContext = help.contains("--max-context")
        caps.versionLine = help.split(separator: "\n").first.map(String.init) ?? ""
        return caps
    }
}

struct WhisperSettings {
    var executable: URL
    var model: URL
    var vadModel: URL?          // nil = Silero VAD off
    var language: String        // "auto", "ru", "en", ...
    var threads: Int
    var capabilities: WhisperCapabilities
}

enum WhisperError: LocalizedError {
    case failed(status: Int32, log: String)
    case missingOutput(String)

    var errorDescription: String? {
        switch self {
        case let .failed(status, log):
            return "whisper завершился с ошибкой (код \(status)).\n\(log)"
        case let .missingOutput(name):
            return "whisper не создал результат для \(name)."
        }
    }
}

/// Runs whisper.cpp's `whisper-cli` on a batch of WAV files with settings chosen to
/// avoid losing speech after pauses.
final class WhisperRunner {
    let settings: WhisperSettings

    init(settings: WhisperSettings) { self.settings = settings }

    /// Transcribes each file independently. Returns segments in file-local time.
    /// - Parameter onFileDone: called with the number of finished files.
    func transcribe(files: [URL], useVAD: Bool, onFileDone: @escaping (Int) -> Void) async throws -> [[TranscriptSegment]] {
        var results: [[TranscriptSegment]] = []
        let batchSize = 16 // one model load per batch
        var done = 0
        for batchStart in stride(from: 0, to: files.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(files[batchStart..<min(batchStart + batchSize, files.count)])
            let base = done
            try await run(batch: batch, useVAD: useVAD) { started in
                // whisper announces a file when it starts it, so the previous one is done.
                onFileDone(base + max(0, started - 1))
            }
            for file in batch {
                results.append(try Self.readOutput(for: file))
            }
            done += batch.count
            onFileDone(done)
        }
        return results
    }

    func arguments(for batch: [URL], useVAD: Bool) -> [String] {
        let caps = settings.capabilities
        var args = [
            "-m", settings.model.path,
            "-l", settings.language,
            "-t", String(settings.threads),
            "-bs", "5",          // beam search: more accurate
            "-bo", "5",
            "-oj", "-otxt",
        ]
        // Do not condition on previously decoded text: this is the main reason Whisper
        // gets stuck or skips the rest of the audio after a pause.
        if caps.supportsMaxContext { args += ["-mc", "0"] }
        if caps.supportsSuppressNST { args += ["-sns"] }
        if useVAD, caps.supportsVAD, let vad = settings.vadModel {
            // Softer than the defaults so quiet speech is not discarded.
            args += ["--vad", "--vad-model", vad.path,
                     "--vad-threshold", "0.4",
                     "--vad-min-silence-duration-ms", "300",
                     "--vad-speech-pad-ms", "200"]
        }
        for f in batch { args += ["-f", f.path] }
        return args
    }

    private func run(batch: [URL], useVAD: Bool, onFileStarted: @escaping (Int) -> Void) async throws {
        let process = Process()
        process.executableURL = settings.executable
        process.arguments = arguments(for: batch, useVAD: useVAD)
        process.standardInput = FileHandle.nullDevice
        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe

        let log = LineCollector()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in log.append(data) where line.contains("processing '") {
                onFileStarted(log.markFileStarted())
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        errPipe.fileHandleForReading.readabilityHandler = nil
        outPipe.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()
        if status != 0 {
            throw WhisperError.failed(status: status, log: log.tail(lines: 15))
        }
    }

    static func readOutput(for file: URL) throws -> [TranscriptSegment] {
        let fm = FileManager.default
        let jsonCandidates = [URL(fileURLWithPath: file.path + ".json"), file.deletingPathExtension().appendingPathExtension("json")]
        for url in jsonCandidates where fm.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url), let segments = parseJSON(data) { return segments }
        }
        let txtCandidates = [URL(fileURLWithPath: file.path + ".txt"), file.deletingPathExtension().appendingPathExtension("txt")]
        for url in txtCandidates where fm.fileExists(atPath: url.path) {
            let text = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
                .split(separator: "\n").joined(separator: " ")
            return text.isEmpty ? [] : [TranscriptSegment(start: 0, end: 0, text: text)]
        }
        throw WhisperError.missingOutput(file.lastPathComponent)
    }

    static func parseJSON(_ raw: Data) -> [TranscriptSegment]? {
        // whisper may emit invalid UTF-8 when a token splits a character; repair it first.
        let data = Data(String(decoding: raw, as: UTF8.self).utf8)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["transcription"] as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let text = item["text"] as? String else { return nil }
            let offsets = item["offsets"] as? [String: Any]
            let from = (offsets?["from"] as? NSNumber)?.doubleValue ?? 0
            let to = (offsets?["to"] as? NSNumber)?.doubleValue ?? from
            return TranscriptSegment(start: from / 1000, end: to / 1000,
                                     text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

/// Splits streamed bytes into lines and keeps a bounded tail for error reporting.
final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var lines: [String] = []
    private var filesStarted = 0

    /// Counts "processing 'file'" announcements; returns the new count.
    func markFileStarted() -> Int {
        lock.locked { filesStarted += 1; return filesStarted }
    }

    func append(_ data: Data) -> [String] {
        lock.locked {
            pending.append(data)
            var newLines: [String] = []
            while let idx = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<idx]
                pending.removeSubrange(pending.startIndex...idx)
                newLines.append(String(decoding: lineData, as: UTF8.self))
            }
            lines.append(contentsOf: newLines)
            if lines.count > 200 { lines.removeFirst(lines.count - 200) }
            return newLines
        }
    }

    func tail(lines n: Int) -> String {
        lock.locked {
            (lines + [String(decoding: pending, as: UTF8.self)])
                .filter { !$0.isEmpty }.suffix(n).joined(separator: "\n")
        }
    }
}
