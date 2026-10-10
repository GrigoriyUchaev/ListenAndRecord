import Foundation

enum TimeFormat {
    /// 3725 -> "01:02:05"
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// 3725 -> "1 ч 2 мин", 65 -> "1 мин 5 с"
    static func human(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h) ч \(m) мин" }
        if m > 0 { return "\(m) мин \(s) с" }
        return "\(s) с"
    }

    static func fileStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f.string(from: date)
    }

    static func longDate(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .long
        f.timeStyle = .short
        return f.string(from: date)
    }
}
