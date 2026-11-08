import SwiftUI

/// DuoBar+: every popover row is a rounded-rectangle card inside one glass
/// panel (see `PopoverGlassContainer`). Cards use a light translucent fill
/// and a hairline edge instead of their own glass, so the panel's glass is
/// sampled once. The parameters are kept so existing call sites compile.
struct PopoverCardBackground: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: PopoverDesign.cardCornerRadius, style: .continuous)
        content
            .background(Color.primary.opacity(0.065), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }
}

extension View {
    func popoverCardBackground(cornerRadius: CGFloat, fillOpacity: Double) -> some View {
        modifier(PopoverCardBackground())
    }
}

/// The popover's glass panel: Liquid Glass on macOS 26 and later, a
/// translucent material on older systems, with rounded corners and an edge.
struct PopoverGlassContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: PopoverDesign.panelCornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(.black.opacity(0.28)), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
    }
}
