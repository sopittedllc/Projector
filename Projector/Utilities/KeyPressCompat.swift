//
//  KeyPressCompat.swift
//  Projector
//
//  Timeline key handling on systems without SwiftUI's `onKeyPress`.
//

import SwiftUI
import AppKit

/// A key the timeline responds to.
enum TimelineKey {
    case returnKey
    case escape
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow

    /// The `NSEvent` key code, for the pre-macOS 14 path.
    fileprivate var keyCode: UInt16 {
        switch self {
        case .returnKey:  return 36
        case .escape:     return 53
        case .leftArrow:  return 123
        case .rightArrow: return 124
        case .downArrow:  return 125
        case .upArrow:    return 126
        }
    }
}

extension View {
    /// Handles the timeline's keys, using SwiftUI's own key handling where it exists.
    ///
    /// On macOS 14 and later this is exactly the chain of `onKeyPress` modifiers
    /// that was here before, so nothing about the app's key handling changes on
    /// a system that has them. Older systems fall back to a local `NSEvent`
    /// monitor, which is the only way to see key presses there.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether the timeline should act on keys at all. False
    ///     while a text field is being edited, so typing is never intercepted.
    ///   - action: Called with the key. Return `true` if it was handled, which
    ///     stops it going any further.
    func onTimelineKey(
        isEnabled: Bool,
        perform action: @escaping (TimelineKey) -> Bool
    ) -> some View {
        modifier(TimelineKeyHandling(isEnabled: isEnabled, action: action))
    }

    /// Hides the focus ring where the modifier for it exists.
    ///
    /// `focusEffectDisabled()` is macOS 14. Below that the ring is drawn, which
    /// is a visible difference on old systems and nothing at all on new ones.
    @ViewBuilder
    func focusRingHidden() -> some View {
        if #available(macOS 14, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }
}

// MARK: - Implementation

private struct TimelineKeyHandling: ViewModifier {
    let isEnabled: Bool
    let action: (TimelineKey) -> Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content
                .onKeyPress(.return) { dispatch(.returnKey) }
                .onKeyPress(.escape) { dispatch(.escape) }
                .onKeyPress(.leftArrow) { dispatch(.leftArrow) }
                .onKeyPress(.rightArrow) { dispatch(.rightArrow) }
                .onKeyPress(.upArrow) { dispatch(.upArrow) }
                .onKeyPress(.downArrow) { dispatch(.downArrow) }
        } else {
            content.background(
                LegacyKeyMonitor(isEnabled: isEnabled, action: action)
            )
        }
    }

    @available(macOS 14, *)
    private func dispatch(_ key: TimelineKey) -> KeyPress.Result {
        guard isEnabled else { return .ignored }
        return action(key) ? .handled : .ignored
    }
}

/// Watches for the timeline's keys through AppKit, for systems without `onKeyPress`.
///
/// The monitor is local to this process and sees keys before the focused view
/// does, so it is installed only while the timeline is on screen and asks the
/// caller whether each key was wanted. A key the caller does not claim is passed
/// through untouched, which is what leaves text fields and menu shortcuts alone.
private struct LegacyKeyMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let action: (TimelineKey) -> Bool

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(isEnabled: isEnabled, action: action)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        var isEnabled: Bool
        var action: (TimelineKey) -> Bool
        private var monitor: Any?

        init(isEnabled: Bool, action: @escaping (TimelineKey) -> Bool) {
            self.isEnabled = isEnabled
            self.action = action
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isEnabled else { return event }

                // Modified presses belong to menu commands, not to timeline
                // navigation, so they are never claimed here.
                let modifiers: NSEvent.ModifierFlags = [.command, .option, .control]
                guard event.modifierFlags.intersection(modifiers).isEmpty else { return event }

                guard let key = TimelineKey.allHandled.first(where: { $0.keyCode == event.keyCode }) else {
                    return event
                }
                // Swallow the event only when the timeline actually used it.
                return self.action(key) ? nil : event
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        deinit {
            // `dismantleNSView` covers the normal path; this is the safety net.
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}

private extension TimelineKey {
    /// Every key the timeline claims, for matching an incoming event.
    static let allHandled: [TimelineKey] = [
        .returnKey, .escape, .leftArrow, .rightArrow, .upArrow, .downArrow
    ]
}
