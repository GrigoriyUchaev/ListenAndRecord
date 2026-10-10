import Foundation

/// Locates command-line tools installed by the user (Homebrew etc.).
enum ExternalTools {
    static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "\(home)/.local/bin", "\(home)/bin",
            "\(home)/whisper.cpp/build/bin", "\(home)/whisper.cpp",
            "\(home)/Developer/whisper.cpp/build/bin",
        ]
    }

    static func find(_ names: [String]) -> URL? {
        let fm = FileManager.default
        for dir in searchDirectories {
            for name in names {
                let path = (dir as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        // Fall back to the user's login shell PATH.
        for name in names {
            if let path = run("/bin/zsh", ["-lc", "command -v \(name)"])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, fm.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Runs a short command and returns stdout+stderr, or nil if it could not start.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 15) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let collected = DataBox()
        pipe.fileHandleForReading.readabilityHandler = { h in collected.append(h.availableData) }
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return String(decoding: collected.data, as: UTF8.self)
    }
}

/// Thread-safe byte accumulator for pipe handlers.
final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ d: Data) { lock.locked { storage.append(d) } }
    var data: Data { lock.locked { storage } }
}
