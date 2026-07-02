import Foundation

/// Pure geometry for the Time Spent donut (extracted from SpentView so it can
/// be checked and shared with the iOS pie): slice-angle layout, the radial
/// band model for hit-testing, and a label-keyed selection that survives the
/// nodes array re-sorting underneath it. All angles are degrees in the pie's
/// domain [-90, 270) — 12 o'clock start, clockwise.
public enum PieGeometry {

    // MARK: - Metrics (radii scale with the square drawn into)

    public struct Metrics: Equatable, Sendable {
        /// Outer radius of the inner project wedges.
        public let r1: Double
        /// Radius of the blank centre hole.
        public let hole: Double
        /// Gap between the wedge disc and each ring.
        public let gap: Double
        /// Thickness of the task / app rings.
        public let ringWidth: Double

        public init(side: Double) {
            r1 = side * 0.30
            hole = side * 0.10
            gap = max(side * 0.012, 3)
            ringWidth = side * 0.085
        }

        /// Outer edge of the outermost (app) ring.
        public var outerMost: Double { r1 + gap * 2 + ringWidth * 2 }
    }

    // MARK: - Angle layout

    /// Contiguous (start, end) angle pairs proportional to `weights`, packed
    /// into `range` (default: the full circle from 12 o'clock). A zero or
    /// negative total yields zero-sweep slices — nothing to draw, nothing to
    /// hit.
    public static func angles(weights: [Double], total: Double,
                              within range: (Double, Double) = (-90, 270))
        -> [(Double, Double)] {
        let (lo, hi) = range
        let span = hi - lo
        var cursor = lo
        return weights.map { w in
            let sweep = total > 0 ? span * w / total : 0
            defer { cursor += sweep }
            return (cursor, cursor + sweep)
        }
    }

    /// Polar angle of a point relative to the centre (screen coordinates:
    /// +y is down), normalised into the pie's [-90, 270) domain.
    public static func polarAngle(dx: Double, dy: Double) -> Double {
        var angle = atan2(dy, dx) * 180 / .pi
        if angle < -90 { angle += 360 }
        return angle
    }

    /// The slice whose [start, end) contains `angle`, if any.
    public static func index(at angle: Double, in angles: [(Double, Double)]) -> Int? {
        angles.firstIndex { angle >= $0.0 && angle < $0.1 }
    }

    // MARK: - Radial bands (contiguous: no dead zone between rings, so a
    // pointer travelling wedge → task arc → app arc never collapses the
    // hover expansion; the +3 slack matches the highlight bulge)

    public enum Band: Equatable, Sendable {
        case wedge      // the inner project disc (hole included)
        case taskRing
        case appRing
        case outside
    }

    public static func band(radius: Double, metrics m: Metrics) -> Band {
        if radius <= m.r1 + 3 { return .wedge }
        if radius <= m.r1 + m.gap + m.ringWidth + 3 { return .taskRing }
        if radius <= m.outerMost + 3 { return .appRing }
        return .outside
    }

    // MARK: - Selection (keyed by label, NOT position)

    /// What the user is hovering / has pinned, keyed by node labels so a
    /// background reload that re-sorts `nodes` cannot silently retarget a pin
    /// to whichever node now sits at the old index (the 2026-07-01 review
    /// finding). Labels are unique within their parent — TimeAggregator
    /// groups by label.
    public enum Selection: Equatable, Sendable {
        case none
        case project(String)
        case task(String, String)
        case app(String, String, String)
    }

    /// A selection resolved against the CURRENT nodes array. `project` is
    /// always valid; `task`/`app` are set for the deeper cases.
    public struct Resolved: Equatable, Sendable {
        public var project: Int
        public var task: Int?
        public var app: Int?
        public init(project: Int, task: Int? = nil, app: Int? = nil) {
            self.project = project
            self.task = task
            self.app = app
        }
    }

    /// Resolve a label-keyed selection to indices in `nodes`. nil when any
    /// level no longer exists (the selection dies cleanly instead of
    /// retargeting).
    public static func resolve(_ sel: Selection, in nodes: [TimeAggregator.Node])
        -> Resolved? {
        func find(_ label: String, in children: [TimeAggregator.Node]) -> Int? {
            children.firstIndex { $0.label == label }
        }
        switch sel {
        case .none:
            return nil
        case .project(let p):
            return find(p, in: nodes).map { Resolved(project: $0) }
        case .task(let p, let t):
            guard let pi = find(p, in: nodes),
                  let ti = find(t, in: nodes[pi].children) else { return nil }
            return Resolved(project: pi, task: ti)
        case .app(let p, let t, let a):
            guard let pi = find(p, in: nodes),
                  let ti = find(t, in: nodes[pi].children),
                  let ai = find(a, in: nodes[pi].children[ti].children) else { return nil }
            return Resolved(project: pi, task: ti, app: ai)
        }
    }
}
