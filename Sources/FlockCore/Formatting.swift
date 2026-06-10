import Foundation

public enum Format {
    /// 1234 → "1.2k", 4_500_000 → "4.5M"
    public static func tokens(_ count: Int) -> String {
        switch count {
        case ..<1000: String(count)
        case ..<1_000_000: String(format: "%.1fk", Double(count) / 1000)
        default: String(format: "%.1fM", Double(count) / 1_000_000)
        }
    }

    /// 12.34 → "12 tok/s", 0.82 → "0.8 tok/s"
    public static func rate(perSecond: Double) -> String {
        perSecond >= 10
            ? String(format: "%.0f tok/s", perSecond)
            : String(format: "%.1f tok/s", perSecond)
    }

    /// Compact form for the menu bar: "12/s", "0.8/s"
    public static func rateCompact(perSecond: Double) -> String {
        perSecond >= 10
            ? String(format: "%.0f/s", perSecond)
            : String(format: "%.1f/s", perSecond)
    }

    /// "claude-fable-5[1m]" → "fable-5", "claude-opus-4-8" → "opus-4-8"
    public static func modelShortName(_ model: String) -> String {
        var name = model
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        if name.hasPrefix("claude-") { name = String(name.dropFirst("claude-".count)) }
        return name
    }
}
