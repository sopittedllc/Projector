//
//  AccordionResizeHandle.swift
//  Projector
//
//  Extracted from ContentView - draggable resize handle for accordion panels.
//

import SwiftUI
import AppKit

/// A draggable resize handle for accordion panels.
///
/// This view provides a visual indicator (pill shape) that can be dragged
/// to resize accordion panels between a minimum and maximum height.
struct AccordionResizeHandle: View {
    @Binding var height: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var isDragging = false
    @State private var startHeight: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 8)
            .contentShape(Rectangle())
            .overlay(alignment: .center) {
                // Visual indicator - pill shape
                RoundedRectangle(cornerRadius: 2)
                    .fill(isDragging ? Color.accentColor : Color.white.opacity(0.3))
                    .frame(width: 40, height: 4)
            }
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if !isDragging {
                            startHeight = height
                            isDragging = true
                        }
                        let newHeight = startHeight + value.translation.height
                        height = min(maxHeight, max(minHeight, newHeight))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
    }
}
