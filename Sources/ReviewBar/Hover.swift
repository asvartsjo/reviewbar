import SwiftUI
import AppKit

/// For rows and lines that are clickable but look like plain text: a faint rounded background on
/// hover, a stronger one while pressed, and the pointing-hand cursor. The row takes the full
/// width, so the highlight and the click area don't stop where its text does.
struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(HoverHighlight(pressed: configuration.isPressed, inset: 6))
    }
}

/// A borderless button that shows it can be clicked: the same hover background and cursor.
/// Its icon is grey like its text, instead of macOS's accent blue.
struct HoverBorderlessStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(configuration).buttonStyle(.borderless).labelStyle(GreyIconLabelStyle())
            .modifier(HoverHighlight(inset: 4))
    }
}

private struct GreyIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(.secondary)
            configuration.title
        }
    }
}

extension ButtonStyle where Self == HoverRowStyle {
    static var hoverRow: HoverRowStyle { .init() }
}

extension PrimitiveButtonStyle where Self == HoverBorderlessStyle {
    static var hoverBorderless: HoverBorderlessStyle { .init() }
}

/// The background reaches `inset` past the content, so hovering never moves the layout.
/// Nothing shows while disabled.
struct HoverHighlight: ViewModifier {
    var pressed = false
    var inset: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(.primary.opacity(!isEnabled ? 0 : pressed ? 0.12 : hovering ? 0.06 : 0))
                    .padding(.horizontal, -inset).padding(.vertical, -2)
            )
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
            .pointingHand(isEnabled)
    }
}

extension View {
    /// The pointing-hand cursor while hovering.
    func pointingHand(_ enabled: Bool = true) -> some View { modifier(PointingHand(enabled: enabled)) }
}

/// macOS 14 has no `pointerStyle`, so this pushes and pops NSCursor. It pops on disappear too,
/// or a row that vanishes under the pointer (dismissed, or clicked into) would leave the hand behind.
private struct PointingHand: ViewModifier {
    let enabled: Bool
    @ViewState private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside, enabled, !pushed { NSCursor.pointingHand.push(); pushed = true }
                else if !inside, pushed { NSCursor.pop(); pushed = false }
            }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}
