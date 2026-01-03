//
//  WindowTitleConfigurator.swift
//  Projector
//
//  Extracted from ContentView - configures the window title with a custom logo.
//

import SwiftUI
import AppKit

/// Configures the window title with a logo and custom title format.
///
/// This view is used as a background to configure the window's title bar
/// with a custom logo and "PROJECTOR: [filename]" format.
struct WindowTitleConfigurator: NSViewRepresentable {
    let title: String
    let isEdited: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindowTitle(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindowTitle(nsView.window)
        }
    }

    private func configureWindowTitle(_ window: NSWindow?) {
        guard let window = window else { return }

        // Hide the system title - we'll show our own
        window.titleVisibility = .hidden

        // Update the window title (for Window menu, etc.)
        let displayTitle = "PROJECTOR: " + title + (isEdited ? " *" : "")
        window.title = displayTitle

        // Find the titlebar container and add our custom title with logo
        guard let titlebarContainer = window.standardWindowButton(.closeButton)?.superview?.superview else { return }

        // Look for an existing custom title view or create one
        configureTitleWithLogo(in: titlebarContainer, window: window)
    }

    private func configureTitleWithLogo(in container: NSView, window: NSWindow) {
        // Check if we already added our custom view (identified by accessibilityIdentifier)
        let customViewID = "ProjectorTitleView"
        if let existingView = findViewWithIdentifier(customViewID, in: container) as? NSStackView {
            // Update existing view
            if let textField = existingView.arrangedSubviews.last as? NSTextField {
                let displayTitle = "PROJECTOR: " + title + (isEdited ? " *" : "")
                textField.stringValue = displayTitle
                if isEdited {
                    textField.font = NSFont.systemFont(ofSize: 13, weight: .semibold).italic()
                } else {
                    textField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
                }
            }
            return
        }

        // Find the original title text field
        guard let originalTitle = findTitleTextField(in: container, title: title) else { return }

        // Hide the original title
        originalTitle.isHidden = true

        // Create our custom title view with logo
        let stackView = NSStackView()
        stackView.setAccessibilityIdentifier(customViewID)
        stackView.orientation = .horizontal
        stackView.spacing = 6
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Add logo
        let logoView = NSImageView()
        logoView.image = NSImage(named: "TitlebarLogo")
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logoView.widthAnchor.constraint(equalToConstant: 16),
            logoView.heightAnchor.constraint(equalToConstant: 16)
        ])
        stackView.addArrangedSubview(logoView)

        // Add title text
        let titleField = NSTextField(labelWithString: "PROJECTOR: " + title + (isEdited ? " *" : ""))
        titleField.font = isEdited ? NSFont.systemFont(ofSize: 13, weight: .semibold).italic() : NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.alignment = .center
        stackView.addArrangedSubview(titleField)

        // Add to the same superview as the original title
        if let superview = originalTitle.superview {
            superview.addSubview(stackView)

            // Center the stack view where the original title was
            NSLayoutConstraint.activate([
                stackView.centerXAnchor.constraint(equalTo: superview.centerXAnchor),
                stackView.centerYAnchor.constraint(equalTo: originalTitle.centerYAnchor)
            ])
        }
    }

    private func findViewWithIdentifier(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        for subview in view.subviews {
            if let found = findViewWithIdentifier(identifier, in: subview) {
                return found
            }
        }
        return nil
    }

    private func findTitleTextField(in view: NSView, title: String) -> NSTextField? {
        for subview in view.subviews {
            if let textField = subview as? NSTextField,
               textField.stringValue.contains(title) || textField.stringValue == "Untitled Projector Project" {
                return textField
            }
            if let found = findTitleTextField(in: subview, title: title) {
                return found
            }
        }
        return nil
    }
}

// MARK: - NSFont Extension

extension NSFont {
    /// Returns an italic variant of this font.
    func italic() -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: 0) ?? self
    }
}
