import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var navigation: NavigationModel

    var body: some View {
        TabView(selection: $navigation.tab) {
            RecordView()
                .tabItem { Label("Запись", systemImage: "record.circle") }
                .tag(AppTab.record)
            TranscribeView()
                .tabItem { Label("Расшифровка", systemImage: "text.quote") }
                .tag(AppTab.transcribe)
            SettingsView()
                .tabItem { Label("Модели и настройки", systemImage: "cpu") }
                .tag(AppTab.settings)
        }
        .padding(12)
    }
}

/// Simple horizontal level meter (input RMS → dB scale).
struct LevelMeter: View {
    let title: String
    let systemImage: String
    let level: Float
    let enabled: Bool

    private var normalized: Double {
        guard level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        return min(1, max(0, (db + 55) / 55))
    }

    var body: some View {
        HStack(spacing: 10) {
            Label(title, systemImage: systemImage)
                .frame(width: 170, alignment: .leading)
                .foregroundStyle(enabled ? .primary : .secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * normalized)
                        .animation(.linear(duration: 0.1), value: normalized)
                }
            }
            .frame(height: 8)
        }
    }
}

extension View {
    func card() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
    }
}
