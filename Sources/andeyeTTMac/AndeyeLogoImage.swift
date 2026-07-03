import AppKit
import andeyeTTCore

/// Renders the andeye mark as the menu-bar icon. The drawing-handler NSImage
/// rasterises lazily at the screen's backing scale, so the mark is crisp on
/// retina without explicit 2x plumbing (same pattern as the old certainty
/// swatch). Non-template: the tint IS the certainty signal. The mark is wide
/// (365:235), so the image is `height` tall and proportionally wider.
public enum AndeyeLogoImage {
    @MainActor
    public static func image(t: Double, wink: Double, colour: NSColor,
                             height: CGFloat = 18) -> NSImage {
        let segs = AndeyeLogo.stroke(t: t, wink: wink)
        let size = NSSize(width: (height / AndeyeLogo.aspect).rounded(),
                          height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            // Uniform scale: the unit-width box (1 × aspect) fits the rect
            // inset by half the stroke, so round caps never clip at the edges.
            let lineWidth = rect.width * AndeyeLogo.strokeWidth
            let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let scale = min(inset.width, inset.height / AndeyeLogo.aspect)
            let originX = inset.midX - scale / 2
            let originY = inset.midY - scale * AndeyeLogo.aspect / 2
            func at(_ p: AndeyeLogo.Point) -> NSPoint {
                NSPoint(x: originX + scale * p.x, y: originY + scale * p.y)
            }
            guard let first = segs.first else { return true }
            let path = NSBezierPath()
            path.move(to: at(first.p0))
            for seg in segs {
                path.curve(to: at(seg.p1), controlPoint1: at(seg.c1),
                           controlPoint2: at(seg.c2))
            }
            path.lineWidth = scale * AndeyeLogo.strokeWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            colour.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
