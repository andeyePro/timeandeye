import Foundation

/// The andeye brand mark, hardcoded verbatim from assets/brand/andeye.svg:
/// one closed stroked path — a sweeping single-line ampersand whose right
/// side closes into an almond/eye shape (andeye = "&eye"). The SVG's four
/// cubic segments are kept exactly (translate applied, then normalised to a
/// unit-WIDTH box preserving the 365:235 aspect, y up), so the platform
/// layers just scale and stroke them. Revealing the path by arc length from
/// its M point hand-draws the mark; a wink is an eyelid close — the left
/// side and the eye's corners stay fixed while the top lid sweeps down and
/// the bottom lid rises a little, the two meeting along one gentle ‿ arc.
public enum AndeyeLogo {

    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    /// One cubic bezier segment: p0 → p1 steered by c1/c2.
    public struct Cubic: Equatable, Sendable {
        public var p0: Point
        public var c1: Point
        public var c2: Point
        public var p1: Point
        public init(_ p0: Point, _ c1: Point, _ c2: Point, _ p1: Point) {
            self.p0 = p0; self.c1 = c1; self.c2 = c2; self.p1 = p1
        }
    }

    // MARK: - The mark, verbatim from the SVG

    /// SVG viewBox is 365 × 235; everything normalises by the WIDTH, so the
    /// mark lives in a box 1 wide and `aspect` tall (y up).
    public static let aspect = 235.0 / 365.0

    /// Stroke width from the SVG (17px on a 365-wide viewBox), as a fraction
    /// of the box width.
    public static let strokeWidth = 17.0 / 365.0

    /// The SVG's group transform: translate(18.0915, 17.9436).
    static let translate = Point(18.0915, 17.9436)

    /// d="M145,157 C-95,-27 177,-2 59,76 C-37.95,140.08 54,236 122,137
    ///    C205.86,14.91 311,137 311,137 C311,137 232,221 145,157 Z"
    /// (Z is degenerate: the last cubic already returns to the M point.)
    static let svgCubics: [(Point, Point, Point, Point)] = [
        (Point(145, 157), Point(-95, -27), Point(177, -2), Point(59, 76)),
        (Point(59, 76), Point(-37.95, 140.08), Point(54, 236), Point(122, 137)),
        (Point(122, 137), Point(205.86, 14.91), Point(311, 137), Point(311, 137)),
        (Point(311, 137), Point(311, 137), Point(232, 221), Point(145, 157)),
    ]

    /// SVG user space (y down) → unit-width box (y up).
    static func normalised(_ p: Point) -> Point {
        Point((p.x + translate.x) / 365.0,
              (235.0 - (p.y + translate.y)) / 365.0)
    }

    /// Closed-eye pose (SVG space). Only the two lid segments' CONTROL points
    /// move — every endpoint (the eye's corners at (311,137) and (145,157),
    /// and the top lid's junction with the left side at (122,137)) is fixed,
    /// and segments 0-1 (the left side) never change at all. The bottom lid
    /// rises a little; the top-lid values are a least-squares fit of its
    /// cubic (endpoints pinned) onto the reversed closed bottom lid, so at
    /// wink 1 the lids lie along the same gentle ‿ arc — max separation
    /// ~1.6 SVG units against a 17-unit stroke, i.e. they render as one line.
    static let topLidClosed = (c1: Point(171.03, 187.18), c2: Point(258.9, 178.05))
    static let bottomLidClosed = (c1: Point(311, 141), c2: Point(232, 196))

    /// The complete mark at blink amount `wink` (0 open … 1 shut): an eyelid
    /// close, not a squash. The lid control points lerp toward the closed
    /// pose above; everything else is untouched, so the mark's footprint and
    /// the left half of the ampersand hold perfectly still through a blink.
    public static func fullStroke(wink: Double) -> [Cubic] {
        let w = min(max(wink, 0), 1)
        func lerp(_ a: Point, _ b: Point) -> Point {
            Point(a.x + (b.x - a.x) * w, a.y + (b.y - a.y) * w)
        }
        var svg = svgCubics
        svg[2].1 = lerp(svg[2].1, topLidClosed.c1)
        svg[2].2 = lerp(svg[2].2, topLidClosed.c2)
        svg[3].1 = lerp(svg[3].1, bottomLidClosed.c1)
        svg[3].2 = lerp(svg[3].2, bottomLidClosed.c2)
        return svg.map { Cubic(normalised($0.0), normalised($0.1),
                               normalised($0.2), normalised($0.3)) }
    }

    /// The mark revealed by arc length from its M point. `t` = 0 shows
    /// nothing, 1 the full closed mark; `wink` closes the eyelids as above.
    /// Both clamp to [0, 1].
    public static func stroke(t rawT: Double, wink rawWink: Double = 0) -> [Cubic] {
        let t = min(max(rawT, 0), 1)
        let wink = min(max(rawWink, 0), 1)
        return revealed(fullStroke(wink: wink), fraction: t)
    }

    // MARK: - Bezier arithmetic (exposed for the checks)

    public static func point(on c: Cubic, at u: Double) -> Point {
        let v = 1 - u
        let a = v * v * v, b = 3 * v * v * u, d = 3 * v * u * u, e = u * u * u
        return Point(a * c.p0.x + b * c.c1.x + d * c.c2.x + e * c.p1.x,
                     a * c.p0.y + b * c.c1.y + d * c.c2.y + e * c.p1.y)
    }

    /// Flattened (24-sample) arc length — plenty for reveal timing.
    public static func length(of c: Cubic) -> Double {
        var total = 0.0
        var prev = c.p0
        for i in 1...24 {
            let p = point(on: c, at: Double(i) / 24)
            total += ((p.x - prev.x) * (p.x - prev.x)
                + (p.y - prev.y) * (p.y - prev.y)).squareRoot()
            prev = p
        }
        return total
    }

    public static func length(of segs: [Cubic]) -> Double {
        segs.reduce(0) { $0 + length(of: $1) }
    }

    /// Leading part of `c` up to parameter `u` (de Casteljau split).
    static func split(_ c: Cubic, at u: Double) -> Cubic {
        func lerp(_ a: Point, _ b: Point) -> Point {
            Point(a.x + (b.x - a.x) * u, a.y + (b.y - a.y) * u)
        }
        let q0 = lerp(c.p0, c.c1), q1 = lerp(c.c1, c.c2), q2 = lerp(c.c2, c.p1)
        let r0 = lerp(q0, q1), r1 = lerp(q1, q2)
        return Cubic(c.p0, q0, r0, lerp(r0, r1))
    }

    /// Parameter u whose leading arc length is `target` (sample-walked).
    static func parameter(forArcLength target: Double, on c: Cubic) -> Double {
        guard target > 0 else { return 0 }
        var acc = 0.0
        var prev = c.p0
        for i in 1...24 {
            let u = Double(i) / 24
            let p = point(on: c, at: u)
            let step = ((p.x - prev.x) * (p.x - prev.x)
                + (p.y - prev.y) * (p.y - prev.y)).squareRoot()
            if acc + step >= target {
                let inside = step > 0 ? (target - acc) / step : 0
                return u - (1 - inside) / 24
            }
            acc += step
            prev = p
        }
        return 1
    }

    /// First `fraction` of the path's total arc length, ending mid-segment
    /// via a bezier split so the reveal front moves smoothly.
    static func revealed(_ segs: [Cubic], fraction: Double) -> [Cubic] {
        guard fraction > 0 else { return [] }
        guard fraction < 1 else { return segs }
        let target = fraction * length(of: segs)
        var out: [Cubic] = []
        var acc = 0.0
        for seg in segs {
            let l = length(of: seg)
            if acc + l >= target {
                let u = parameter(forArcLength: target - acc, on: seg)
                if u > 1e-6 { out.append(split(seg, at: u)) }
                return out
            }
            out.append(seg)
            acc += l
        }
        return segs
    }
}
