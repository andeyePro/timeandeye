import Foundation

/// The andeye brand mark as pure geometry: an ampersand drawn in one
/// continuous stroke whose tail closes into an eye (andeye = "&eye").
/// Everything lives in a unit box (y up, 0…1) so the platform layers just
/// scale and stroke it — the AppKit renderer, checks and any future SwiftUI
/// use share these numbers. The stroke order IS the hand-drawing animation:
/// waist → top loop → waist (the crossing) → bottom loop → tail → upper
/// eyelid → lower eyelid, so revealing the path by arc length from its start
/// literally draws the ampersand and then closes its end into the eye. The
/// pupil pops in over the last few percent.
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

    /// Everything a renderer needs for one animation frame. `stroke` is an
    /// open contiguous path to stroke; `pupil` is a closed path to fill
    /// (empty until the final reveal phase, or when a wink squashes it away).
    public struct Frame: Equatable, Sendable {
        public var stroke: [Cubic]
        public var pupil: [Cubic]
        public init(stroke: [Cubic], pupil: [Cubic]) {
            self.stroke = stroke; self.pupil = pupil
        }
    }

    /// Stroke width as a fraction of the box side — thick enough that the
    /// mark still reads as "&" at menu-bar size (~18 pt → ~2.2 pt line).
    public static let strokeWidth = 0.11

    /// Eye midline and pupil, shared by the lids, the pupil and the checks.
    static let eyeY = 0.44
    static let eyeLeft = Point(0.64, 0.44)
    static let eyeRight = Point(0.96, 0.44)
    static let lidLift = 0.20
    static let pupilCentre = Point(0.80, 0.44)
    static let pupilRadius = 0.05
    /// Reveal fraction at which the pupil starts growing in.
    static let pupilPhase = 0.95

    /// The complete mark at eyelid closure `wink` (0 open … 1 shut). The
    /// first 8 segments are the ampersand body + tail; the last 2 are the
    /// eyelids, so they are the final phase of any arc-length reveal.
    public static func fullStroke(wink: Double) -> [Cubic] {
        let lift = lidLift * (1 - wink)
        return [
            // waist up the left of the small top loop
            Cubic(Point(0.40, 0.52), Point(0.31, 0.55), Point(0.20, 0.62), Point(0.20, 0.74)),
            Cubic(Point(0.20, 0.74), Point(0.20, 0.83), Point(0.27, 0.90), Point(0.36, 0.90)),
            Cubic(Point(0.36, 0.90), Point(0.45, 0.90), Point(0.52, 0.83), Point(0.52, 0.74)),
            Cubic(Point(0.52, 0.74), Point(0.52, 0.65), Point(0.48, 0.58), Point(0.40, 0.52)),
            // cross the waist and round the big bottom loop
            Cubic(Point(0.40, 0.52), Point(0.32, 0.46), Point(0.09, 0.42), Point(0.09, 0.30)),
            Cubic(Point(0.09, 0.30), Point(0.09, 0.17), Point(0.20, 0.06), Point(0.33, 0.06)),
            Cubic(Point(0.33, 0.06), Point(0.46, 0.06), Point(0.57, 0.17), Point(0.57, 0.30)),
            // tail flicks out right, into the eye's inner corner
            Cubic(Point(0.57, 0.30), Point(0.57, 0.38), Point(0.585, 0.44), eyeLeft),
            // the end closes into the eye: upper lid out, lower lid back
            Cubic(eyeLeft, Point(0.71, eyeY + lift), Point(0.89, eyeY + lift), eyeRight),
            Cubic(eyeRight, Point(0.89, eyeY - lift), Point(0.71, eyeY - lift), eyeLeft),
        ]
    }

    /// Segment count of the ampersand body (everything before the lids).
    public static let bodySegmentCount = 8

    static func pupilPath(scale: Double, wink: Double) -> [Cubic] {
        let rx = pupilRadius * scale
        let ry = rx * max(0, 1 - 1.2 * wink)   // lids squash it shut before they meet
        guard rx > 0.004, ry > 0.004 else { return [] }
        let k = 0.5523
        let c = pupilCentre
        let e = Point(c.x + rx, c.y), n = Point(c.x, c.y + ry)
        let w = Point(c.x - rx, c.y), s = Point(c.x, c.y - ry)
        return [
            Cubic(e, Point(e.x, c.y + k * ry), Point(c.x + k * rx, n.y), n),
            Cubic(n, Point(c.x - k * rx, n.y), Point(w.x, c.y + k * ry), w),
            Cubic(w, Point(w.x, c.y - k * ry), Point(c.x - k * rx, s.y), s),
            Cubic(s, Point(c.x + k * rx, s.y), Point(e.x, c.y - k * ry), e),
        ]
    }

    /// One animation frame. `t` reveals the stroke by arc length from its
    /// start (0 = nothing, 1 = the full mark); `wink` closes the eyelids
    /// (0 = open … 1 = shut). Both clamp to [0, 1].
    public static func frame(t rawT: Double, wink rawWink: Double = 0) -> Frame {
        let t = min(max(rawT, 0), 1)
        let wink = min(max(rawWink, 0), 1)
        let segs = fullStroke(wink: wink)
        let pupilScale = min(max((t - pupilPhase) / (1 - pupilPhase), 0), 1)
        return Frame(stroke: revealed(segs, fraction: t),
                     pupil: pupilPath(scale: pupilScale, wink: wink))
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
