import SwiftUI
import AmbitickCore
import AmbitickMac

/// Time Spent: donut of projects for a period (default today). Hovering a
/// wedge extends an arc ring outside it with the task breakdown; hovering a
/// task arc extends the app-level ring. Clicking pins the expansion until you
/// click again or elsewhere. Legend rows pin too.
struct SpentView: View {
    @ObservedObject var controller: AppController
    @State private var period: Period = .today
    @State private var hover: Selection = .none
    @State private var pinned: Selection = .none
    @State private var refreshTick = 0

    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    enum Period: String, CaseIterable, Identifiable {
        case today = "Today"
        case yesterday = "Yesterday"
        case thisWeek = "This week"
        case last7 = "Last 7 days"
        case thisMonth = "This month"
        var id: String { rawValue }

        var range: (Date, Date) {
            let cal = Calendar.current
            let todayStart = cal.startOfDay(for: Date())
            switch self {
            case .today: return (todayStart, todayStart.addingTimeInterval(86_400))
            case .yesterday: return (todayStart.addingTimeInterval(-86_400), todayStart)
            case .thisWeek:
                let start = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? todayStart
                return (start, start.addingTimeInterval(7 * 86_400))
            case .last7:
                return (todayStart.addingTimeInterval(-6 * 86_400),
                        todayStart.addingTimeInterval(86_400))
            case .thisMonth:
                let start = cal.dateInterval(of: .month, for: Date())?.start ?? todayStart
                return (start, start.addingTimeInterval(32 * 86_400))
            }
        }
    }

    /// What's highlighted: nothing, a project wedge, or a task arc within one.
    enum Selection: Equatable {
        case none
        case project(Int)
        case task(Int, Int)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $period) {
                    ForEach(Period.allCases) { p in Text(p.rawValue).tag(p) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Spacer()
                Text(totalText).font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                pie
                legend
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .onReceive(timer) { _ in refreshTick += 1 }
    }

    // MARK: - Data

    private var nodes: [TimeAggregator.Node] {
        _ = refreshTick
        let (from, to) = period.range
        return controller.spentNodes(from: from, to: to)
    }

    private var totalSeconds: TimeInterval {
        nodes.reduce(0) { $0 + $1.seconds }
    }

    private var totalText: String {
        "total: \(hm(totalSeconds))"
    }

    private func hm(_ seconds: TimeInterval) -> String {
        MenuTitle.text(elapsed: seconds, certainty: nil, showPercent: false)
    }

    /// Angular layout: (startAngle, endAngle) per node, from 12 o'clock.
    private func angles(for children: [TimeAggregator.Node], total: TimeInterval,
                        within range: (Double, Double)? = nil) -> [(Double, Double)] {
        let (lo, hi) = range ?? (-90, 270)
        let span = hi - lo
        var cursor = lo
        return children.map { node in
            let sweep = total > 0 ? span * node.seconds / total : 0
            defer { cursor += sweep }
            return (cursor, cursor + sweep)
        }
    }

    private var active: Selection { pinned == .none ? hover : pinned }

    // MARK: - Pie

    private let r1: CGFloat = 105        // project wedges
    private let hole: CGFloat = 36
    private let ringGap: CGFloat = 5
    private let ringWidth: CGFloat = 30

    private var pie: some View {
        let projectAngles = angles(for: nodes, total: totalSeconds)
        let side = (r1 + ringGap * 2 + ringWidth * 2 + 12) * 2
        return Canvas { context, size in
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            // Level 1: project wedges.
            for (i, node) in nodes.enumerated() {
                let (a0, a1) = projectAngles[i]
                let highlighted = isHighlighted(project: i)
                var path = Path()
                path.move(to: centre)
                path.addArc(center: centre, radius: highlighted ? r1 + 3 : r1,
                            startAngle: .degrees(a0), endAngle: .degrees(a1),
                            clockwise: false)
                path.closeSubpath()
                context.fill(path, with: .color(colour(project: node, index: i)
                    .opacity(highlighted ? 1 : 0.88)))
                if a1 - a0 > 14 {
                    let mid = Angle.degrees((a0 + a1) / 2).radians
                    let lp = CGPoint(x: centre.x + cos(mid) * r1 * 0.66,
                                     y: centre.y + sin(mid) * r1 * 0.66)
                    context.draw(Text(node.label).font(.system(size: 9).bold())
                        .foregroundStyle(.black.opacity(0.75)), at: lp)
                }
            }
            // Donut hole + centre label.
            var holePath = Path()
            holePath.addArc(center: centre, radius: hole, startAngle: .degrees(0),
                            endAngle: .degrees(360), clockwise: false)
            context.fill(holePath, with: .color(Color(nsColor: .windowBackgroundColor)))
            drawCentreLabel(context, centre)

            // Level 2 ring for the active project.
            if case let projectIndex = activeProjectIndex(), let pi = projectIndex,
               pi < nodes.count {
                let (p0, p1) = projectAngles[pi]
                let tasks = nodes[pi].children
                let taskAngles = angles(for: tasks, total: nodes[pi].seconds,
                                        within: (p0, p1))
                for (j, task) in tasks.enumerated() {
                    let (a0, a1) = taskAngles[j]
                    let highlighted = active == .task(pi, j)
                    ring(context, centre: centre, inner: r1 + ringGap,
                         outer: r1 + ringGap + ringWidth + (highlighted ? 3 : 0),
                         from: a0, to: a1,
                         colour: taskColour(task).opacity(highlighted ? 1 : 0.85))
                    if a1 - a0 > 10 {
                        let mid = Angle.degrees((a0 + a1) / 2).radians
                        let r = r1 + ringGap + ringWidth / 2
                        context.draw(Text(shortLabel(task.label))
                            .font(.system(size: 8))
                            .foregroundStyle(.black.opacity(0.75)),
                            at: CGPoint(x: centre.x + cos(mid) * r,
                                        y: centre.y + sin(mid) * r))
                    }
                }
                // Level 3 ring: apps inside the active task.
                if case .task(pi, let tj) = active, tj < tasks.count,
                   !tasks[tj].children.isEmpty {
                    let (t0, t1) = taskAngles[tj]
                    let apps = tasks[tj].children
                    let appAngles = angles(for: apps, total: tasks[tj].seconds,
                                           within: (t0, t1))
                    for (k, app) in apps.enumerated() {
                        let (a0, a1) = appAngles[k]
                        ring(context, centre: centre,
                             inner: r1 + ringGap * 2 + ringWidth,
                             outer: r1 + ringGap * 2 + ringWidth * 2,
                             from: a0, to: a1,
                             colour: taskColour(tasks[tj])
                                .opacity(0.35 + 0.5 * Double(k % 2 == 0 ? 1 : 0.55)))
                        if a1 - a0 > 12 {
                            let mid = Angle.degrees((a0 + a1) / 2).radians
                            let r = r1 + ringGap * 2 + ringWidth * 1.5
                            context.draw(Text(shortLabel(app.label))
                                .font(.system(size: 8))
                                .foregroundStyle(.black.opacity(0.7)),
                                at: CGPoint(x: centre.x + cos(mid) * r,
                                            y: centre.y + sin(mid) * r))
                        }
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hover = hitTest(location, size: CGSize(width: side, height: side))
            case .ended:
                hover = .none
            }
        }
        .onTapGesture {
            // Click pins; clicking another segment moves the pin; clicking
            // pinned segment or empty space unpins.
            if hover == .none || hover == pinned {
                pinned = .none
            } else {
                pinned = hover
            }
        }
    }

    private func drawCentreLabel(_ context: GraphicsContext, _ centre: CGPoint) {
        let (title, seconds): (String, TimeInterval)
        switch active {
        case .none:
            (title, seconds) = ("total", totalSeconds)
        case .project(let i) where i < nodes.count:
            (title, seconds) = (nodes[i].label, nodes[i].seconds)
        case .task(let i, let j) where i < nodes.count && j < nodes[i].children.count:
            let t = nodes[i].children[j]
            (title, seconds) = (t.label, t.seconds)
        default:
            (title, seconds) = ("total", totalSeconds)
        }
        let pct = totalSeconds > 0 ? Int((seconds / totalSeconds * 100).rounded()) : 0
        context.draw(Text("\(shortLabel(title))\n\(hm(seconds)) · \(pct)%")
            .font(.system(size: 9)), at: centre)
    }

    private func ring(_ context: GraphicsContext, centre: CGPoint, inner: CGFloat,
                      outer: CGFloat, from a0: Double, to a1: Double, colour: Color) {
        var path = Path()
        path.addArc(center: centre, radius: outer, startAngle: .degrees(a0),
                    endAngle: .degrees(a1), clockwise: false)
        path.addArc(center: centre, radius: inner, startAngle: .degrees(a1),
                    endAngle: .degrees(a0), clockwise: true)
        path.closeSubpath()
        context.fill(path, with: .color(colour))
    }

    // MARK: - Hit testing

    private func hitTest(_ point: CGPoint, size: CGSize) -> Selection {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        let r = sqrt(dx * dx + dy * dy)
        var angle = atan2(dy, dx) * 180 / .pi          // -180...180, 0 = 3 o'clock
        if angle < -90 { angle += 360 }                 // match the -90...270 layout
        let projectAngles = angles(for: nodes, total: totalSeconds)

        if r >= hole, r <= r1 + 3 {
            for (i, (a0, a1)) in projectAngles.enumerated() where angle >= a0 && angle < a1 {
                return .project(i)
            }
        }
        if let pi = activeProjectIndex(), pi < nodes.count,
           r > r1 + ringGap, r <= r1 + ringGap + ringWidth + 3 {
            let (p0, p1) = projectAngles[pi]
            let taskAngles = angles(for: nodes[pi].children, total: nodes[pi].seconds,
                                    within: (p0, p1))
            for (j, (a0, a1)) in taskAngles.enumerated() where angle >= a0 && angle < a1 {
                return .task(pi, j)
            }
            return .project(pi)   // in the ring band but outside arcs: keep expansion
        }
        if case .task(let pi, _) = active,
           r > r1 + ringGap * 2 + ringWidth, r <= r1 + ringGap * 2 + ringWidth * 2 {
            return active          // hovering the app ring keeps it open
        }
        return .none
    }

    private func activeProjectIndex() -> Int? {
        switch active {
        case .project(let i): return i
        case .task(let i, _): return i
        case .none: return nil
        }
    }

    private func isHighlighted(project index: Int) -> Bool {
        activeProjectIndex() == index
    }

    // MARK: - Colours / labels

    private func colour(project node: TimeAggregator.Node, index: Int) -> Color {
        if let firstTask = node.children.first, let ref = firstTask.ref {
            return Color(nsColor: controller.colour(for: ref))
        }
        return Color(hue: Double(index) * 0.13.truncatingRemainder(dividingBy: 1),
                     saturation: 0.5, brightness: 0.85)
    }

    private func taskColour(_ node: TimeAggregator.Node) -> Color {
        if let ref = node.ref {
            return Color(nsColor: controller.colour(for: ref))
        }
        return .gray
    }

    private func shortLabel(_ label: String) -> String {
        label.count > 18 ? String(label.prefix(17)) + "…" : label
    }

    // MARK: - Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { i, node in
                Button {
                    pinned = pinned == .project(i) ? .none : .project(i)
                } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(colour(project: node, index: i))
                            .frame(width: 10, height: 10)
                        Text(node.label).lineLimit(1)
                        Spacer()
                        Text(hm(node.seconds)).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if activeProjectIndex() == i {
                    ForEach(Array(node.children.enumerated()), id: \.offset) { j, task in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(taskColour(task))
                                .frame(width: 8, height: 8)
                            Text(task.label).lineLimit(1)
                            Spacer()
                            Text(hm(task.seconds)).foregroundStyle(.secondary)
                        }
                        .font(.caption2)
                        .padding(.leading, 14)
                        .background(active == .task(i, j) ? Color.accentColor.opacity(0.1) : .clear)
                    }
                }
            }
            if nodes.isEmpty {
                Text("nothing tracked in this period")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 220, alignment: .leading)
    }
}
