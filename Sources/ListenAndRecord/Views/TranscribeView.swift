import AppKit
import SwiftUI

struct TranscribeView: View {
    @EnvironmentObject private var transcriber: TranscriptionController
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var navigation: NavigationModel
    @EnvironmentObject private var models: ModelManager
    @StateObject private var drop = DropState()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if models.selectedModelURL == nil {
                    setupWarning
                }
                fileCard
                optionsCard
                runCard
                if let transcript = transcriber.transcript {
                    resultCard(transcript)
                }
            }
            .padding(8)
        }
    }

    private var setupWarning: some View {
        HStack {
            Label("Не выбрана модель распознавания — скачайте её (один раз).",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Spacer()
            Button("Открыть «Модели»") { navigation.tab = .settings }
        }
        .card()
    }

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Аудиофайл").font(.headline)
            HStack(spacing: 12) {
                Image(systemName: transcriber.inputURL == nil ? "square.and.arrow.down.on.square" : "waveform")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    if let url = transcriber.inputURL {
                        Text(url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text(transcriber.inputDuration.map { "Длительность: \(TimeFormat.clock($0))" } ?? url.deletingLastPathComponent().path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("Перетащите сюда аудио- или видеофайл")
                        Text("M4A, MP3, WAV, AIFF, FLAC, MP4, MOV…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Выбрать файл…") { transcriber.chooseFile() }
                    .disabled(transcriber.isRunning)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                .foregroundStyle(drop.isTargeted ? Color.accentColor : Color.secondary.opacity(0.4)))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, !transcriber.isRunning else { return false }
                transcriber.select(url)
                return true
            } isTargeted: { drop.isTargeted = $0 }
        }
        .card()
    }

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Параметры").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Язык разговора:")
                    Picker("", selection: $settings.language) {
                        ForEach(AppSettings.languages) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                GridRow {
                    Text("Модель:")
                    Picker("", selection: $models.selectedPath) {
                        if models.selectedModelURL == nil { Text("не выбрана").tag(models.selectedPath) }
                        ForEach(models.installedModels) { Text($0.title).tag($0.path) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                GridRow {
                    Text("Формат файла:")
                    Picker("", selection: $settings.transcriptFormat) {
                        ForEach(TranscriptFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }
                GridRow {
                    Text("")
                    Toggle("Добавлять время начала абзацев [чч:мм:сс]", isOn: $settings.includeTimestamps)
                }
            }
        }
        .disabled(transcriber.isRunning)
        .card()
    }

    private var runCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch transcriber.phase {
            case .running:
                ProgressView(value: transcriber.progress) {
                    Text(transcriber.stageText)
                } currentValueLabel: {
                    Text(etaText)
                }
                Button("Отменить", role: .cancel) { transcriber.cancel() }
            default:
                HStack {
                    Button {
                        transcriber.start()
                    } label: {
                        Label("Расшифровать", systemImage: "text.badge.star")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(transcriber.inputURL == nil || models.selectedModelURL == nil)
                    Spacer()
                    Text("Распознавание идёт локально на Mac, без интернета.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if case let .failed(message) = transcriber.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else if transcriber.stageText == "Отменено" {
                    Text("Расшифровка отменена.").foregroundStyle(.secondary)
                }
            }
        }
        .card()
    }

    private var etaText: String {
        let p = transcriber.progress
        guard let started = transcriber.startedAt, p > 0.15 else { return "\(Int(p * 100))%" }
        let elapsed = Date().timeIntervalSince(started)
        let remaining = elapsed / p * (1 - p)
        return "\(Int(p * 100))% · осталось ≈ \(TimeFormat.human(remaining))"
    }

    private func resultCard(_ transcript: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Результат").font(.headline)
                Spacer()
                Text("\(transcript.segments.reduce(0) { $0 + $1.wordCount }) слов")
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                Text(TranscriptExporter.plainText(transcript, timestamps: settings.includeTimestamps))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 220, maxHeight: 360)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                Button {
                    transcriber.save(format: settings.transcriptFormat, timestamps: settings.includeTimestamps)
                } label: {
                    Label("Сохранить как \(settings.transcriptFormat.fileExtension.uppercased())…", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                Button("Копировать текст") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript.plainText, forType: .string)
                }
                Spacer()
                if let saved = transcriber.savedURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([saved])
                    } label: {
                        Label("Сохранено — показать", systemImage: "checkmark.circle.fill")
                    }
                }
            }
        }
        .card()
    }
}

@MainActor
final class DropState: ObservableObject {
    @Published var isTargeted = false
}
