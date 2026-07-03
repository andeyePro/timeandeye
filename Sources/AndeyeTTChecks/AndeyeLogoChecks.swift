import Foundation
import AndeyeTTCore

func andeyeLogoChecks(_ c: Checks) {
    /// Bounding box of the curves themselves (sampled), not the control
    /// points — the SVG's control points legitimately roam outside the box.
    func curveBBox(_ segs: [AndeyeLogo.Cubic]) -> (minX: Double, minY: Double,
                                                   maxX: Double, maxY: Double) {
        var xs: [Double] = [], ys: [Double] = []
        for s in segs {
            for i in 0...48 {
                let p = AndeyeLogo.point(on: s, at: Double(i) / 48)
                xs.append(p.x); ys.append(p.y)
            }
        }
        return (xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0)
    }

    c.check("the mark is the SVG's four cubics, contiguous") {
        let segs = AndeyeLogo.stroke(t: 1)
        try expectEq(segs.count, 4, "assets/brand/andeye.svg has four C commands:")
        for i in 1..<segs.count {
            try expectEq(segs[i].p0, segs[i - 1].p1, "segment \(i) starts where \(i - 1) ends:")
        }
    }

    c.check("the mark is a closed loop (end == start, the SVG's Z)") {
        let segs = AndeyeLogo.stroke(t: 1)
        try expectEq(segs.last!.p1, segs.first!.p0, "loop does not close:")
    }

    c.check("the curve stays inside the unit-width 365:235 box at any wink") {
        for wink in [0.0, 0.5, 1.0] {
            let b = curveBBox(AndeyeLogo.stroke(t: 1, wink: wink))
            try expect(b.minX >= 0 && b.minY >= 0
                && b.maxX <= 1 && b.maxY <= AndeyeLogo.aspect + 1e-9,
                "wink \(wink) escapes the box: \(b)")
        }
    }

    c.check("aspect and stroke width match the SVG source") {
        try expectClose(AndeyeLogo.aspect, 235.0 / 365.0, accuracy: 1e-12)
        try expectClose(AndeyeLogo.strokeWidth, 17.0 / 365.0, accuracy: 1e-12)
        // The mark genuinely uses its wide box: much wider than tall.
        let b = curveBBox(AndeyeLogo.stroke(t: 1))
        try expect((b.maxX - b.minX) / (b.maxY - b.minY) > 1.4,
                   "mark is not menu-bar wide: \(b)")
    }

    c.check("t=0 reveals nothing; t=1 reveals the whole mark") {
        try expect(AndeyeLogo.stroke(t: 0).isEmpty)
        try expectEq(AndeyeLogo.stroke(t: 1), AndeyeLogo.fullStroke(wink: 0))
    }

    c.check("t reveals arc length monotonically and in proportion") {
        let total = AndeyeLogo.length(of: AndeyeLogo.stroke(t: 1))
        try expect(total > 1, "a degenerate mark would pass every ratio test")
        var previous = 0.0
        for k in 0...20 {
            let t = Double(k) / 20
            let revealed = AndeyeLogo.length(of: AndeyeLogo.stroke(t: t))
            try expect(revealed >= previous - 1e-9, "shrank between t steps at t=\(t)")
            try expectClose(revealed / total, t, accuracy: 0.02,
                            "reveal is not linear in t at t=\(t):")
            previous = revealed
        }
    }

    c.check("a partial reveal is still contiguous and ends ON the full path") {
        let full = AndeyeLogo.fullStroke(wink: 0)
        for t in [0.15, 0.4, 0.65, 0.9] {
            let segs = AndeyeLogo.stroke(t: t)
            for i in 1..<segs.count {
                try expectEq(segs[i].p0, segs[i - 1].p1, "t=\(t) segment \(i):")
            }
            // The reveal front must lie on the source segment it was split
            // from, or the draw-on front would jump off the mark.
            let tip = segs.last!.p1
            let host = full[segs.count - 1]
            var nearest = Double.infinity
            for i in 0...48 {
                let p = AndeyeLogo.point(on: host, at: Double(i) / 48)
                let dx = p.x - tip.x
                let dy = p.y - tip.y
                nearest = min(nearest, (dx * dx + dy * dy).squareRoot())
            }
            try expect(nearest < 0.012, "t=\(t): reveal tip \(tip) is off the path by \(nearest)")
        }
    }

    c.check("a wink squashes the whole mark vertically, width preserved") {
        let open = curveBBox(AndeyeLogo.stroke(t: 1))
        for wink in [0.5, 1.0] {
            let b = curveBBox(AndeyeLogo.stroke(t: 1, wink: wink))
            let expected = 1 - AndeyeLogo.winkSquash * wink
            try expectClose(b.maxX - b.minX, open.maxX - open.minX, accuracy: 1e-9,
                            "wink \(wink) changed the width:")
            try expectClose((b.maxY - b.minY) / (open.maxY - open.minY), expected,
                            accuracy: 1e-9, "wink \(wink) squash factor:")
            // Squash is toward the box's vertical centre, so the mark's
            // vertical midline never drifts by more than the squash pulls it.
            try expectClose((b.minY + b.maxY) / 2,
                            AndeyeLogo.aspect / 2
                                + ((open.minY + open.maxY) / 2 - AndeyeLogo.aspect / 2) * expected,
                            accuracy: 1e-9, "wink \(wink) centre drift:")
        }
    }

    c.check("a full wink still leaves a visible (non-degenerate) mark") {
        let b = curveBBox(AndeyeLogo.stroke(t: 1, wink: 1))
        try expect(b.maxY - b.minY > 0.01, "full wink flattened the mark to nothing")
        try expect(AndeyeLogo.winkSquash < 1, "winkSquash must keep some height")
    }

    c.check("the wink only scales y — x coordinates are untouched") {
        let open = AndeyeLogo.fullStroke(wink: 0)
        let shut = AndeyeLogo.fullStroke(wink: 1)
        for (a, b) in zip(open, shut) {
            for (p, q) in [(a.p0, b.p0), (a.c1, b.c1), (a.c2, b.c2), (a.p1, b.p1)] {
                try expectEq(p.x, q.x, "wink moved a point horizontally:")
            }
        }
    }

    c.check("t and wink clamp to [0, 1]") {
        try expectEq(AndeyeLogo.stroke(t: 2, wink: -1), AndeyeLogo.stroke(t: 1, wink: 0))
        try expectEq(AndeyeLogo.stroke(t: -1, wink: 2), AndeyeLogo.stroke(t: 0, wink: 1))
        try expect(AndeyeLogo.stroke(t: -1).isEmpty)
    }
}
