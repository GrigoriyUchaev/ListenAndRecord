import AppKit
import SwiftUI

enum AppTab: Hashable {
    case record, transcribe, settings
}

@MainActor
final class NavigationModel: ObservableObject {
    static let shared = NavigationModel()
    @Published var tab: AppTab = .record
}

@main
struct ListenAndRecordApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = CallRecorder.shared
    @StateObject private var transcriber = TranscriptionController.shared
    @StateObject private var settings = AppSettings.shared
    @StateObject private var navigation = NavigationModel.shared
    @StateObject private var models = ModelManager.shared

    init() {
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        Window("ListenAndRecord", id: "main") {
            MainWindowContent(appDelegate: appDelegate)
                .environmentObject(recorder)
                .environmentObject(transcriber)
                .environmentObject(settings)
                .environmentObject(navigation)
                .environmentObject(models)
                .frame(minWidth: 620, minHeight: 640)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Запись") {
                Button("Начать запись") { Task { await recorder.start() } }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(recorder.isActive || recorder.hasUnsaved)
                Button(recorder.state == .paused ? "Продолжить" : "Пауза") { recorder.togglePause() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!recorder.isActive)
                Button("Остановить") { Task { await recorder.stop() } }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(!recorder.isActive)
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(recorder)
        } label: {
            Image(systemName: recorder.menuBarSymbol)
        }
    }
}

/// Keep SwiftUI's window-opening action available even after the window is closed.
private struct MainWindowContent: View {
    let appDelegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView()
            .onAppear {
                let open = openWindow
                appDelegate.openMainWindow = {
                    open(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }
}

extension CallRecorder {
    var menuBarSymbol: String {
        switch state {
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        default: return "megaphone"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?
    private var terminationTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LifecycleSelfTest.runIfRequested(delegate: self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Closing the window must leave recording and the menu bar available.
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow?()
        return false // SwiftUI recreates the single main window, including when none remain.
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        let recorder = CallRecorder.shared
        if recorder.isActive || recorder.hasUnsaved {
            let alert = NSAlert()
            alert.messageText = recorder.isActive ? "Идёт запись созвона" : "Запись не сохранена"
            alert.informativeText = recorder.isActive
                ? "Если выйти сейчас, запись будет остановлена. Её можно будет сохранить при следующем запуске."
                : "Несохранённая запись останется и будет предложена при следующем запуске."
            alert.addButton(withTitle: "Отмена")
            alert.addButton(withTitle: "Выйти")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        let transcriber = TranscriptionController.shared
        if recorder.isActive || transcriber.needsTerminationCleanup {
            terminationTask = Task { @MainActor in
                await recorder.stop()
                await transcriber.stopForTermination()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}
