import AppKit
import SwiftUI

enum SleepSealTheme {
    // Semantic native surfaces follow contrast, appearance and accessibility settings.
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
    static let accent = Color(nsColor: NSColor(name: "SleepSealAccent") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.47, green: 0.80, blue: 0.77, alpha: 1)
            : NSColor(srgbRed: 0.15, green: 0.48, blue: 0.47, alpha: 1)
    })
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 20
    static let cornerRadius: CGFloat = 10
}

struct SealSection<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(SleepSealTheme.surface, in: RoundedRectangle(cornerRadius: SleepSealTheme.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: SleepSealTheme.cornerRadius).strokeBorder(SleepSealTheme.separator.opacity(0.55)))
    }
}

struct SealNote: View {
    let text: String
    var symbol = "info.circle"
    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}
