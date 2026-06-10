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

    /// 12.34 → "12 tok/s", 0.82 → "0.8 tok/s", 4200 → "4.2k tok/s"
    public static func rate(perSecond: Double) -> String {
        "\(rateNumber(perSecond)) tok/s"
    }

    /// Compact form for the menu bar: "12/s", "0.8/s", "4.2k/s"
    public static func rateCompact(perSecond: Double) -> String {
        "\(rateNumber(perSecond))/s"
    }

    private static func rateNumber(_ v: Double) -> String {
        switch v {
        case 1_000_000...: String(format: "%.1fM", v / 1_000_000)
        case 1000...: String(format: "%.1fk", v / 1000)
        case 10...: String(format: "%.0f", v)
        default: String(format: "%.1f", v)
        }
    }

    /// "claude-fable-5[1m]" → "fable-5", "claude-opus-4-8" → "opus-4-8"
    public static func modelShortName(_ model: String) -> String {
        var name = model
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        if name.hasPrefix("claude-") { name = String(name.dropFirst("claude-".count)) }
        return name
    }
}
