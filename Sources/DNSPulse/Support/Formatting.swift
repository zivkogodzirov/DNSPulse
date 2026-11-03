import AppKit
import SwiftUI

extension Color {
    /// Creates a colour from "#RRGGBB".
    init(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        var value: UInt64 = 0
        guard text.count == 6, Scanner(string: text).scanHexInt64(&value) else {
            self.init(.sRGB, red: 0.55, green: 0.55, blue: 0.6, opacity: 1)
            return
        }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}

enum Palette {
    /// Colours handed out to servers without a brand colour.
    static let automatic = [
        "#5E81F4", "#F2994A", "#27AE60", "#EB5757", "#9B51E0", "#2D9CDB",
        "#E2B93B", "#219653", "#BB6BD9", "#56CCF2", "#E07A5F", "#3D5A80",
    ]

    /// Colours offered in the server editor.
    static let swatches = [
        "#F38020", "#4285F4", "#E0218A", "#68BC71", "#5D5FEF", "#00A3E0",
        "#C8102E", "#7B3FE4", "#1FA67A", "#F59E0B", "#3D5A80", "#8E8E93",
    ]

    /// A stable colour for a name (String.hashValue changes every launch, so use djb2).
    static func automaticHex(for key: String) -> String {
        var hash: UInt64 = 5381
        for byte in key.lowercased().utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return automatic[Int(hash % UInt64(automatic.count))]
    }
}

enum Format {
    static func ms(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value < 10 { return String(format: "%.2f ms", value) }
        if value < 100 { return String(format: "%.1f ms", value) }
        return String(format: "%.0f ms", value)
    }

    /// Milliseconds without the unit, for compact cells.
    static func msValue(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if value < 10 { return String(format: "%.1f", value) }
        return String(format: "%.0f", value)
    }

    static func percent(_ value: Double) -> String {
        if value >= 0.9995 { return "100%" }
        return String(format: "%.1f%%", value * 100)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m \(total % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Maps a response time to a green → yellow → red colour.
enum Heat {
    static func color(for value: Double, low: Double, high: Double) -> Color {
        guard value.isFinite else { return .red }
        let t = high > low ? Swift.min(Swift.max((value - low) / (high - low), 0), 1) : 0
        return Color(hue: 0.36 * (1 - t), saturation: 0.75, brightness: 0.86)
    }

    /// Bar length for `value` between the fastest (`low`) and slowest (`high`), on a log axis,
    /// so small differences between close servers stay visible. Never shorter than 12%.
    static func barFraction(for value: Double, low: Double, high: Double) -> Double {
        guard value.isFinite, value > 0, low > 0, high > low else { return 1 }
        let t = (Foundation.log(value) - Foundation.log(low)) / (Foundation.log(high) - Foundation.log(low))
        return 0.12 + 0.88 * Swift.min(Swift.max(t, 0), 1)
    }

    /// Same scale on a logarithmic axis. Response times are skewed (most are 10–100 ms, a few are 500 ms),
    /// so a log scale keeps the common range readable.
    static func logColor(for value: Double, low: Double, high: Double) -> Color {
        guard value.isFinite, value > 0, low > 0, high > 0 else { return color(for: value, low: low, high: high) }
        return color(for: Foundation.log(value), low: Foundation.log(low), high: Foundation.log(high))
    }
}

extension Comparable {
    func clamped(_ low: Self, _ high: Self) -> Self { Swift.min(Swift.max(self, low), high) }
}

/// What the colours in the website grid mean.
enum HeatColourMode: String, CaseIterable, Identifiable {
    case time, relative

    var id: Self { self }
    var title: String { self == .time ? "Time" : "vs Fastest" }
}

/// Eight discrete colour steps. Time mode is a log scale of milliseconds between "nice" p5 and p95 values;
/// relative mode is how many times slower than the website's fastest server (1× … 4×).
struct HeatScale: Hashable {
    static let steps = 8
    let mode: HeatColourMode
    let lo: Double
    let hi: Double

    /// `values` must be sorted and finite.
    init(mode: HeatColourMode, sortedFinite values: [Double]) {
        self.mode = mode
        let p5 = values.isEmpty ? 20 : LatencyStats.percentile(values, 0.05)
        let p95 = values.isEmpty ? 500 : LatencyStats.percentile(values, 0.95)
        // Floor at 5 ms: a cached router answers in under a millisecond and would stretch the scale.
        let low = Self.nice(Swift.max(p5, 5), up: false)
        lo = low
        hi = Swift.max(Self.nice(Swift.max(p95, low), up: true), low * 2)
    }

    /// 0 = fastest / quiet … 1 = slowest / loud.
    func position(_ ms: Double, rowBest: Double) -> Double {
        switch mode {
        case .time:
            return (Foundation.log(Swift.max(ms, lo) / lo) / Foundation.log(hi / lo)).clamped(0, 1)
        case .relative:
            guard rowBest.isFinite, rowBest > 0 else { return 0 }
            return (log2(Swift.max(ms / rowBest, 1)) / 2).clamped(0, 1)
        }
    }

    func bucket(_ ms: Double, rowBest: Double) -> Int {
        Swift.min(Int(position(ms, rowBest: rowBest) * Double(Self.steps)), Self.steps - 1)
    }

    /// Labels for the leading edge, middle and trailing edge of the legend.
    var legend: (String, String, String) {
        switch mode {
        case .time: (Format.msValue(lo) + " ms", Format.msValue((lo * hi).squareRoot()), "≥ " + Format.msValue(hi) + " ms")
        case .relative: ("fastest", "2×", "≥ 4×")
        }
    }

    static func nice(_ value: Double, up: Bool) -> Double {
        let power = pow(10, floor(log10(value)))
        let ladder = [1, 1.5, 2, 3, 5, 7, 10].map { $0 * power }
        return up ? (ladder.first { $0 >= value } ?? 10 * power) : (ladder.last { $0 <= value } ?? power)
    }
}

/// "Fast is quiet": lightness falls steadily from fast to slow (light L* 95→38, dark 21→48),
/// so the order still reads in greyscale and for colour-blind users.
enum HeatPalette {
    static let lightFills = ["#E8F5EC", "#D2EBD8", "#D6E5A8", "#EED38A", "#EFB173", "#E58858", "#C64B3C", "#A8283A"].map(Color.init(hex:))
    static let darkFills = ["#22382B", "#28503A", "#4C5A28", "#6E5A20", "#8A541F", "#A3472A", "#B93A30", "#D3343E"].map(Color.init(hex:))

    static func fills(dark: Bool) -> [Color] { dark ? darkFills : lightFills }

    /// Text colour per step, chosen for at least 4.3:1 contrast.
    static func inks(dark: Bool) -> [Color] {
        dark ? Array(repeating: Color.white.opacity(0.95), count: 8)
            : (0..<8).map { $0 >= 6 ? Color.white : Color.black.opacity(0.85) }
    }
}

private struct AccentKey: EnvironmentKey {
    static let defaultValue: Color = .blue
}

private struct ContentWidthLimitKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// The accent colour picked in Settings.
    var accent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }

    /// Width actually visible for page content, taken from the scroll view's frame (0 = unknown).
    /// Wide content can stretch a scroll view's document, so measuring the content alone can get stuck
    /// after the window shrinks; this value comes from the window and can't feed back.
    var contentWidthLimit: CGFloat {
        get { self[ContentWidthLimitKey.self] }
        set { self[ContentWidthLimitKey.self] = newValue }
    }
}

extension View {
    /// Publishes the scroll view's visible content width (minus `padding` on each side and any always-visible scroll bar).
    func providesContentWidthLimit(padding: CGFloat) -> some View {
        modifier(ContentWidthLimitProvider(padding: padding))
    }
}

private struct ContentWidthLimitProvider: ViewModifier {
    let padding: CGFloat
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.contentWidthLimit, width)
            .onGeometryChange(for: CGFloat.self) { proxy in
                let scroller = NSScroller.preferredScrollerStyle == .legacy
                    ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
                return max(0, (proxy.size.width - 2 * padding - scroller).rounded(.down))
            } action: { newWidth in
                if abs(newWidth - width) >= 1 { width = newWidth }
            }
    }
}
