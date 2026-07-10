import Foundation
import SwiftUI
import timeandeyeCore
import timeandeyeTheme

func andeyeThemeChecks(_ c: Checks) {
    // The geometry itself is covered by the AndeyeLogo suite; these checks
    // pin the THEME contract sibling apps (a sibling andeye app) build against — the
    // shape must render the Core geometry into any rect without drift, and
    // the compatibility spelling must stay pointed at the theme value.

    /// Bounding box of the rendered CURVES (sampled), not Path.boundingRect —
    /// the control points legitimately roam outside the mark's box (same
    /// reasoning as the AndeyeLogo suite's curveBBox).
    func sampledBBox(_ path: Path) -> CGRect {
        var xs: [CGFloat] = [], ys: [CGFloat] = []
        var current = CGPoint.zero
        path.forEach { element in
            switch element {
            case .move(let p):
                current = p
                xs.append(p.x); ys.append(p.y)
            case .line(let p):
                current = p
                xs.append(p.x); ys.append(p.y)
            case .curve(let p, let c1, let c2):
                for i in 0...48 {
                    let u = CGFloat(i) / 48, v = 1 - u
                    let a = v * v * v, b = 3 * v * v * u, d = 3 * v * u * u, e = u * u * u
                    xs.append(a * current.x + b * c1.x + d * c2.x + e * p.x)
                    ys.append(a * current.y + b * c1.y + d * c2.y + e * p.y)
                }
                current = p
            case .quadCurve(let p, _):
                current = p
                xs.append(p.x); ys.append(p.y)
            case .closeSubpath:
                break
            }
        }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
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
