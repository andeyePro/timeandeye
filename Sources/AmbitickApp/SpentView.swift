import SwiftUI
import AmbitickCore
import AmbitickMac

/// Time Spent: donut of projects for a period (default today). Hovering a
/// wedge extends an arc ring outside it with the task breakdown; hovering a
/// task arc extends the app-level ring. Clicking pins (click another segment
/// to move the pin, empty space to clear). The pie scales with the window.
/// Labels that do not fit their segment are hidden — the centre readout and
/// the ✕-marked legend row identify the hovered segment instead.
/// "OpenProject only" hides local/personal time; with it off, non-OP wedges
/// are drawn desaturated with a dashed outline (and "local" in the legend).
struct SpentView: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var period: Period = .today
    @State private var blockData: (sessions: [Session], start: Date, end: Date)?
    @State private var hover: Selection = .none
    @State private var pinned: Selection = .none
    @State private var opOnly = false
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

    enum Selection: Equatable {
        case none
        case project(Int)
        case task(Int, Int)
        case app(Int, Int, Int)
    }

    @State private var reassignFilter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $period) {
                    ForEach(Period.allCases) { p in Text(p.rawValue).tag(p) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle("OpenProject only", isOn: $opOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Text(totalText).font(.caption).foregroundStyle(.secondary)
            }
            // Cross-preview / navigation: the current block's timeline. Clicking
            // a slice opens the full timeline framed on that exact slice. Labelled
            // with the first slice's start time.
            if let block = blockData, !block.sessions.isEmpty {
                let from = block.sessions.map(\.start).min() ?? block.start
                HStack(spacing: 6) {
                    Text("from \(from.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                    MiniTimeline(sessions: block.sessions, start: block.start, end: block.end,
                                 colour: { Color(nsColor: controller.colour(for: $0)) },
                                 onTap: { s in
                                     controller.pendingTimelineFocus = s
                                     controller.noteTimeViewOpened(.timeline)
                                     openWindow(id: "timeline")
                                     dismissWindow(id: "spent")
                                 })
                }
            }
            if let note = controller.actionNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            reassignBar
            HStack(alignment: .top, spacing: 16) {
                GeometryReader { geo in
                    pie(in: geo.size)
                }
                legend
                    .frame(width: 250)
            }
        }
        .padding(12)
        .onReceive(timer) { _ in refreshTick += 1; reloadBlock() }
        .onAppear {
            controller.noteTimeViewOpened(.spent)
            reloadBlock()
        }
    }

    /// Cached current-block slices for the mini-timeline cross-preview (a journal
    /// query — don't recompute per body eval).
    private func reloadBlock() { blockData = controller.currentBlock() }

    // MARK: - Data

    private var nodes: [TimeAggregator.Node] {
        _ = refreshTick
        let (from, to) = period.range
        let all = controller.spentNodes(from: from, to: to)
        let filtered = opOnly ? all.filter { !isLocalProject($0) } : all
        // OP work first, then local/personal — the pie reads as two groups.
        return filtered.sorted { a, b in
            if isLocalProject(a) != isLocalProject(b) { return !isLocalProject(a) }
            return a.seconds > b.seconds
        }
    }

    private func isLocalProject(_ node: TimeAggregator.Node) -> Bool {
        !node.children.isEmpty && node.children.allSatisfy { child in
            if case .local = child.ref { return true }
            return false
        }
    }

    private var totalSeconds: TimeInterval {
        nodes.reduce(0) { $0 + $1.seconds }
    }

    private var totalText: String { "total: \(hm(totalSeconds))" }

    private func hm(_ seconds: TimeInterval) -> String {
        MenuTitle.text(elapsed: seconds, certainty: nil, showPercent: false)
    }

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

    // MARK: - Geometry (scales with the window)

    private struct Metrics {
        let r1: CGFloat
        let hole: CGFloat
        let gap: CGFloat
        let ringWidth: CGFloat

        init(side: CGFloat) {
            r1 = side * 0.30
            hole = side * 0.10
            gap = max(side * 0.012, 3)
            ringWidth = side * 0.085
        }

        var outerMost: CGFloat { r1 + gap * 2 + ringWidth * 2 }
    }

    // MARK: - Pie

    private func pie(in size: CGSize) -> some View {
        let side = min(size.width, size.height)
        let m = Metrics(side: side)
        let projectAngles = angles(for: nodes, total: totalSeconds)
        return Canvas { context, canvasSize in
            let centre = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            for (i, node) in nodes.enumerated() {
                let (a0, a1) = projectAngles[i]
                let highlighted = activeProjectIndex() == i
                let local = isLocalProject(node)
                var path = Path()
                path.move(to: centre)
                path.addArc(center: centre, radius: highlighted ? m.r1 + 3 : m.r1,
                            startAngle: .degrees(a0), endAngle: .degrees(a1),
                            clockwise: false)
                path.closeSubpath()
                context.fill(path, with: .color(colour(project: node, index: i)
                    .opacity(highlighted ? 1 : (local ? 0.55 : 0.88))))
                if local {
                    context.stroke(path, with: .color(.white.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
                drawAngledLabel(context, node.label, centre: centre,
                                radius: (m.hole + m.r1) / 2, a0: a0, a1: a1,
                                orientation: .radial, depth: m.r1 - m.hole,
                                bold: true, colour: colour(project: node, index: i))
            }
            var holePath = Path()
            holePath.addArc(center: centre, radius: m.hole, startAngle: .degrees(0),
                            endAngle: .degrees(360), clockwise: false)
            context.fill(holePath, with: .color(Color(nsColor: .windowBackgroundColor)))
            drawCentreLabel(context, centre)

            if let pi = activeProjectIndex(), pi < nodes.count {
                let (p0, p1) = projectAngles[pi]
                let local = isLocalProject(nodes[pi])
                let tasks = nodes[pi].children
                let taskAngles = angles(for: tasks, total: nodes[pi].seconds, within: (p0, p1))
                for (j, task) in tasks.enumerated() {
                    let (a0, a1) = taskAngles[j]
                    let highlighted = active == .task(pi, j)
                    let outer = m.r1 + m.gap + m.ringWidth + (highlighted ? 3 : 0)
                    ring(context, centre: centre, inner: m.r1 + m.gap, outer: outer,
                         from: a0, to: a1,
                         colour: taskColour(task)
                            .opacity(highlighted ? 1 : (local ? 0.55 : 0.85)),
                         dashed: local)
                    drawAngledLabel(context, task.label, centre: centre,
                                    radius: m.r1 + m.gap + m.ringWidth / 2,
                                    a0: a0, a1: a1, orientation: .tangential,
                                    depth: m.ringWidth, bold: false, colour: taskColour(task))
                }
                if let tj = activeTaskIndex(), tj < tasks.count,
                   !tasks[tj].children.isEmpty {
                    let (t0, t1) = taskAngles[tj]
                    let apps = tasks[tj].children
                    // Normalise against the apps we know about so a sole app
                    // (e.g. all Ambitick work in Ghostty) fills 100% of the
                    // task arc — span coverage is partial, the task total isn't.
                    let appTotal = apps.reduce(0.0) { $0 + $1.seconds }
                    let appAngles = angles(for: apps, total: appTotal, within: (t0, t1))
                    for (k, app) in apps.enumerated() {
                        let (a0, a1) = appAngles[k]
                        let appColour = taskColour(tasks[tj]).opacity(k % 2 == 0 ? 0.85 : 0.55)
                        ring(context, centre: centre,
                             inner: m.r1 + m.gap * 2 + m.ringWidth,
                             outer: m.r1 + m.gap * 2 + m.ringWidth * 2,
                             from: a0, to: a1, colour: appColour, dashed: false)
                        drawAngledLabel(context, app.label, centre: centre,
                                        radius: m.r1 + m.gap * 2 + m.ringWidth * 1.5,
                                        a0: a0, a1: a1, orientation: .tangential,
                                        depth: m.ringWidth, bold: false,
                                        colour: taskColour(tasks[tj]))
                    }
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hover = hitTest(location, size: size, metrics: m)
            case .ended:
                hover = .none
            }
        }
        .onTapGesture {
            if hover == .none || hover == pinned {
                pinned = .none
            } else {
                pinned = hover
            }
        }
    }

    enum LabelOrientation { case radial, tangential }

    /// Whole-word angled label. `.radial` runs out from the centre (inner
    /// wedges); `.tangential` runs along the arc (rings). The rotation is
    /// always kept upright — never upside-down or mirror-reversed below the
    /// halfway line. Hidden when the word can't fit its segment; the legend
    /// and centre readout still identify it.
    private func drawAngledLabel(_ context: GraphicsContext, _ label: String,
                                 centre: CGPoint, radius: CGFloat,
                                 a0: Double, a1: Double,
                                 orientation: LabelOrientation,
                                 depth: CGFloat, bold: Bool, colour: Color) {
        let sweepRad = (a1 - a0) * .pi / 180
        guard sweepRad > 0.02, radius > 0 else { return }
        let resolved = context.resolve(Text(label)
            .font(.system(size: bold ? 10 : 9, weight: bold ? .bold : .regular))
            .foregroundStyle(readableText(on: colour)))
        let measured = resolved.measure(in: CGSize(width: 600, height: 40))

        let arc = radius * sweepRad                 // tangential room
        func fits(_ o: LabelOrientation) -> Bool {
            let along = o == .radial ? depth : arc
            let across = o == .radial ? arc : depth
            return measured.width <= along * 0.92 && measured.height <= across
        }
        // Prefer the requested orientation; if a wedge label won't fit
        // radially, lay it along the arc instead rather than hiding it.
        let chosen: LabelOrientation
        if fits(orientation) { chosen = orientation }
        else if orientation == .radial, fits(.tangential) { chosen = .tangential }
        else { return }

        let midDeg = (a0 + a1) / 2
        var rotation = chosen == .radial ? midDeg : midDeg + 90
        // Keep upright: if the baseline would read right-to-left, spin 180°.
        var norm = rotation.truncatingRemainder(dividingBy: 360)
        if norm < 0 { norm += 360 }
        if norm > 90 && norm < 270 { rotation += 180 }

        let midRad = midDeg * .pi / 180
        var ctx = context
        ctx.translateBy(x: centre.x + cos(midRad) * radius,
                        y: centre.y + sin(midRad) * radius)
        ctx.rotate(by: .degrees(rotation))
        ctx.draw(resolved, at: .zero, anchor: .center)
    }

    private func readableText(on colour: Color) -> Color {
        let c = NSColor(colour).usingColorSpace(.sRGB) ?? .black
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent
            + 0.114 * c.blueComponent
        return luminance > 0.6 ? .black : .white
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
        case .app(let i, let j, let k) where i < nodes.count && j < nodes[i].children.count
            && k < nodes[i].children[j].children.count:
            let a = nodes[i].children[j].children[k]
            (title, seconds) = (a.label, a.seconds)
        default:
            (title, seconds) = ("total", totalSeconds)
        }
        let pct = totalSeconds > 0 ? Int((seconds / totalSeconds * 100).rounded()) : 0
        context.draw(Text("\(shortLabel(title))\n\(hm(seconds)) · \(pct)%")
            .font(.system(size: 10)), at: centre)
    }

    private func ring(_ context: GraphicsContext, centre: CGPoint, inner: CGFloat,
                      outer: CGFloat, from a0: Double, to a1: Double,
                      colour: Color, dashed: Bool) {
        var path = Path()
        path.addArc(center: centre, radius: outer, startAngle: .degrees(a0),
                    endAngle: .degrees(a1), clockwise: false)
        path.addArc(center: centre, radius: inner, startAngle: .degrees(a1),
                    endAngle: .degrees(a0), clockwise: true)
        path.closeSubpath()
        context.fill(path, with: .color(colour))
        if dashed {
            context.stroke(path, with: .color(.white.opacity(0.9)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    // MARK: - Hit testing (contiguous bands: no dead zone between rings, so
    // travelling wedge -> task arc -> app arc never collapses the expansion)

    private func hitTest(_ point: CGPoint, size: CGSize, metrics m: Metrics) -> Selection {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = point.x - centre.x
        let dy = point.y - centre.y
        let r = sqrt(dx * dx + dy * dy)
        var angle = atan2(dy, dx) * 180 / .pi
        if angle < -90 { angle += 360 }
        let projectAngles = angles(for: nodes, total: totalSeconds)

        if r <= m.r1 + 3 {
            for (i, (a0, a1)) in projectAngles.enumerated() where angle >= a0 && angle < a1 {
                return .project(i)
            }
            return .none
        }
        guard let pi = activeProjectIndex(), pi < nodes.count else { return .none }
        let (p0, p1) = projectAngles[pi]
        if r <= m.r1 + m.gap + m.ringWidth + 3 {
            let taskAngles = angles(for: nodes[pi].children, total: nodes[pi].seconds,
                                    within: (p0, p1))
            for (j, (a0, a1)) in taskAngles.enumerated() where angle >= a0 && angle < a1 {
                return .task(pi, j)
            }
            return .project(pi)        // ring band, off-arc: keep the expansion
        }
        if r <= m.outerMost + 3, let tj = activeTaskIndex(), tj < nodes[pi].children.count {
            let apps = nodes[pi].children[tj].children
            guard !apps.isEmpty else { return active }
            let taskAngles = angles(for: nodes[pi].children, total: nodes[pi].seconds,
                                    within: (p0, p1))
            let (t0, t1) = taskAngles[tj]
            let appTotal = apps.reduce(0.0) { $0 + $1.seconds }
            let appAngles = angles(for: apps, total: appTotal, within: (t0, t1))
            for (k, (a0, a1)) in appAngles.enumerated() where angle >= a0 && angle < a1 {
                return .app(pi, tj, k)
            }
            return active
        }
        return .none
    }

    private func activeProjectIndex() -> Int? {
        switch active {
        case .project(let i): return i
        case .task(let i, _): return i
        case .app(let i, _, _): return i
        case .none: return nil
        }
    }

    private func activeTaskIndex() -> Int? {
        switch active {
        case .task(_, let j): return j
        case .app(_, let j, _): return j
        default: return nil
        }
    }

    // MARK: - Colours / labels

    // MARK: - Reassign (click a pinned task/app → move that time)

    @ViewBuilder private var reassignBar: some View {
        switch pinned {
        case .task(let i, let j) where i < nodes.count && j < nodes[i].children.count:
            let task = nodes[i].children[j]
            if let ref = task.ref {
                reassignRow(label: "all \(task.label) (\(hm(task.seconds)))") { target in
                    let (from, to) = period.range
                    Task { await controller.reassignSpentTask(ref, from: from, to: to, to: target) }
                }
            }
        case .app(let i, let j, let k) where i < nodes.count && j < nodes[i].children.count
            && k < nodes[i].children[j].children.count:
            let app = nodes[i].children[j].children[k]
            reassignRow(label: "\(app.label) time (\(hm(app.seconds)))") { target in
                let (from, to) = period.range
                Task { await controller.reassignSpentApp(app.label, from: from, to: to, to: target) }
            }
        default:
            EmptyView()
        }
    }

    private func reassignRow(label: String, action: @escaping (TaskRef) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Reassign \(label) →").font(.caption)
                TextField("filter tasks", text: $reassignFilter)
                    .textFieldStyle(.roundedBorder).font(.caption).frame(width: 150)
                Button { pinned = .none } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(controller.searchTasks(reassignFilter), id: \.ref) { task in
                        Button {
                            action(task.ref)
                            pinned = .none
                            reassignFilter = ""
                        } label: {
                            HStack(spacing: 3) {
                                if task.isLocalOnly { Image(systemName: "house").font(.system(size: 8)) }
                                Text(task.subject)
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func colour(project node: TimeAggregator.Node, index: Int) -> Color {
        if let firstTask = node.children.first, let ref = firstTask.ref {
            return Color(nsColor: controller.colour(for: ref))
        }
        return Color(hue: (Double(index) * 0.13).truncatingRemainder(dividingBy: 1),
                     saturation: 0.5, brightness: 0.85)
    }

    private func taskColour(_ node: TimeAggregator.Node) -> Color {
        if let ref = node.ref {
            return Color(nsColor: controller.colour(for: ref))
        }
        return .gray
    }

    private func shortLabel(_ label: String) -> String {
        label.count > 22 ? String(label.prefix(21)) + "…" : label
    }

    // MARK: - Legend (the "key": active row gets the ✕ badge)

    private func swatch(_ colour: Color, marked: Bool, local: Bool, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(colour.opacity(local ? 0.55 : 1))
            .overlay {
                if local {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: size, height: size)
            .overlay {
                if marked {
                    Image(systemName: "xmark")
                        .font(.system(size: size * 0.7, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
    }

    private var legend: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(nodes.enumerated()), id: \.offset) { i, node in
                    let local = isLocalProject(node)
                    Button {
                        pinned = pinned == .project(i) ? .none : .project(i)
                    } label: {
                        HStack(spacing: 6) {
                            swatch(colour(project: node, index: i),
                                   marked: activeProjectIndex() == i, local: local, size: 11)
                            Text(node.label).lineLimit(1)
                            if local {
                                Text("local").font(.system(size: 8))
                                    .padding(.horizontal, 3)
                                    .background(.quaternary, in: Capsule())
                            }
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
                                swatch(taskColour(task), marked: active == .task(i, j),
                                       local: local, size: 9)
                                Text(task.label).lineLimit(1)
                                Spacer()
                                Text(hm(task.seconds)).foregroundStyle(.secondary)
                            }
                            .font(.caption2)
                            .padding(.leading, 14)
                            .background(active == .task(i, j)
                                ? Color.accentColor.opacity(0.12) : .clear)
                        }
                    }
                }
                if nodes.isEmpty {
                    Text("nothing tracked in this period")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
