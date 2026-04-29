//
//  TransparentTextField.swift
//  Projector
//
//  A TextField with no system styling - fully transparent background,
//  no focus ring, allowing parent views to control all visual styling.
//

import SwiftUI
import AppKit

/// A TextField that removes all macOS system styling (focus ring, background)
/// so parent views can apply custom styling without interference.
struct TransparentTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .medium)
    var alignment: NSTextAlignment = .left
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?

    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.font = font
        textField.alignment = alignment
        textField.placeholderString = placeholder
        textField.cell?.sendsActionOnEndEditing = true
        return textField
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.font = font
        nsView.alignment = alignment
        nsView.placeholderString = placeholder

        // Handle focus changes from SwiftUI
        DispatchQueue.main.async {
            if isFocused && nsView.window?.firstResponder != nsView.currentEditor() {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: TransparentTextField

        init(_ parent: TransparentTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused = true
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            DispatchQueue.main.async {
                self.parent.isFocused = false
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Return key pressed
                parent.onSubmit?()
                // Resign first responder to exit edit mode
                control.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                // Escape key pressed
                parent.onEscape?()
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}
