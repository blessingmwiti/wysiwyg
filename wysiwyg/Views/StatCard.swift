import SwiftUI

/// Reusable dashboard card: icon + title header, big value, subtitle, sparkline slot.
struct StatCard<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(icon: String, tint: Color, title: String, value: String, subtitle: String? = nil,
         @ViewBuilder content: () -> Content = { EmptyView() }) {
        self.icon = icon; self.tint = tint; self.title = title
        self.value = value; self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
            }
            content
        }
        .padding(10)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Thin usage bar (CPU cores, memory pressure, disk).
struct UsageBar: View {
    let fraction: Double
    let tint: Color
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.tertiary.opacity(0.4))
                RoundedRectangle(cornerRadius: 3)
                    .fill(tint.gradient)
                    .frame(width: max(3, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 6)
    }
}
