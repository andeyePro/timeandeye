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
    @State private var period: Period = .today
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
    }

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
            HStack(alignment: .top, spacing: 16) {
                GeometryReader { geo in
                    pie(in: geo.size)
                }
                legend
                    .frame(width: 250)
            }
        }
        .padding(12)
        .onReceive(timer) { _ in refreshTick += 1 }
    }

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
                drawLabelIfFits(context, node.label, centre: centre,
                                radius: m.r1 * 0.66, a0: a0, a1: a1,
                                depth: m.r1 - m.hole, bold: true,
                                colour: colour(project: node, index: i))
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
                    drawCurvedLabel(context, task.label, centre: centre,
                                    radius: m.r1 + m.gap + m.ringWidth / 2,
                                    a0: a0, a1: a1, colour: taskColour(task))
                }
                if case .task(pi, let tj) = active, tj < tasks.count,
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
                        drawCurvedLabel(context, app.label, centre: centre,
                                        radius: m.r1 + m.gap * 2 + m.ringWidth * 1.5,
                                        a0: a0, a1: a1, colour: taskColour(tasks[tj]))
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

    /// Straight label for the central wedges — drawn only when it fits the
    /// segment (chord across, depth down), in a colour readable on the fill.
    private func drawLabelIfFits(_ context: GraphicsContext, _ label: String,
                                 centre: CGPoint, radius: CGFloat,
                                 a0: Double, a1: Double, depth: CGFloat, bold: Bool,
                                 colour: Color) {
        let sweepRadians = (a1 - a0) * .pi / 180
        guard sweepRadians > 0.02 else { return }
        let available = 2 * radius * sin(min(sweepRadians, .pi) / 2) * 0.92
        let text = Text(label)
            .font(.system(size: bold ? 10 : 9, weight: bold ? .bold : .regular))
            .foregroundStyle(readableText(on: colour))
        let resolved = context.resolve(text)
        let measured = resolved.measure(in: CGSize(width: 600, height: 40))
        guard measured.width <= available, measured.height <= depth else { return }
        let mid = Angle.degrees((a0 + a1) / 2).radians
        context.draw(resolved, at: CGPoint(x: centre.x + cos(mid) * radius,
                                           y: centre.y + sin(mid) * radius))
    }

    /// Curved label hugging a ring arc: each glyph placed and rotated along
    /// the arc, hidden when the word can't fit the arc length, flipped on the
    /// lower half so it reads right-way-up. Colour readable on the fill.
    private func drawCurvedLabel(_ context: GraphicsContext, _ label: String,
                                 centre: CGPoint, radius: CGFloat,
                                 a0: Double, a1: Double, colour: Color) {
        let sweepRad = (a1 - a0) * .pi / 180
        guard sweepRad > 0.02, radius > 0 else { return }
        let chars = Array(label)
        var widths: [CGFloat] = []
        var resolved: [GraphicsContext.ResolvedText] = []
        var total: CGFloat = 0
        let textColour = readableText(on: colour)
        for ch in chars {
            let r = context.resolve(Text(String(ch))
                .font(.system(size: 9)).foregroundStyle(textColour))
            let w = r.measure(in: CGSize(width: 50, height: 30)).width
            widths.append(w)
            resolved.append(r)
            total += w
        }
        let arcLen = radius * sweepRad
        guard total <= arcLen * 0.95 else { return }   // doesn't fit → hide

        let midRad = (a0 + a1) / 2 * .pi / 180
        // Lower half (text would be upside down): flip and reverse.
        let flip = sin(midRad) > 0
        let ordered = flip ? Array(zip(resolved, widths).reversed()) : Array(zip(resolved, widths))
        var lengthCursor = -total / 2
        for (glyph, w) in ordered {
            let centreLen = lengthCursor + w / 2
            let ang = midRad + (flip ? -centreLen : centreLen) / radius
            let p = CGPoint(x: centre.x + cos(ang) * radius,
                            y: centre.y + sin(ang) * radius)
            var ctx = context
            ctx.translateBy(x: p.x, y: p.y)
            ctx.rotate(by: .radians(ang + (flip ? -.pi / 2 : .pi / 2)))
            ctx.draw(glyph, at: .zero)
            lengthCursor += w
        }
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
        if r <= m.outerMost + 3 {
            return active              // app band keeps whatever is open
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

    // MARK: - Colours / labels

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
