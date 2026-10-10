import AppKit
import SwiftUI

struct RecordView: View {
    @EnvironmentObject private var recorder: CallRecorder
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var transcriber: TranscriptionController
    @EnvironmentObject private var navigation: NavigationModel
    // Plain ObservableObject instead of @State: in newer SDKs @State is a macro whose
    // plugin ships only with full Xcode, so Command Line Tools builds would fail.
    @StateObject private var form = RecordFormState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                statusCard
                sourcesCard
                if let finished = recorder.finished, !recorder.isActive {
                    saveCard(finished)
                }
                if let error = recorder.errorMessage {
                    errorCard(error)
                }
                tips
            }
            .padding(8)
        }
        .onAppear { if form.fileName.isEmpty { form.fileName = defaultName } }
        .onChange(of: recorder.finished?.id) { _, _ in form.fileName = defaultName }
    }

    private var defaultName: String {
        "Созвон \(TimeFormat.fileStamp(recorder.finished?.startedAt ?? Date()))"
    }

    // MARK: - Status & controls

    private var statusCard: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                    .opacity(recorder.state == .recording ? 1 : 0.8)
                Text(statusText).font(.headline)
                Spacer()
            }
            Text(TimeFormat.clock(recorder.elapsed))
                .font(.system(size: 54, weight: .light, design: .monospaced))
                .frame(maxWidth: .infinity)
            controls
        }
        .card()
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 14) {
            switch recorder.state {
            case .idle:
                Button {
                    Task { await recorder.start() }
                } label: {
                    Label("Начать запись", systemImage: "record.circle").frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(recorder.hasUnsaved)
            case .starting, .stopping:
                ProgressView().controlSize(.small)
                Text(recorder.state == .starting ? "Подключение…" : "Завершение…").foregroundStyle(.secondary)
            case .recording, .paused:
                Button {
                    recorder.togglePause()
                } label: {
                    Label(recorder.state == .paused ? "Продолжить" : "Пауза",
                          systemImage: recorder.state == .paused ? "play.fill" : "pause.fill")
                        .frame(minWidth: 140)
                }
                .controlSize(.large)
                Button {
                    Task { await recorder.stop() }
                } label: {
                    Label("Стоп", systemImage: "stop.fill").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var statusText: String {
        switch recorder.state {
        case .idle: return recorder.hasUnsaved ? "Запись остановлена — сохраните её" : "Готово к записи"
        case .starting: return "Запуск…"
        case .recording: return "Идёт запись"
        case .paused: return "Пауза"
        case .stopping: return "Остановка…"
        }
    }

    private var statusColor: Color {
        switch recorder.state {
        case .recording: return .red
        case .paused: return .orange
        default: return .secondary
        }
    }

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Что записывать").font(.headline)
            HStack {
                Toggle("Мой микрофон", isOn: $settings.captureMicrophone)
                Spacer().frame(width: 24)
                Toggle("Звук созвона (голоса собеседников)", isOn: $settings.captureSystemAudio)
            }
            .disabled(recorder.state != .idle)
            LevelMeter(title: "Микрофон", systemImage: "mic", level: recorder.micLevel, enabled: settings.captureMicrophone)
            LevelMeter(title: "Звук созвона", systemImage: "speaker.wave.2", level: recorder.systemLevel,
                       enabled: settings.captureSystemAudio)
        }
        .card()
    }

    // MARK: - Saving

    private func saveCard(_ finished: FinishedRecording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Сохранение записи").font(.headline)
                Spacer()
                Text("Длительность: \(TimeFormat.clock(finished.duration))").foregroundStyle(.secondary)
            }
            HStack {
                Text("Имя файла:").frame(width: 90, alignment: .leading)
                TextField("Например: Планёрка с командой", text: $form.fileName)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Формат:").frame(width: 90, alignment: .leading)
                Picker("", selection: $settings.audioFormat) {
                    ForEach(AudioFormatOption.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 380)
            }
            if let progress = recorder.exportProgress {
                ProgressView(value: progress) { Text("Сохранение…") }
            } else {
                HStack {
                    Button {
                        Task { await recorder.save(name: form.fileName, format: settings.audioFormat) }
                    } label: {
                        Label("Сохранить…", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    Spacer()
                    Button(role: .destructive) {
                        form.confirmDiscard = true
                    } label: {
                        Label(finished.savedTo == nil ? "Удалить запись" : "Закрыть", systemImage: "trash")
                    }
                }
            }
            if let saved = finished.savedTo {
                Divider()
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Сохранено: \(saved.path)").lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                HStack {
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                    Button {
                        transcriber.select(saved)
                        navigation.tab = .transcribe
                    } label: {
                        Label("Расшифровать эту запись", systemImage: "text.quote")
                    }
                }
            }
        }
        .card()
        .confirmationDialog(finished.savedTo == nil ? "Удалить несохранённую запись?" : "Закрыть запись?",
                            isPresented: $form.confirmDiscard) {
            Button(finished.savedTo == nil ? "Удалить" : "Закрыть", role: .destructive) { recorder.discard() }
        } message: {
            Text(finished.savedTo == nil ? "Это действие нельзя отменить." : "Сохранённый файл останется на месте.")
        }
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            HStack {
                Button("Открыть настройки конфиденциальности") {
                    let url = message.contains("Микрофон") || message.contains("микрофон")
                        ? "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                        : "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                }
                Button("Скрыть") { recorder.errorMessage = nil }
            }
        }
        .card()
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Работает с любым приложением: Zoom, Google Meet, Teams, Telegram, FaceTime, WhatsApp.", systemImage: "info.circle")
            Label("Лучше говорить в наушниках — тогда голоса собеседников не попадут в микрофон повторно (без эха).", systemImage: "headphones")
            Label("Кнопки: ⌘R — запись, ⇧⌘P — пауза/продолжить, ⌘. — стоп. Управлять можно и из строки меню.", systemImage: "keyboard")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

@MainActor
final class RecordFormState: ObservableObject {
    @Published var fileName = ""
    @Published var confirmDiscard = false
}
