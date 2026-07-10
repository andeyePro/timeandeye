import SwiftUI

/// The shared andeye look for sibling apps (Time&I, a sibling andeye app, …): brand
/// colours, the semantic type scale, and the eye-mark renderer (AndeyeMark).
/// SwiftUI-only by contract — no AppKit/UIKit — so any andeye app on any
/// Apple platform can consume this target without dragging the macOS app
/// layers (the a sibling project's 2026-07-08 coordination request; its local shim
/// mirrors exactly this surface).
public enum AndeyeTheme {

    public enum Colours {
        /// One shared, legible highlight for text/glyphs on translucent dark
        /// backgrounds. `Color.accentColor` mirrors the user's system accent
        /// (often systemBlue), which reads fine as a FILL but is hard to read
        /// as TEXT on black/dark vibrancy (2026-07 hardware-test feedback).
        /// Decorative fills/strokes keep `Color.accentColor`; foreground
        /// text/glyphs use this, so contrast is retuned in ONE place.
        public static let highlight = Color(red: 0.45, green: 0.78, blue: 1.0)

        /// The brand amber the hero mark wears when andeye is "saying hello"
        /// (#F0A13A — the accent of time.andeye.com's landing page; the
        /// menu-bar mark instead wears an app-specific certainty tint).
        public static let brandAccent = Color(red: 240 / 255, green: 161 / 255, blue: 58 / 255)
    }

    /// The semantic type scale, distilled 2026-07-10 from what timeandeye
    /// actually sets (caption/caption2 dominate; monospaced variants carry
    /// timestamps and ids). Sibling apps use these NAMES so a family-wide
    /// retune is one edit here, not a hunt through call sites.
    public enum Fonts {
        /// Section and card headings.
        public static let heading = Font.headline
        /// Running text.
        public static let body = Font.body
        /// Emphasised interstitials — button rows, list group labels.
        public static let label = Font.callout
        /// Secondary text: explanations, row subtitles.
        public static let caption = Font.caption
        /// Fine print: counts, hints, footers.
        public static let detail = Font.caption2
        /// Monospaced caption — timestamps, short ids.
        public static let monoCaption = Font.system(.caption, design: .monospaced)
        /// Monospaced fine print — logs, hashes.
        public static let monoDetail = Font.system(.caption2, design: .monospaced)
    }
}

/// Compatibility spelling used throughout timeandeyeUI since 2026-07; new
/// code (and sibling apps) should reach the same value via
/// `AndeyeTheme.Colours.highlight`.
public enum AndeyeColors {
    public static let highlight = AndeyeTheme.Colours.highlight
}
