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

    var body: some Scene {
        Window("ListenAndRecord", id: "main") {
            ContentView()
                .environmentObject(recorder)
                .environmentObject(transcriber)
                .environmentObject(settings)
                .environmentObject(navigation)
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

extension CallRecorder {
    var menuBarSymbol: String {
        switch state {
        case .recording: return "record.circle.fill"
        case .paused: return "pause.circle.fill"
        default: return "waveform.circle"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let recorder = CallRecorder.shared
        guard recorder.isActive || recorder.hasUnsaved else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = recorder.isActive ? "Идёт запись созвона" : "Запись не сохранена"
        alert.informativeText = recorder.isActive
            ? "Если выйти сейчас, запись будет остановлена. Её можно будет сохранить при следующем запуске."
            : "Несохранённая запись останется и будет предложена при следующем запуске."
        alert.addButton(withTitle: "Отмена")
        alert.addButton(withTitle: "Выйти")
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        if recorder.isActive {
            Task { @MainActor in
                await recorder.stop()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return .terminateNow
    }
}
