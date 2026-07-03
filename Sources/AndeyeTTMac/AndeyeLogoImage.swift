import AppKit
import AndeyeTTCore

/// Renders an AndeyeLogo frame as the menu-bar icon. The drawing-handler
/// NSImage rasterises lazily at the screen's backing scale, so the mark is
/// crisp on retina without explicit 2x plumbing (same pattern as the old
/// certainty swatch). Non-template: the tint IS the certainty signal.
public enum AndeyeLogoImage {
    @MainActor
    public static func image(t: Double, wink: Double, colour: NSColor,
                             side: CGFloat = 18) -> NSImage {
        let frame = AndeyeLogo.frame(t: t, wink: wink)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let lineWidth = rect.width * AndeyeLogo.strokeWidth
            // Inset by half the stroke so round caps never clip at the edges.
            let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            func at(_ p: AndeyeLogo.Point) -> NSPoint {
                NSPoint(x: inset.minX + inset.width * p.x,
                        y: inset.minY + inset.height * p.y)
            }
            func path(_ segs: [AndeyeLogo.Cubic]) -> NSBezierPath {
                let path = NSBezierPath()
                guard let first = segs.first else { return path }
                path.move(to: at(first.p0))
                for seg in segs {
                    path.curve(to: at(seg.p1), controlPoint1: at(seg.c1),
                               controlPoint2: at(seg.c2))
                }
                return path
            }
            let stroke = path(frame.stroke)
            stroke.lineWidth = lineWidth
            stroke.lineCapStyle = .round
            stroke.lineJoinStyle = .round
            colour.setStroke()
            stroke.stroke()
            if !frame.pupil.isEmpty {
                colour.setFill()
                let pupil = path(frame.pupil)
                pupil.close()
                pupil.fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}
