import Foundation
import andeyeTTCore

func pieGeometryChecks(_ c: Checks) {
    func node(_ label: String, _ seconds: TimeInterval,
              children: [TimeAggregator.Node] = []) -> TimeAggregator.Node {
        TimeAggregator.Node(label: label, seconds: seconds, children: children)
    }

    c.check("angles are proportional, contiguous and fill the full circle") {
        let a = PieGeometry.angles(weights: [3, 1], total: 4)
        try expectEq(a.count, 2)
        try expectEq(a[0].0, -90, "starts at 12 o'clock")
        try expectEq(a[0].1, 180, "3/4 of 360° = 270° sweep")
        try expectEq(a[1].0, 180, "contiguous: next starts where the last ended")
        try expectEq(a[1].1, 270, "ends where the domain ends")
    }

    c.check("zero total → zero-sweep slices (nothing drawn, nothing hit)") {
        let a = PieGeometry.angles(weights: [1, 2], total: 0)
        try expect(a.allSatisfy { $0.0 == $0.1 }, "every sweep is empty")
        try expectEq(PieGeometry.index(at: 0, in: a), nil)
    }

    c.check("nested range: task arcs pack exactly into their project's wedge") {
        let a = PieGeometry.angles(weights: [1, 1], total: 2, within: (30, 90))
        try expectEq(a[0].0, 30)
        try expectEq(a[0].1, 60)
        try expectEq(a[1].1, 90)
    }

    c.check("polarAngle normalises into [-90, 270): up=-90 right=0 down=90 left=180") {
        try expectEq(PieGeometry.polarAngle(dx: 0, dy: -1), -90, "12 o'clock")
        try expectEq(PieGeometry.polarAngle(dx: 1, dy: 0), 0, "3 o'clock")
        try expectEq(PieGeometry.polarAngle(dx: 0, dy: 1), 90, "6 o'clock")
        try expectEq(PieGeometry.polarAngle(dx: -1, dy: 0), 180, "9 o'clock")
        let upLeft = PieGeometry.polarAngle(dx: -1, dy: -1)
        try expect(upLeft >= -90 && upLeft < 270, "wraps below -90 up by 360")
        try expectEq(upLeft, 225, "atan2 -135 + 360")
    }

    c.check("index(at:) is inclusive at a slice's start, exclusive at its end") {
        let a = PieGeometry.angles(weights: [1, 1], total: 2)   // [-90,90) [90,270)
        try expectEq(PieGeometry.index(at: -90, in: a), 0)
        try expectEq(PieGeometry.index(at: 89.999, in: a), 0)
        try expectEq(PieGeometry.index(at: 90, in: a), 1)
        try expectEq(PieGeometry.index(at: 270, in: a), nil, "past the domain")
    }

    c.check("bands are contiguous with +3 highlight slack at each edge") {
        let m = PieGeometry.Metrics(side: 400)   // r1=120 hole=40 gap=4.8 ring=34
        try expectEq(PieGeometry.band(radius: 0, metrics: m), .wedge, "hole hits the wedge")
        try expectEq(PieGeometry.band(radius: m.r1 + 3, metrics: m), .wedge)
        try expectEq(PieGeometry.band(radius: m.r1 + 3.01, metrics: m), .taskRing,
                     "no dead zone between wedge and task ring")
        try expectEq(PieGeometry.band(radius: m.r1 + m.gap + m.ringWidth + 3.01, metrics: m),
                     .appRing)
        try expectEq(PieGeometry.band(radius: m.outerMost + 3.01, metrics: m), .outside)
    }

    c.check("small windows keep a visible gap (floor at 3pt)") {
        let m = PieGeometry.Metrics(side: 100)
        try expectEq(m.gap, 3, "100 * 0.012 = 1.2 → floored to 3")
    }

    c.check("a pinned selection survives the nodes re-sorting (the review finding)") {
        var nodes = [
            node("Alpha", 100, children: [node("a1", 60), node("a2", 40)]),
            node("Beta", 900, children: [node("b1", 900)]),
        ]
        let pin = PieGeometry.Selection.task("Alpha", "a2")
        let before = try unwrap(PieGeometry.resolve(pin, in: nodes),
                                "resolves before the re-sort")
        try expectEq(before.project, 0)
        try expectEq(before.task, 1)
        // Background reload re-sorts by seconds — Alpha moves to index 1.
        nodes.sort { $0.seconds > $1.seconds }
        let after = try unwrap(PieGeometry.resolve(pin, in: nodes),
                               "still resolves after the re-sort")
        try expectEq(after.project, 1, "follows the node, not the position")
        try expectEq(after.task, 1)
        try expectEq(nodes[after.project].children[after.task!].label, "a2",
                     "the pin still points at the SAME task")
    }

    c.check("a selection whose node vanished dies cleanly (nil, never retargets)") {
        let nodes = [node("Alpha", 100, children: [node("a1", 100)])]
        try expectEq(PieGeometry.resolve(.project("Gone"), in: nodes), nil)
        try expectEq(PieGeometry.resolve(.task("Alpha", "gone"), in: nodes), nil)
        try expectEq(PieGeometry.resolve(.app("Alpha", "a1", "gone"), in: nodes), nil)
        try expectEq(PieGeometry.resolve(.none, in: nodes), nil)
    }

    c.check("app-level selection resolves all three indices") {
        let nodes = [node("P", 10, children: [
            node("T", 10, children: [node("Ghostty", 6), node("Safari", 4)]),
        ])]
        let r = try unwrap(PieGeometry.resolve(.app("P", "T", "Safari"), in: nodes),
                           "resolves")
        try expectEq(r.project, 0)
        try expectEq(r.task, 0)
        try expectEq(r.app, 1)
    }
}
