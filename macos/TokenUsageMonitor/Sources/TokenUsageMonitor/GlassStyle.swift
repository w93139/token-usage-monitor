import AppKit
import SwiftUI

/// One system backdrop for the window; cards add tint instead of extra blur layers.
struct GlassBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                WindowBackdrop()
                    .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.16))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 12
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor)
                        .opacity(reduceTransparency ? 1 : (colorScheme == .dark ? 0.46 : 0.56)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 0.7)
                    .allowsHitTesting(false)
            )
    }
}

struct GlassButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        GlassButton(configuration: configuration, compact: compact)
    }

    private struct GlassButton: View {
        let configuration: Configuration
        let compact: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
        @State private var hovered = false

        private var activeHover: Bool { hovered && isEnabled }
        private var pressed: Bool { configuration.isPressed && isEnabled }

        var body: some View {
            configuration.label
                .padding(.horizontal, compact ? 5 : 8)
                .padding(.vertical, compact ? 4 : 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            pressed ? Color.accentColor.opacity(0.75) : Color.primary.opacity(activeHover ? 0.24 : 0.11),
                            lineWidth: pressed ? 1.2 : 0.7
                        )
                        .allowsHitTesting(false)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: activeHover)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: pressed)
        }

        private var backgroundColor: Color {
            if pressed { return Color.accentColor.opacity(reduceTransparency ? 0.30 : 0.22) }
            if activeHover { return Color.primary.opacity(reduceTransparency ? 0.14 : 0.10) }
            return Color(nsColor: .controlBackgroundColor).opacity(reduceTransparency ? 1 : 0.34)
        }
    }
}

struct HoverFeedback: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    private var activeHover: Bool { hovered && isEnabled }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(activeHover ? 0.075 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(activeHover ? 0.14 : 0), lineWidth: 0.7)
                    .allowsHitTesting(false)
            )
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: activeHover)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 12) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius))
    }

    func usageHover() -> some View { modifier(HoverFeedback()) }
}
