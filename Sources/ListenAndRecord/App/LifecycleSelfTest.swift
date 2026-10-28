import AppKit
import Foundation

/// Exercises the real SwiftUI window and AppKit delegate on the macOS CI runner.
@MainActor
enum LifecycleSelfTest {
    static func runIfRequested(delegate: AppDelegate) {
        guard CommandLine.arguments.contains("--lifecycle-selftest") else { return }
        Task { @MainActor in
            do {
                try await waitUntil { delegate.openMainWindow != nil && mainWindows.contains(where: { $0.isVisible }) }
                guard !delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp) else {
                    throw SetupError("Closing the window would terminate the application")
                }
                for _ in 0..<3 {
                    guard let window = mainWindows.first(where: { $0.isVisible }) else {
                        throw SetupError("Main window is missing")
                    }
                    window.performClose(nil)
                    try await waitUntil { !mainWindows.contains(where: { $0.isVisible }) }

                    // Use NSApp's installed delegate, just as the Dock reopen event does.
                    _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
                    try await waitUntil { mainWindows.contains(where: { $0.isVisible }) }
                    _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: true)
                    try await Task.sleep(nanoseconds: 200_000_000)
                    guard mainWindows.filter({ $0.isVisible }).count == 1 else {
                        throw SetupError("Reopening created duplicate main windows")
                    }
                }

                let args = CommandLine.arguments
                if let index = args.firstIndex(of: "--lifecycle-selftest"), args.count > index + 1 {
                    guard args.count == index + 3 else {
                        throw SetupError("Expected model and audio paths")
                    }
                    let models = ModelManager.shared
                    let settings = AppSettings.shared
                    let oldPath = models.selectedPath
                    let oldLanguage = settings.language
                    let oldVAD = settings.useVAD
                    do {
                        defer {
                            models.selectedPath = oldPath
                            settings.language = oldLanguage
                            settings.useVAD = oldVAD
                        }
                        models.selectedPath = args[index + 1]
                        settings.language = "en"
                        settings.useVAD = false
                        let transcriber = TranscriptionController.shared
                        transcriber.select(URL(fileURLWithPath: args[index + 2]))
                        transcriber.start()
                        try await waitUntil(timeoutSeconds: 180) {
                            switch transcriber.phase {
                            case .finished, .failed: return true
                            default: return false
                            }
                        }
                        guard transcriber.phase == .finished,
                              let transcript = transcriber.transcript,
                              TranscriptExporter.plainText(transcript, timestamps: false).lowercased().contains("country") else {
                            throw SetupError("Lifecycle transcription failed: \(transcriber.phase)")
                        }
                        // Also cover the case where Cancel clears the UI task handle but
                        // the cached model still owns Metal residency sets (the reported crash).
                        transcriber.cancel()
                        guard transcriber.needsTerminationCleanup else {
                            throw SetupError("Cached model is missing from termination cleanup")
                        }
                        FileHandle.standardOutput.write(Data("LIFECYCLE: transcription completed with cached model\n".utf8))
                    }
                }

                mainWindows.first(where: { $0.isVisible })?.performClose(nil)
                try await waitUntil { !mainWindows.contains(where: { $0.isVisible }) }
                FileHandle.standardOutput.write(Data("LIFECYCLE: close/reopen passed; requesting normal quit\n".utf8))
                NSApp.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("LIFECYCLE ERROR: \(error)\n".utf8))
                exit(1)
            }
        }
    }

    private static var mainWindows: [NSWindow] {
        NSApp.windows.filter { $0.title == "ListenAndRecord" && $0.canBecomeMain }
    }

    private static func waitUntil(timeoutSeconds: Int = 10, _ condition: () -> Bool) async throws {
        for _ in 0..<(timeoutSeconds * 20) {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw SetupError("Timed out waiting for the main window")
    }
}
