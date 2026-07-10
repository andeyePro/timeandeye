import SwiftUI
import timeandeyeCore

/// The andeye eye-mark as a SwiftUI `Shape`: the brand ampersand-eye,
/// geometry verbatim from `AndeyeLogo` (timeandeyeCore, itself hardcoded
/// from assets/brand/andeye.svg). `t` reveals the stroke by arc length
/// (0 nothing … 1 full mark, the "draw-on"); `wink` closes the eyelids
/// (0 open … 1 shut). Both animate.
///
/// Stroke it — never fill: the mark is one continuous line. Use
/// `AndeyeMark.strokeStyle(for:)` so the line weight scales with the
/// rendered size exactly as the SVG intends.
public struct AndeyeMark: Shape {
    public var t: Double
    public var wink: Double

    public init(t: Double = 1, wink: Double = 0) {
        self.t = t
        self.wink = wink
    }

    public var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(t, wink) }
        set { t = newValue.first; wink = newValue.second }
    }

    /// The SVG stroke width for a mark rendered `width` points wide.
    public static func strokeStyle(for width: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: width * AndeyeLogo.strokeWidth,
                    lineCap: .round, lineJoin: .round)
    }

    /// Height/width of the mark's box (the SVG's 235:365).
    public static let aspect = AndeyeLogo.aspect

    public func path(in rect: CGRect) -> Path {
        let segs = AndeyeLogo.stroke(t: t, wink: wink)
        guard let first = segs.first else { return Path() }
        // Fit the unit-width, `aspect`-tall (y-up) box into rect, centred,
        // preserving aspect; flip y for screen space.
        let scale = min(rect.width, rect.height / AndeyeLogo.aspect)
        let x0 = rect.midX - scale / 2
        let y0 = rect.midY + scale * AndeyeLogo.aspect / 2
        func at(_ p: AndeyeLogo.Point) -> CGPoint {
            CGPoint(x: x0 + p.x * scale, y: y0 - p.y * scale)
        }
        var path = Path()
        path.move(to: at(first.p0))
        for seg in segs {
            path.addCurve(to: at(seg.p1), control1: at(seg.c1), control2: at(seg.c2))
        }
        return path
    }
}

/// Convenience view: the mark stroked in a colour, aspect-locked. For the
/// hero/hello pose use `AndeyeTheme.Colours.brandAccent`.
public struct AndeyeMarkView: View {
    public var t: Double
    public var wink: Double
    public var colour: Color

    public init(t: Double = 1, wink: Double = 0,
                colour: Color = AndeyeTheme.Colours.brandAccent) {
        self.t = t
        self.wink = wink
        self.colour = colour
    }

    public var body: some View {
        GeometryReader { proxy in
            AndeyeMark(t: t, wink: wink)
                .stroke(colour, style: AndeyeMark.strokeStyle(
                    for: min(proxy.size.width, proxy.size.height / AndeyeMark.aspect)))
        }
        .aspectRatio(1 / AndeyeMark.aspect, contentMode: .fit)
    }
}
