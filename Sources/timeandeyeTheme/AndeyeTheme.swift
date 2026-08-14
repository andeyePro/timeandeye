import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// The shared andeye look for sibling andeye apps: brand
/// colours, the semantic type scale, and the eye-mark renderer (AndeyeMark).
/// SwiftUI-first by contract: the ONLY platform-kit use is the
/// `canImport`-guarded dynamic-colour construction (SwiftUI has no
/// appearance-resolved Color initialiser of its own), which adds no
/// dependency any Apple platform doesn't already ship — so any andeye app
/// on any Apple platform can still consume this target without dragging
/// the macOS app layers.
package enum AndeyeTheme {

    package enum Colours {
        /// One shared, legible highlight for text/glyphs. `Color.accentColor`
        /// mirrors the user's system accent (often systemBlue), which reads
        /// fine as a FILL but is hard to read as TEXT on black/dark vibrancy
        /// (2026-07 hardware-test feedback). Decorative fills/strokes keep
        /// `Color.accentColor`; foreground text/glyphs use this, so contrast
        /// is retuned in ONE place. Dynamic since 2026-08-14: the light blue
        /// that reads well on dark vibrancy washed out on white, so light
        /// mode gets a deep blue instead — resolved per-appearance by the
        /// platform colour (the `canImport` split keeps the target consumable
        /// on every Apple platform; no consumer gains a dependency it didn't
        /// already have).
        package static let highlight: Color = {
            #if canImport(AppKit)
            return Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(red: 0.45, green: 0.78, blue: 1.0, alpha: 1)
                    : NSColor(red: 0.00, green: 0.35, blue: 0.72, alpha: 1)
            })
            #elseif canImport(UIKit)
            return Color(uiColor: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.45, green: 0.78, blue: 1.0, alpha: 1)
                    : UIColor(red: 0.00, green: 0.35, blue: 0.72, alpha: 1)
            })
            #else
            return Color(red: 0.45, green: 0.78, blue: 1.0)
            #endif
        }()

        /// The brand amber the hero mark wears when andeye is "saying hello"
        /// (#F0A13A — the accent of time.andeye.com's landing page; the
        /// menu-bar mark instead wears an app-specific certainty tint).
        package static let brandAccent = Color(red: 240 / 255, green: 161 / 255, blue: 58 / 255)
    }

    /// The semantic type scale, distilled 2026-07-10 from what timeandeye
    /// actually sets (caption/caption2 dominate; monospaced variants carry
    /// timestamps and ids). Sibling apps use these NAMES so a family-wide
    /// retune is one edit here, not a hunt through call sites.
    package enum Fonts {
        /// Section and card headings.
        package static let heading = Font.headline
        /// Running text.
        package static let body = Font.body
        /// Emphasised interstitials — button rows, list group labels.
        package static let label = Font.callout
        /// Secondary text: explanations, row subtitles.
        package static let caption = Font.caption
        /// Fine print: counts, hints, footers.
        package static let detail = Font.caption2
        /// Monospaced caption — timestamps, short ids.
        package static let monoCaption = Font.system(.caption, design: .monospaced)
        /// Monospaced fine print — logs, hashes.
        package static let monoDetail = Font.system(.caption2, design: .monospaced)
    }
}

/// Compatibility spelling used throughout timeandeyeUI since 2026-07; new
/// code (and sibling apps) should reach the same value via
/// `AndeyeTheme.Colours.highlight`.
package enum AndeyeColors {
    package static let highlight = AndeyeTheme.Colours.highlight
}
