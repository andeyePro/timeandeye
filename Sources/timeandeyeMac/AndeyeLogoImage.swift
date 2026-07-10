import AppKit
import timeandeyeCore
import timeandeyeTheme

/// Renders the andeye mark — and, via `label`, the ENTIRE menu-bar item
/// (mark + elapsed text) — as one NSImage. The drawing-handler NSImage
/// rasterises lazily at the screen's backing scale, so everything is crisp
/// on retina without explicit 2x plumbing. Non-template: the tint IS the
/// certainty signal.
///
/// Why the text lives INSIDE the image (Martin, 2026-07-08, third jiggle
/// report): every SwiftUI-side width defence — figure-space pad,
/// .monospacedDigit(), hidden sizing templates, measured minWidth — still
/// left the icon moving on seconds ticks, because the MenuBarExtra label's
/// rendering doesn't reliably honour the layout SwiftUI computes. One image
/// whose width WE compute (mark + gap + reserved text width, all measured
/// with the same font the text is drawn in) cannot reflow: the item's width
/// changes only when the reservation itself changes (bracket transitions),
/// never on a digit tick.
public enum AndeyeLogoImage {
    /// The font both measurement and drawing use — a mismatch here is
    /// exactly the bug this type exists to kill.
    public static var menuFont: NSFont {
        .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    }

    public static func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: menuFont]).width
    }

    /// The calendar alerts' fixed target tint (the pre-meeting pulse and
    /// the meeting-start flash both LERP toward it) — a warm amber,
    /// deliberately distinct from the certainty gradient `menuColour`
    /// already carries, so an alert reads as "a different KIND of signal"
    /// at a glance rather than a certainty dip.
    public static let flashTint = NSColor(hex: "#FF9F0A") ?? .systemOrange

    @MainActor
    public static func image(t: Double, wink: Double, colour: NSColor, flash: Double = 0,
                             height: CGFloat = 18) -> NSImage {
        label(t: t, wink: wink, colour: colour, flash: flash, text: "", reservedTextWidth: 0,
              height: height)
    }

    /// The full menu-bar label. `reservedTextWidth` is the width the text
    /// column occupies regardless of the current string (the widest sizing
    /// candidate, measured with `menuFont`); the actual text draws
    /// leading-aligned inside it. `flash` (0...1) LERPs the mark's tint
    /// toward `flashTint` — the calendar alerts' pose (quiet pre-meeting
    /// pulse, violent meeting-start flash); 0 (the default) leaves `colour`
    /// untouched, so every existing caller is unaffected.
    @MainActor
    public static func label(t: Double, wink: Double, colour: NSColor, flash: Double = 0,
                             text: String, reservedTextWidth: CGFloat,
                             height: CGFloat = 18) -> NSImage {
        let strokeColour = flash > 0 ? blend(colour, toward: flashTint, amount: flash) : colour
        let segs = AndeyeLogo.stroke(t: t, wink: wink)
        let logoWidth = (height / AndeyeLogo.aspect).rounded()
        // Tightened 4 → 2 (Martin, 2026-07-08: "closer to the text") — the
        // mark's right side is an eye outline with visual whitespace of its
        // own, so a slim gap reads right.
        let gap: CGFloat = 2
        // Defensive max: the reservation comes from the same font, so the
        // live text can never exceed it — but if it ever did, growing beats
        // clipping (and the growth would be a bug to chase, not a crop).
        let column = text.isEmpty ? 0 : max(reservedTextWidth, textWidth(text)).rounded(.up)
        let size = NSSize(width: logoWidth + (column > 0 ? gap + column : 0),
                          height: height)
        let font = menuFont
        let image = NSImage(size: size, flipped: false) { _ in
            // The mark, in its box at the left edge (same maths as ever).
            let rect = NSRect(x: 0, y: 0, width: logoWidth, height: height)
            let lineWidth = rect.width * AndeyeLogo.strokeWidth
            let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let scale = min(inset.width, inset.height / AndeyeLogo.aspect)
            let originX = inset.midX - scale / 2
            let originY = inset.midY - scale * AndeyeLogo.aspect / 2
            func at(_ p: AndeyeLogo.Point) -> NSPoint {
                NSPoint(x: originX + scale * p.x, y: originY + scale * p.y)
            }
            if let first = segs.first {
                let path = NSBezierPath()
                path.move(to: at(first.p0))
                for seg in segs {
                    path.curve(to: at(seg.p1), controlPoint1: at(seg.c1),
                               controlPoint2: at(seg.c2))
                }
                path.lineWidth = scale * AndeyeLogo.strokeWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                strokeColour.setStroke()
                path.stroke()
            }
            // The text, leading-aligned in its reserved column. labelColor
            // resolves at draw time, so it tracks the menu bar's appearance.
            if !text.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: NSColor.labelColor,
                ]
                let textSize = (text as NSString).size(withAttributes: attributes)
                (text as NSString).draw(
                    at: NSPoint(x: logoWidth + gap,
                                y: ((height - textSize.height) / 2).rounded()),
                    withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Linear component blend, `amount` clamped to 0...1 — same shape as
    /// `MenuTitle.colour`'s low/high certainty blend, reused here for the
    /// flash instead of a second bespoke lerp.
    private static func blend(_ from: NSColor, toward: NSColor, amount: Double) -> NSColor {
        let f = CGFloat(min(max(amount, 0), 1))
        let a = from.usingColorSpace(.deviceRGB) ?? from
        let b = toward.usingColorSpace(.deviceRGB) ?? toward
        return NSColor(red: a.redComponent + (b.redComponent - a.redComponent) * f,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * f,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * f,
                       alpha: 1)
    }
}
