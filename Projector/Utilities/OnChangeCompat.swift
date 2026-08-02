//
//  OnChangeCompat.swift
//  Projector
//
//  `onChange` with the previous value, on systems older than macOS 14.
//

import SwiftUI

extension View {
    /// Runs an action when a value changes, passing the new value.
    ///
    /// Uses SwiftUI's current `onChange` wherever it exists, so a system that
    /// has it behaves exactly as it did before this shim was introduced. The
    /// older single-parameter form is only taken on systems without it, and is
    /// confined here rather than deprecating call sites across the app.
    ///
    /// - Parameters:
    ///   - value: The value to watch.
    ///   - action: Called with the new value.
    @ViewBuilder
    func onChangeCompat<V: Equatable>(
        of value: V,
        perform action: @escaping (V) -> Void
    ) -> some View {
        if #available(macOS 14, *) {
            onChange(of: value) { _, newValue in
                action(newValue)
            }
        } else {
            onChange(of: value, perform: action)
        }
    }

    /// Runs an action when a value changes, giving it the old value as well.
    ///
    /// SwiftUI's two-parameter `onChange(of:initial:_:)` is macOS 14, which
    /// would put the app's floor above the machines a lot of composers are
    /// still working on. This provides the same signature everywhere.
    ///
    /// Most call sites only want the new value and could use the older
    /// single-parameter form directly. This exists for the ones that genuinely
    /// compare against the previous value - "only when the timeline grew", "only
    /// when the field lost focus" - where dropping it silently changes what the
    /// view does.
    ///
    /// - Parameters:
    ///   - value: The value to watch.
    ///   - action: Called with the previous and the new value.
    @ViewBuilder
    func onChangeWithPrevious<V: Equatable>(
        of value: V,
        perform action: @escaping (V, V) -> Void
    ) -> some View {
        if #available(macOS 14, *) {
            onChange(of: value) { oldValue, newValue in
                action(oldValue, newValue)
            }
        } else {
            modifier(PreviousValueChangeModifier(value: value, action: action))
        }
    }
}

/// Tracks the previous value so pre-macOS 14 systems can offer the same pair.
///
/// The older `onChange(of:perform:)` hands over only the new value, so the
/// previous one has to be remembered here. Seeded on appear, which is why the
/// first change reports a genuine predecessor rather than the new value twice.
private struct PreviousValueChangeModifier<V: Equatable>: ViewModifier {
    let value: V
    let action: (V, V) -> Void

    @State private var previous: V?

    func body(content: Content) -> some View {
        content
            .onAppear { previous = value }
            .onChange(of: value) { newValue in
                // Falls back to the new value only if the view never appeared,
                // in which case there is no earlier state to compare against.
                action(previous ?? newValue, newValue)
                previous = newValue
            }
    }
}
