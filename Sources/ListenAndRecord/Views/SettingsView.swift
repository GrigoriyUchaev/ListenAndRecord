import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var models: ModelManager
    @StateObject private var encoder = EncoderState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                modelsCard
                if !models.foundOnDisk.isEmpty { foundCard }
                qualityCard
                recordingCard
            }
            .padding(8)
        }
        .task {
            encoder.url = await Task.detached { AudioExporter.mp3Encoder }.value
        }
    }

    // MARK: - Models

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Модели распознавания речи").font(.headline)
                Spacer()
                Button("Добавить свой файл…") { models.importFile() }
            }
            Text("Распознавание работает внутри приложения, без интернета. Интернет нужен только один раз — чтобы скачать модель.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(ModelManager.catalog) { model in
                modelRow(model)
                Divider()
            }
            ForEach(models.installedModels.filter { p in !ModelManager.catalog.contains { models.localURL(for: $0).path == p.path } }) { custom in
                HStack {
                    selectButton(path: custom.path)
                    VStack(alignment: .leading) {
                        Text(custom.title).font(.body.weight(.medium))
                        Text(custom.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Убрать из списка") { models.removeCustom(path: custom.path) }
                }
                Divider()
            }
            if let error = models.downloadError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .card()
    }

    private func modelRow(_ model: WhisperModelInfo) -> some View {
        let installed = models.isInstalled(model)
        let path = models.localURL(for: model).path
        return HStack(spacing: 12) {
            if installed { selectButton(path: path) } else { Image(systemName: "circle.dashed").foregroundStyle(.tertiary).frame(width: 22) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.title).font(.body.weight(.medium))
                    if model.id == "large-v3-turbo" {
                        Text("рекомендуется").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.15))).foregroundStyle(.red)
                    }
                }
                Text("\(model.sizeText) · \(model.note)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = models.downloads[model.id] {
                ProgressView(value: p).frame(width: 120)
                Text("\(Int(p * 100))%").monospacedDigit().frame(width: 40)
                Button("Отмена") { models.cancelDownload(id: model.id) }
            } else if installed {
                Button("Удалить") { models.delete(model) }
            } else {
                Button("Скачать") { models.download(model) }
            }
        }
    }

    private func selectButton(path: String) -> some View {
        Button {
            models.selectedPath = path
        } label: {
            Image(systemName: models.selectedPath == path ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(models.selectedPath == path ? Color.accentColor : Color.secondary)
                .font(.title3)
        }
        .buttonStyle(.plain)
        .frame(width: 22)
        .help("Использовать эту модель")
    }

    private var foundCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Найдены модели на вашем Mac").font(.headline)
            Text("Их можно использовать без повторного скачивания.").font(.caption).foregroundStyle(.secondary)
            ForEach(models.foundOnDisk, id: \.self) { path in
                HStack {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text((path as NSString).lastPathComponent)
                        Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Использовать") {
                        models.addCustom(path: path)
                        Task { await models.scanDisk() }
                    }
                }
            }
        }
        .card()
    }

    // MARK: - Quality

    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Качество и защита от пропусков").font(.headline)
            Picker("Режим", selection: $settings.highAccuracy) {
                Text("Максимальная точность (beam search)").tag(true)
                Text("Быстрее (немного менее точно)").tag(false)
            }
            .pickerStyle(.radioGroup)
            Divider()
            Toggle("Удалять тишину детектором речи Silero VAD", isOn: $settings.useVAD)
            HStack {
                if models.vadInstalled {
                    Label("Модель Silero VAD установлена", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if let p = models.downloads["vad"] {
                    ProgressView(value: p).frame(width: 160)
                } else {
                    Label("Модель Silero VAD не установлена (≈ 1 МБ)", systemImage: "arrow.down.circle")
                    Spacer()
                    Button("Скачать") { models.downloadVAD() }
                }
            }
            .font(.callout)
            Toggle("Проверять результат и повторно распознавать фрагменты, где речь потерялась", isOn: $settings.recoverGaps)
            Text("""
            Как приложение избегает «потери» разговора после пауз:
            • запись режется на фрагменты по паузам, длинная тишина вырезается;
            • каждый фрагмент распознаётся независимо, без «памяти» предыдущего текста — именно из-за неё Whisper зацикливается и пропускает речь;
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
}

@MainActor
final class EncoderState: ObservableObject {
    @Published var url: URL?
}
