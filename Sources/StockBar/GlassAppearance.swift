import AppKit
import SwiftUI

/// One glass surface for the utility panel. Quote rows use subtle fills rather
/// than additional glass layers, keeping figures readable and compositing cheap.
struct PanelMaterial: ViewModifier {
    let enabled: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        // Change only the backdrop, preserving text-field focus and scroll state.
        content.background {
            if !enabled || reduceTransparency || contrast == .increased {
                Color(nsColor: .windowBackgroundColor)
            } else if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                ClassicPanelMaterial()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// Older macOS versions retain real window-backdrop blur, not a simulated tint.
private struct ClassicPanelMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
