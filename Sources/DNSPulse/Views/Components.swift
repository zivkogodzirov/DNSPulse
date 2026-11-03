import AppKit
import SwiftUI

// MARK: - Cards

struct CardBackground: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08))
            )
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View {
        modifier(CardBackground(padding: padding))
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var icon: String?

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Icons and badges

struct ServerAvatar: View {
    let name: String
    let color: Color
    var isSystem = false
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [color.opacity(0.95), color.opacity(0.68)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if isSystem {
                Image(systemName: "house.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                let initials = Self.initials(for: name)
                Text(initials)
                    .font(.system(size: size * (initials.count > 1 ? 0.36 : 0.46), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
        .shadow(color: color.opacity(0.28), radius: 2.5, y: 1)
    }

    static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2, let first = words[0].first, let second = words[1].first {
            return "\(first)\(second)".uppercased()
        }
        return String(name.first(where: { $0.isLetter || $0.isNumber }) ?? "?").uppercased()
    }
}

struct ProtocolBadge: View {
    let proto: DNSProtocol

    var body: some View {
        Text(proto.shortTitle)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(proto.tint)
            .background(Capsule().fill(proto.tint.opacity(0.14)))
    }
}

struct TagLabel: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct RankBadge: View {
    let rank: Int

    private var medal: [Color]? {
        switch rank {
        case 1: [Color(hex: "#F9D976"), Color(hex: "#D4A017")]
        case 2: [Color(hex: "#E6E9ED"), Color(hex: "#9BA3AE")]
        case 3: [Color(hex: "#EDB183"), Color(hex: "#B5652B")]
        default: nil
        }
    }

    var body: some View {
        ZStack {
            if let medal {
                Circle().fill(LinearGradient(colors: medal, startPoint: .top, endPoint: .bottom))
                Text("\(rank)")
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 0.5, y: 0.5)
            } else {
                Circle().fill(Color.primary.opacity(0.07))
                Text("\(rank)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 26, height: 26)
    }
}

struct CategoryIcon: View {
    let category: WebsiteCategory
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: category.icon)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(category.color.gradient))
    }
}

struct AppIconView: View {
    var size: CGFloat = 56

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

// MARK: - Result bits

struct LatencyBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.65), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geometry.size.width * CGFloat(min(max(fraction, 0), 1))))
            }
        }
        .frame(height: 8)
    }
}

struct ReliabilityLabel: View {
    let rate: Double
    let attempts: Int

    private var color: Color {
        rate >= 0.99 ? .green : rate >= 0.95 ? .orange : .red
    }

    var body: some View {
        if attempts == 0 {
            Text("—").font(.caption).foregroundStyle(.secondary)
        } else {
            Label(Format.percent(rate), systemImage: rate >= 0.99 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .help("\(Format.percent(rate)) of \(attempts) lookups were answered")
        }
    }
}

struct InsightTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                Text(value).font(.headline).lineLimit(1).minimumScaleFactor(0.75)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 12)
    }
}

// MARK: - Buttons

struct ProminentButtonStyle: ButtonStyle {
    var color: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(
                Capsule().fill(LinearGradient(colors: [color.opacity(0.82), color], startPoint: .top, endPoint: .bottom))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
            .shadow(color: color.opacity(0.35), radius: configuration.isPressed ? 2 : 8, y: configuration.isPressed ? 1 : 4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool
    @Environment(\.accent) private var accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(isSelected ? .white : .primary)
            .background(Capsule().fill(isSelected ? AnyShapeStyle(accent) : AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07))))
            .contentShape(Capsule())
    }
}

struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minWidth: 170, alignment: .leading)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.28 : 0.17)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25)))
            .contentShape(Capsule())
    }
}

struct NoticeBanner: View {
    let text: String
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text)
            Spacer()
            if let onClose {
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

struct ColorSwatchPicker: View {
    @Binding var hex: String?
    let automaticHex: String

    var body: some View {
        HStack(spacing: 6) {
            swatch(nil, color: Color(hex: automaticHex))
                .overlay(Text("A").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                .help("Automatic")
            ForEach(Palette.swatches, id: \.self) { value in
                swatch(value, color: Color(hex: value))
            }
        }
    }

    private func swatch(_ value: String?, color: Color) -> some View {
        let isSelected = hex?.uppercased() == value?.uppercased()
        return Button {
            hex = value
        } label: {
            Circle()
                .fill(color)
                .frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(Color.primary.opacity(isSelected ? 0.9 : 0), lineWidth: 2).padding(-3))
        }
        .buttonStyle(.plain)
    }
}
