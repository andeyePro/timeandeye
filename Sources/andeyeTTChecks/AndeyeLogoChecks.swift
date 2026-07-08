import Foundation
import andeyeTTCore

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

    /// y of the segment's curve nearest a given x — the lids are x-monotone
    /// over the eye's span, so nearest-x sampling reads off "the lid's height
    /// at x" without solving the cubic.
    func yAt(_ s: AndeyeLogo.Cubic, x: Double) -> Double {
        var best = 0.0
        var nearest = Double.infinity
        for i in 0...400 {
            let p = AndeyeLogo.point(on: s, at: Double(i) / 400)
            if abs(p.x - x) < nearest { nearest = abs(p.x - x); best = p.y }
        }
        return best
    }

    c.check("a wink closes the eyelids: flourish sweep and corners fixed, the TAIL retracts into the corner") {
        let open = AndeyeLogo.fullStroke(wink: 0)
        // The corner both lids hinge at: the crossing of the two & strokes
        // (Martin, 2026-07-08: a winking eye is a single loop — the tail
        // exists only where the draw-on starts). Normalised like the mark.
        let cornerX = (121.11 + 18.0915) / 365.0
        let cornerY = (235.0 - (138.06 + 17.9436)) / 365.0
        for wink in [0.5, 1.0] {
            let shut = AndeyeLogo.fullStroke(wink: wink)
            // The flourish's SWEEP is stationary: segment 0's controls and
            // far end, and all of segment 1, never move. Its START is the
            // tail — that retracts toward the corner with the wink.
            try expectEq(shut[0].c1, open[0].c1, "wink \(wink) moved flourish control 1:")
            try expectEq(shut[0].c2, open[0].c2, "wink \(wink) moved flourish control 2:")
            try expectEq(shut[0].p1, open[0].p1, "wink \(wink) moved the flourish's far end:")
            try expectEq(shut[1], open[1], "wink \(wink) moved left segment 1:")
            // The top lid's endpoints (both eye corners) are pinned, and the
            // bottom lid still starts at the right corner.
            try expectEq(shut[2].p0, open[2].p0, "wink \(wink) moved the left corner:")
            try expectEq(shut[2].p1, open[2].p1, "wink \(wink) moved the right corner:")
            try expectEq(shut[3].p0, open[3].p0, "wink \(wink) moved segment 3 start:")
        }
        // At FULL wink both the bottom lid's end and the tail's start sit
        // exactly ON the corner: a single loop, no tail left behind.
        let shut = AndeyeLogo.fullStroke(wink: 1)
        try expectClose(shut[3].p1.x, cornerX, accuracy: 1e-9, "bottom-lid end x off corner:")
        try expectClose(shut[3].p1.y, cornerY, accuracy: 1e-9, "bottom-lid end y off corner:")
        try expectClose(shut[0].p0.x, cornerX, accuracy: 1e-9, "tail start x off corner:")
        try expectClose(shut[0].p0.y, cornerY, accuracy: 1e-9, "tail start y off corner:")
        // Footprint: the mark's width never changes during a blink (the
        // tail sits well inside the flourish's horizontal extent).
        let a = curveBBox(open), b = curveBBox(shut)
        try expectClose(b.maxX - b.minX, a.maxX - a.minX, accuracy: 1e-9,
                        "full wink changed the width:")
    }

    c.check("the top lid comes down a lot, the bottom lid up a little, monotonically") {
        let midX = (228.0 + 18.0915) / 365   // mid-eye (SVG x = 228), normalised
        let open = AndeyeLogo.fullStroke(wink: 0)
        let shut = AndeyeLogo.fullStroke(wink: 1)
        let drop = yAt(open[2], x: midX) - yAt(shut[2], x: midX)   // y up
        let rise = yAt(shut[3], x: midX) - yAt(open[3], x: midX)
        try expect(drop > 0.15, "top lid barely moved: \(drop)")
        try expect(rise > 0.01 && rise < 0.08, "bottom lid should rise a LITTLE: \(rise)")
        try expect(rise < drop / 3, "lids moved comparably — top must dominate: \(rise) vs \(drop)")
        // Each lid moves one way only as the wink progresses — no bounce.
        var top = yAt(open[2], x: midX)
        var bottom = yAt(open[3], x: midX)
        for k in 1...10 {
            let segs = AndeyeLogo.fullStroke(wink: Double(k) / 10)
            let t = yAt(segs[2], x: midX), b = yAt(segs[3], x: midX)
            try expect(t <= top + 1e-9, "top lid rose mid-wink at step \(k)")
            try expect(b >= bottom - 1e-9, "bottom lid dropped mid-wink at step \(k)")
            top = t
            bottom = b
        }
    }

    c.check("at full wink the lids meet along one slightly-smiling line") {
        let shut = AndeyeLogo.fullStroke(wink: 1)
        let leftCorner = shut[3].p1, rightCorner = shut[3].p0
        // Max vertical separation between the lids over the eye's span stays
        // well under the stroke width, so the two curves render as ONE line.
        var maxGap = 0.0
        var samples = 0
        var x = leftCorner.x + 0.02
        while x < rightCorner.x - 0.02 {
            maxGap = max(maxGap, abs(yAt(shut[2], x: x) - yAt(shut[3], x: x)))
            x += 0.01
            samples += 1
        }
        try expect(samples > 20, "gap scan sampled too few points")
        try expect(maxGap < AndeyeLogo.strokeWidth / 3,
                   "lids don't meet: gap \(maxGap) vs stroke \(AndeyeLogo.strokeWidth)")
        // The meeting line is a slightly positive curve: its middle sags
        // gently below the corner-to-corner chord (y up), like ‿ — never
        // above the chord, and never deeply below it.
        let midX = (leftCorner.x + rightCorner.x) / 2
        let chordY = leftCorner.y + (rightCorner.y - leftCorner.y)
            * (midX - leftCorner.x) / (rightCorner.x - leftCorner.x)
        let sag = chordY - yAt(shut[3], x: midX)
        try expect(sag > 0.02 && sag < 0.12, "closed line should sag gently: \(sag)")
    }

    c.check("a full wink still leaves a visible (non-degenerate) mark") {
        let b = curveBBox(AndeyeLogo.stroke(t: 1, wink: 1))
        try expect(b.maxY - b.minY > 0.01, "full wink flattened the mark to nothing")
    }

    c.check("t and wink clamp to [0, 1]") {
        try expectEq(AndeyeLogo.stroke(t: 2, wink: -1), AndeyeLogo.stroke(t: 1, wink: 0))
        try expectEq(AndeyeLogo.stroke(t: -1, wink: 2), AndeyeLogo.stroke(t: 0, wink: 1))
        try expect(AndeyeLogo.stroke(t: -1).isEmpty)
    }
}
