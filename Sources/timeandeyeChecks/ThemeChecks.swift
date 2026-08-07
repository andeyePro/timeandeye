#if os(macOS)
import Foundation
import SwiftUI
import timeandeyeCore
import timeandeyeTheme

func andeyeThemeChecks(_ c: Checks) {
    // The geometry itself is covered by the AndeyeLogo suite; these checks
    // pin the THEME contract sibling andeye apps build against — the
    // shape must render the Core geometry into any rect without drift, and
    // the compatibility spelling must stay pointed at the theme value.

    /// The rendered path's elements as `AndeyeLogo.Cubic`s — cubics verbatim,
    /// moves/lines degree-elevated to point/line cubics (identical sampled
    /// geometry) — so the AndeyeLogo suite's `curveBBox` is the one bezier
    /// evaluator for both suites.
    func pathCubics(_ path: Path) -> [AndeyeLogo.Cubic] {
        func pt(_ p: CGPoint) -> AndeyeLogo.Point { .init(Double(p.x), Double(p.y)) }
        var segs: [AndeyeLogo.Cubic] = []
        var current = CGPoint.zero
        path.forEach { element in
            switch element {
            case .move(let p):
                current = p
                segs.append(.init(pt(p), pt(p), pt(p), pt(p)))
            case .line(let p), .quadCurve(let p, _):
                segs.append(.init(pt(current), pt(current), pt(p), pt(p)))
                current = p
            case .curve(let p, let c1, let c2):
                segs.append(.init(pt(current), pt(c1), pt(c2), pt(p)))
                current = p
            case .closeSubpath:
                break
            }
        }
        return segs
    }

    /// Bounding box of the rendered CURVES (sampled), not Path.boundingRect —
    /// the control points legitimately roam outside the mark's box (see
    /// `curveBBox` in the AndeyeLogo suite, which does the sampling).
    func sampledBBox(_ path: Path) -> CGRect {
        let segs = pathCubics(path)
        guard !segs.isEmpty else { return .null }
        let b = curveBBox(segs)
        return CGRect(x: b.minX, y: b.minY,
                      width: b.maxX - b.minX, height: b.maxY - b.minY)
    }

    c.check("the path IS the Core geometry, scaled and centred into the rect") {
        // Contract: AndeyeMark faithfully maps AndeyeLogo's unit-width y-up
        // box into the rect (scale by width, centre, flip y) — no drift, no
        // squash. Compute the expected bbox from Core and compare against
        // the rendered path's sampled bbox.
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        var xs: [Double] = [], ys: [Double] = []
        for s in AndeyeLogo.stroke(t: 1) {
            for i in 0...48 {
                let p = AndeyeLogo.point(on: s, at: Double(i) / 48)
                xs.append(p.x); ys.append(p.y)
            }
        }
        let scale = 200.0                       // min(200, 200/aspect) = 200
        let x0 = 100 - scale / 2                // rect.midX - scale/2
        let y0 = 100 + scale * AndeyeLogo.aspect / 2
        let box = sampledBBox(AndeyeMark(t: 1, wink: 0).path(in: rect))
        try expect(box.minX >= rect.minX - 1e-6 && box.maxX <= rect.maxX + 1e-6,
                   "x overflow: \(box)")
        try expect(box.minY >= rect.minY - 1e-6 && box.maxY <= rect.maxY + 1e-6,
                   "y overflow: \(box)")
        try expectClose(Double(box.minX), x0 + xs.min()! * scale, accuracy: 0.5)
        try expectClose(Double(box.maxX), x0 + xs.max()! * scale, accuracy: 0.5)
        try expectClose(Double(box.minY), y0 - ys.max()! * scale, accuracy: 0.5)
        try expectClose(Double(box.maxY), y0 - ys.min()! * scale, accuracy: 0.5)
    }

    c.check("t: 0 draws nothing; wink moves the lids, not the footprint") {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        try expect(AndeyeMark(t: 0).path(in: rect).isEmpty)
        let open = AndeyeMark(t: 1, wink: 0).path(in: rect)
        let shut = AndeyeMark(t: 1, wink: 1).path(in: rect)
        try expect(open.description != shut.description, "wink must move the lids")
        // A wink is an eyelid close, not a redraw: the sampled footprint
        // holds still (lid travel is ~2 SVG units of 365; the shut eye sits
        // slightly higher than the open lower lid).
        let a = sampledBBox(open), b = sampledBBox(shut)
        try expect(abs(a.width - b.width) < 6 && abs(a.minX - b.minX) < 6,
                   "wink moved the mark's footprint: \(a) vs \(b)")
    }

    c.check("stroke style scales with the SVG's 17/365 line weight") {
        try expectClose(Double(AndeyeMark.strokeStyle(for: 365).lineWidth), 17,
                        accuracy: 1e-9)
        try expectClose(AndeyeMark.aspect, 235.0 / 365.0, accuracy: 1e-12)
    }

    c.check("compatibility spelling AndeyeColors.highlight IS the theme colour") {
        // One value, two names — if these ever diverge the UI's foreground
        // contrast splits from the theme sibling apps consume.
        try expectEq(AndeyeColors.highlight, AndeyeTheme.Colours.highlight)
    }
}
#endif
