import SwiftUI
import AppKit

/// A SwiftUI wrapper for NSVisualEffectView that provides true macOS vibrancy
/// This blurs content BEHIND the window, unlike SwiftUI's built-in materials
public struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State
    var emphasized: Bool
    var alphaValue: CGFloat

    public init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active,
        emphasized: Bool = false,
        alphaValue: CGFloat = 1.0
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.emphasized = emphasized
        self.alphaValue = alphaValue
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = emphasized
        view.alphaValue = alphaValue
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        nsView.isEmphasized = emphasized
        nsView.alphaValue = alphaValue
    }
}

// MARK: - Convenience View Modifiers

extension View {
    /// Apply a glass-like vibrancy effect that blurs content behind the window
    func glassBackground(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) -> some View {
        self.background(
            VisualEffectView(material: material, blendingMode: blendingMode)
        )
    }

    /// Apply sidebar-style vibrancy
    func sidebarBackground() -> some View {
        self.background(
            VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
        )
    }

    /// Apply a dark translucent panel effect
    func darkPanelBackground() -> some View {
        self.background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
    }

    /// Apply a HUD-style glass effect (like media controls)
    func hudBackground() -> some View {
        self.background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
    }

    /// Apply a titlebar-style vibrancy
    func titlebarBackground() -> some View {
        self.background(
            VisualEffectView(material: .titlebar, blendingMode: .behindWindow)
        )
    }

    /// Apply underpage material (subtle, like content background)
    func contentBackground() -> some View {
        self.background(
            VisualEffectView(material: .underPageBackground, blendingMode: .behindWindow)
        )
    }
}

#Preview {
    VStack(spacing: Spacing.xl) {
        Text("HUD Window")
            .padding()
            .hudBackground()
            .cornerRadius(8)

        Text("Sidebar")
            .padding()
            .sidebarBackground()
            .cornerRadius(8)

        Text("Dark Panel")
            .padding()
            .darkPanelBackground()
            .cornerRadius(8)

        Text("Content Background")
            .padding()
            .contentBackground()
            .cornerRadius(8)
    }
    .padding(Spacing.xxl)
    .frame(width: 300, height: 400)
}
