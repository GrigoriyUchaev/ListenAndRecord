import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var encoder = EncoderState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                whisperCard
                qualityCard
                recordingCard
            }
            .padding(8)
        }
        .onChange(of: settings.whisperPath) { _, _ in
            Task { _ = await settings.loadCapabilities() }
        }
        .task {
            _ = await settings.loadCapabilities()
            encoder.url = await Task.detached { AudioExporter.mp3Encoder }.value
        }
    }

    private var whisperCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Распознаватель речи (whisper.cpp)").font(.headline)
                Spacer()
                if settings.isDetecting { ProgressView().controlSize(.small) }
                Button("Найти автоматически") { Task { await settings.autodetect(onlyMissing: false) } }
                    .disabled(settings.isDetecting)
            }
            pathRow(title: "Программа whisper-cli:", path: $settings.whisperPath, ok: settings.whisperURL != nil) {
                pick(title: "Выберите whisper-cli", directory: "/opt/homebrew/bin") { settings.whisperPath = $0.path }
            }
            pathRow(title: "Модель (.bin):", path: $settings.modelPath, ok: settings.modelURL != nil) {
                pick(title: "Выберите модель ggml-*.bin", directory: nil) { settings.modelPath = $0.path }
            }
            if let caps = settings.capabilities {
                Text(caps.supportsVAD
                     ? "whisper-cli поддерживает Silero VAD — паузы будут обрабатываться надёжно."
                     : "Эта версия whisper-cli не поддерживает VAD. Обновите: brew upgrade whisper-cpp (приложение всё равно режет аудио по паузам само).")
                    .font(.caption)
                    .foregroundStyle(caps.supportsVAD ? Color.secondary : Color.orange)
            }
            Text("Рекомендуемая модель — ggml-large-v3-turbo (быстро и точно). Для максимальной точности можно выбрать ggml-large-v3 — она в 3–4 раза медленнее.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Защита от пропусков после пауз").font(.headline)
            Toggle("Удалять тишину детектором речи Silero VAD", isOn: $settings.useVAD)
            HStack {
                if settings.vadModelInstalled {
                    Label("Модель Silero VAD установлена", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Модель Silero VAD не установлена (≈ 1 МБ, скачивается один раз)", systemImage: "arrow.down.circle")
                    Spacer()
                    Button("Скачать") { Task { await settings.downloadVADModel() } }
                        .disabled(settings.vadDownloadState == "Скачивание…")
                }
            }
            .font(.callout)
            if let state = settings.vadDownloadState {
                Text(state).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Проверять результат и повторно распознавать фрагменты, где речь потерялась", isOn: $settings.recoverGaps)
            Text("""
            Как приложение избегает «потери» разговора после пауз:
            • запись режется на фрагменты по паузам, длинная тишина вырезается;
            • каждый фрагмент распознаётся независимо (без «памяти» предыдущего текста, -mc 0) — именно из-за неё Whisper зацикливается и пропускает речь;
            • после распознавания проверяется, не осталось ли участков речи без текста; такие участки распознаются повторно мелкими кусками;
            • удаляются типичные «галлюцинации» в тишине («Продолжение следует…», «Субтитры сделал…», повторы).
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .card()
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Запись").font(.headline)
            if let enc = encoder.url {
                Label("MP3: используется \(enc.lastPathComponent) (\(enc.path))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("Для MP3 установите кодировщик: brew install lame (M4A и WAV работают без него)",
                      systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
            Button("Открыть настройки доступа к записи звука") {
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(u)
                }
            }
        }
        .font(.callout)
        .card()
    }

    private func pathRow(title: String, path: Binding<String>, ok: Bool, choose: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(title).frame(width: 160, alignment: .leading)
            TextField("Не указано", text: path).textFieldStyle(.roundedBorder)
            Button("Выбрать…", action: choose)
        }
    }

    private func pick(title: String, directory: String?, completion: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        if let directory { panel.directoryURL = URL(fileURLWithPath: directory) }
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }
}

@MainActor
final class EncoderState: ObservableObject {
    @Published var url: URL?
}
