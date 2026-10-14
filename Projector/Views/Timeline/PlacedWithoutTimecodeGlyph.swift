//
//  PlacedWithoutTimecodeGlyph.swift
//  Projector
//
//  The warning mark a clip wears when its position was not set by the file.
//

import SwiftUI

/// Layout and wording shared by the clip views' no-timecode warning.
enum PlacedWithoutTimecodeStyle {

    /// Glyph size, matching the chip's micro monospaced text.
    static let glyphSize: CGFloat = 9

    /// Narrowest a clip can be and still show the bare glyph in place of a
    /// timecode chip that does not fit.
    static let minimumWidthForBareGlyph: CGFloat = 24

    /// Tooltip explaining the mark and the way to resolve it.
    static let help = "No embedded timecode - position was not set by the file. "
        + "Use Set Timecode Position… to set where it belongs."

    /// Spoken description of the mark.
    static let accessibilityLabel = "No embedded timecode, position was not set by the file"
}

/// A small warning triangle for a clip that carries no timecode of its own.
///
/// Shown inside the start-timecode chip, or alone where the chip does not fit.
/// Carries the tooltip and accessibility label, so the chip's text needs neither.
struct PlacedWithoutTimecodeGlyph: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: PlacedWithoutTimecodeStyle.glyphSize, weight: .semibold))
            .foregroundColor(AppColors.warning)
            .help(PlacedWithoutTimecodeStyle.help)
            .accessibilityLabel(PlacedWithoutTimecodeStyle.accessibilityLabel)
    }
}
