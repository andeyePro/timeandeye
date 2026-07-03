import Foundation
import AndeyeTTCore

func andeyeLogoChecks(_ c: Checks) {
    func bbox(_ segs: [AndeyeLogo.Cubic]) -> (minX: Double, minY: Double,
                                              maxX: Double, maxY: Double) {
        var xs: [Double] = [], ys: [Double] = []
        for s in segs {
            for p in [s.p0, s.c1, s.c2, s.p1] { xs.append(p.x); ys.append(p.y) }
        }
        return (xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0)
    }

    c.check("the full stroke is one contiguous path") {
        let segs = AndeyeLogo.frame(t: 1).stroke
        try expect(segs.count > AndeyeLogo.bodySegmentCount, "body plus eyelids")
        for i in 1..<segs.count {
            try expectEq(segs[i].p0, segs[i - 1].p1, "segment \(i) starts where \(i - 1) ends:")
        }
    }

    c.check("every point (stroke and pupil) stays inside the unit box") {
        for wink in [0.0, 0.5, 1.0] {
            let f = AndeyeLogo.frame(t: 1, wink: wink)
            let s = bbox(f.stroke + f.pupil)
            try expect(s.minX >= 0 && s.minY >= 0 && s.maxX <= 1 && s.maxY <= 1,
                       "wink \(wink) escapes the box: \(s)")
        }
    }

    c.check("t=0 reveals nothing; t=1 reveals the whole mark") {
        try expect(AndeyeLogo.frame(t: 0).stroke.isEmpty)
        let full = AndeyeLogo.frame(t: 1).stroke
        try expectEq(full, AndeyeLogo.fullStroke(wink: 0))
    }

    c.check("t reveals arc length monotonically and in proportion") {
        let total = AndeyeLogo.length(of: AndeyeLogo.frame(t: 1).stroke)
        try expect(total > 1, "a degenerate mark would pass every ratio test")
        var previous = 0.0
        for k in 0...20 {
            let t = Double(k) / 20
            let revealed = AndeyeLogo.length(of: AndeyeLogo.frame(t: t).stroke)
            try expect(revealed >= previous - 1e-9, "shrank between t steps at t=\(t)")
            try expectClose(revealed / total, t, accuracy: 0.02,
                            "reveal is not linear in t at t=\(t):")
            previous = revealed
        }
    }

    c.check("a partial reveal is still contiguous and ends ON the full path") {
        let full = AndeyeLogo.fullStroke(wink: 0)
        for t in [0.15, 0.4, 0.65, 0.9] {
            let segs = AndeyeLogo.frame(t: t).stroke
            for i in 1..<segs.count {
                try expectEq(segs[i].p0, segs[i - 1].p1, "t=\(t) segment \(i):")
            }
            // The reveal front must lie on the source segment it was split
            // from, or the draw-on front would jump off the ampersand.
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

    c.check("the eyelids are the final drawing phase") {
        let full = AndeyeLogo.fullStroke(wink: 0)
        let body = AndeyeLogo.length(of: Array(full.prefix(AndeyeLogo.bodySegmentCount)))
        let fraction = body / AndeyeLogo.length(of: full)
        try expect(AndeyeLogo.frame(t: fraction - 0.02).stroke.count <= AndeyeLogo.bodySegmentCount,
                   "lids appeared before the body finished")
        try expect(AndeyeLogo.frame(t: fraction + 0.02).stroke.count > AndeyeLogo.bodySegmentCount,
                   "lids missing after the body finished")
    }

    c.check("the pupil pops in only at the very end of the reveal") {
        try expect(AndeyeLogo.frame(t: 0.9).pupil.isEmpty, "pupil arrived early")
        let pupil = AndeyeLogo.frame(t: 1).pupil
        try expectEq(pupil.count, 4, "closed 4-arc circle:")
        for i in 1..<pupil.count {
            try expectEq(pupil[i].p0, pupil[i - 1].p1, "pupil arc \(i):")
        }
        try expectEq(pupil.last!.p1, pupil.first!.p0, "pupil closes:")
    }

    c.check("the pupil sits inside the eye outline") {
        let f = AndeyeLogo.frame(t: 1)
        let lids = bbox(Array(f.stroke.suffix(f.stroke.count - AndeyeLogo.bodySegmentCount)))
        let pupil = bbox(f.pupil)
        try expect(pupil.minX > lids.minX && pupil.maxX < lids.maxX
            && pupil.minY > lids.minY && pupil.maxY < lids.maxY,
            "pupil \(pupil) outside lids \(lids)")
    }

    c.check("a full wink closes the lids onto the midline and hides the pupil") {
        let f = AndeyeLogo.frame(t: 1, wink: 1)
        let lids = bbox(Array(f.stroke.suffix(f.stroke.count - AndeyeLogo.bodySegmentCount)))
        try expectClose(lids.maxY - lids.minY, 0, accuracy: 1e-9, "lids not shut:")
        try expect(f.pupil.isEmpty, "pupil visible through a shut eye")
    }

    c.check("a half wink keeps the (squashed) pupil under the lids") {
        let f = AndeyeLogo.frame(t: 1, wink: 0.5)
        let lids = bbox(Array(f.stroke.suffix(f.stroke.count - AndeyeLogo.bodySegmentCount)))
        let pupil = bbox(f.pupil)
        try expect(!f.pupil.isEmpty, "half-shut eye lost its pupil entirely")
        try expect(pupil.minY > lids.minY && pupil.maxY < lids.maxY,
                   "pupil \(pupil) peeks past half-shut lids \(lids)")
        let open = bbox(AndeyeLogo.frame(t: 1).pupil)
        try expect(pupil.maxY - pupil.minY < open.maxY - open.minY,
                   "wink did not squash the pupil")
        try expectClose(pupil.maxX - pupil.minX, open.maxX - open.minX, accuracy: 1e-9,
                        "squash should be vertical only:")
    }

    c.check("t and wink clamp to [0, 1]") {
        try expectEq(AndeyeLogo.frame(t: 2, wink: -1), AndeyeLogo.frame(t: 1, wink: 0))
        try expectEq(AndeyeLogo.frame(t: -1, wink: 2), AndeyeLogo.frame(t: 0, wink: 1))
        try expect(AndeyeLogo.frame(t: -1).stroke.isEmpty)
    }

    c.check("the wink never moves the ampersand body, only the lids") {
        let open = AndeyeLogo.fullStroke(wink: 0)
        let shut = AndeyeLogo.fullStroke(wink: 1)
        try expectEq(Array(open.prefix(AndeyeLogo.bodySegmentCount)),
                     Array(shut.prefix(AndeyeLogo.bodySegmentCount)))
    }
}
