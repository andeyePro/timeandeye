import SwiftUI

/// One shared, legible highlight colour for text/glyphs on the popover's
/// translucent dark background. `Color.accentColor` mirrors the user's
/// System Settings accent (often systemBlue), which reads fine as a
/// background fill but is hard to read as TEXT on black/dark vibrancy
/// (2026-07 hardware-test feedback: "blue-on-black text is hard to read
/// throughout the app"). Decorative fills/strokes (calendar highlight,
/// timeline session outline, etc.) keep using `Color.accentColor` — only
/// foreground text/glyph colour swaps to this constant, so there is ONE
/// place to retune contrast rather than scattered literals.
enum AndeyeColors {
    static let highlight = Color(red: 0.45, green: 0.78, blue: 1.0)
}
