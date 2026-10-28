import AppKit
import SwiftUI

struct MenuBarView: View {
    let showMainWindow: () -> Void
    @EnvironmentObject private var recorder: CallRecorder

    var body: some View {
        Group {
            switch recorder.state {
            case .recording, .paused:
                Text("\(recorder.state == .paused ? "Пауза" : "Запись") · \(TimeFormat.clock(recorder.elapsed))")
                Button(recorder.state == .paused ? "Продолжить" : "Пауза") { recorder.togglePause() }
                Button("Остановить") {
                    Task {
                        await recorder.stop()
                        showWindow()
                    }
                }
            default:
                Button("Начать запись") { Task { await recorder.start() } }
                    .disabled(recorder.hasUnsaved)
                if recorder.hasUnsaved {
                    Text("Есть несохранённая запись")
                }
            }
            Divider()
            Button("Открыть окно ListenAndRecord") { showWindow() }
            Button("Выйти") { NSApp.terminate(nil) }
        }
    }

    private func showWindow() {
        showMainWindow()
    }
}
