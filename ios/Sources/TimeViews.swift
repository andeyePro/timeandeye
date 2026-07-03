import SwiftUI
import AndeyeTTCore
import AndeyeTTPhone

// The phone's Time pages: the Spent donut (project wedges, tap to expand a
// task ring — the Mac SpentView's interaction reshaped for touch), the
// day's slices as a simple vertical timeline, and the LIVE mini-pie that
// lives in NowView's toolbar. All geometry comes from Core's PieGeometry;
// only the SwiftUI drawing lives here.

// MARK: - Colours (mirrors AppController.colour(for:) — override, then hash)

enum PhonePalette {
    static func colour(for ref: TaskRef, overrides: [String: String]) -> Color {
        if let hex = overrides[ref.storageKey], let c = Color(hex: hex) { return c }
        var hash: UInt64 = 5381
        for byte in String(describing: ref).utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        return Color(hue: Double(hash % 360) / 360, saturation: 0.55, brightness: 0.85)
    }

    /// A project wedge takes its first task's colour, like the Mac pie.
    static func colour(project node: TimeAggregator.Node, index: Int,
                       overrides: [String: String]) -> Color {
        if let ref = node.children.first?.ref {
            return colour(for: ref, overrides: overrides)
        }
        return Color(hue: (Double(index) * 0.13).truncatingRemainder(dividingBy: 1),
                     saturation: 0.5, brightness: 0.85)
    }
}

private extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Mini-pie (the toolbar icon: today's projects, live)

struct MiniPieIcon: View {
    let nodes: [TimeAggregator.Node]
    let overrides: [String: String]

    var body: some View {
        if nodes.isEmpty {
            Image(systemName: "chart.pie")
        } else {
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2
                let total = nodes.reduce(0.0) { $0 + $1.seconds }
                let angles = PieGeometry.angles(weights: nodes.map(\.seconds), total: total)
                context.drawLayer { ctx in
                    for (i, node) in nodes.enumerated() {
                        let (a0, a1) = angles[i]
                        var path = Path()
                        path.move(to: centre)
                        path.addArc(center: centre, radius: r, startAngle: .degrees(a0),
                                    endAngle: .degrees(a1), clockwise: false)
                        path.closeSubpath()
                        ctx.fill(path, with: .color(
                            PhonePalette.colour(project: node, index: i, overrides: overrides)))
                    }
                    // Punch the donut hole to transparent so the bar shows through.
                    ctx.blendMode = .destinationOut
                    var hole = Path()
                    hole.addArc(center: centre, radius: r * 0.4, startAngle: .degrees(0),
                                endAngle: .degrees(360), clockwise: false)
                    ctx.fill(hole, with: .color(.black))
                }
            }
            .frame(width: 24, height: 24)
        }
    }
}

// MARK: - Spent (the pie page)

/// Donut of the period's time by project. Tap a wedge to expand its task
/// ring (tap a task arc to read it in the centre); tap the same wedge or
/// empty space to collapse. Selection is label-keyed (PieGeometry.Selection)
/// so a reload re-sorting `nodes` can't retarget it.
struct SpentPhoneView: View {
    @ObservedObject var controller: PhoneController
    @State private var period: TimePeriod = .today
    @State private var nodes: [TimeAggregator.Node] = []
    @State private var selection: PieGeometry.Selection = .none
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 12) {
            Picker("Period", selection: $period) {
                ForEach([TimePeriod.today, .thisWeek]) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)

            if nodes.isEmpty {
                Spacer()
                Text("nothing tracked in this period")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                GeometryReader { geo in
                    pie(in: geo.size)
                }
                legend
                    .frame(maxHeight: 220)
            }
        }
        .padding()
        .navigationTitle("Time")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    TimelinePhoneView(controller: controller)
                } label: {
                    Image(systemName: "calendar.day.timeline.left")
                }
                .accessibilityLabel("Timeline")
            }
        }
        .onAppear { reload() }
        .onChange(of: period) { _, _ in reload() }
        .onReceive(timer) { _ in reload() }
    }

    private func reload() {
        let (from, to) = period.range(anchor: Date(), now: Date())
        nodes = controller.spentNodes(from: from, to: to)
    }

    private var totalSeconds: TimeInterval { nodes.reduce(0) { $0 + $1.seconds } }

    private var resolved: PieGeometry.Resolved? {
        PieGeometry.resolve(selection, in: nodes)
    }

    private func projectColour(_ node: TimeAggregator.Node, _ i: Int) -> Color {
        PhonePalette.colour(project: node, index: i,
                            overrides: controller.settings.taskColours)
    }

    private func taskColour(_ node: TimeAggregator.Node) -> Color {
        guard let ref = node.ref else { return .gray }
        return PhonePalette.colour(for: ref, overrides: controller.settings.taskColours)
    }

    private func hm(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }

    // MARK: Drawing

    private func pie(in size: CGSize) -> some View {
        let side = min(size.width, size.height)
        let m = PieGeometry.Metrics(side: side)
        let projectAngles = PieGeometry.angles(weights: nodes.map(\.seconds),
                                               total: totalSeconds)
        return Canvas { context, canvasSize in
            let centre = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            context.drawLayer { ctx in
                for (i, node) in nodes.enumerated() {
                    let (a0, a1) = projectAngles[i]
                    let highlighted = resolved?.project == i
                    var path = Path()
                    path.move(to: centre)
                    path.addArc(center: centre, radius: highlighted ? m.r1 + 3 : m.r1,
                                startAngle: .degrees(a0), endAngle: .degrees(a1),
                                clockwise: false)
                    path.closeSubpath()
                    ctx.fill(path, with: .color(projectColour(node, i)
                        .opacity(highlighted ? 1 : 0.88)))
                }
                ctx.blendMode = .destinationOut
                var hole = Path()
                hole.addArc(center: centre, radius: m.hole, startAngle: .degrees(0),
                            endAngle: .degrees(360), clockwise: false)
                ctx.fill(hole, with: .color(.black))
            }
            drawCentreLabel(context, centre)

            if let pi = resolved?.project, pi < nodes.count {
                let (p0, p1) = projectAngles[pi]
                let tasks = nodes[pi].children
                let taskAngles = PieGeometry.angles(weights: tasks.map(\.seconds),
                                                    total: nodes[pi].seconds,
                                                    within: (p0, p1))
                for (j, task) in tasks.enumerated() {
                    let (a0, a1) = taskAngles[j]
                    let highlighted = resolved?.task == j
                    let outer = m.r1 + m.gap + m.ringWidth + (highlighted ? 3 : 0)
                    var path = Path()
                    path.addArc(center: centre, radius: outer, startAngle: .degrees(a0),
                                endAngle: .degrees(a1), clockwise: false)
                    path.addArc(center: centre, radius: m.r1 + m.gap,
                                startAngle: .degrees(a1), endAngle: .degrees(a0),
                                clockwise: true)
                    path.closeSubpath()
                    context.fill(path, with: .color(taskColour(task)
                        .opacity(highlighted ? 1 : 0.85)))
                }
            }
        }
        .onTapGesture { location in
            let hit = hitTest(location, size: size, metrics: m)
            selection = (hit == selection || hit == .none) ? .none : hit
        }
    }

    private func drawCentreLabel(_ context: GraphicsContext, _ centre: CGPoint) {
        let (title, seconds): (String, TimeInterval)
        if let r = resolved {
            let project = nodes[r.project]
            if let ti = r.task {
                let t = project.children[ti]
                (title, seconds) = (t.label, t.seconds)
            } else {
                (title, seconds) = (project.label, project.seconds)
            }
        } else {
            (title, seconds) = ("total", totalSeconds)
        }
        let short = title.count > 22 ? String(title.prefix(21)) + "…" : title
        let pct = totalSeconds > 0 ? Int((seconds / totalSeconds * 100).rounded()) : 0
        context.draw(Text("\(short)\n\(hm(seconds)) · \(pct)%")
            .font(.caption2)
            .foregroundStyle(.primary), at: centre)
    }

    // MARK: Hit testing (wedge → project, task-ring arc → task)

    private func hitTest(_ point: CGPoint, size: CGSize,
                         metrics m: PieGeometry.Metrics) -> PieGeometry.Selection {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let angle = PieGeometry.polarAngle(dx: point.x - centre.x, dy: point.y - centre.y)
        let r = hypot(point.x - centre.x, point.y - centre.y)
        let projectAngles = PieGeometry.angles(weights: nodes.map(\.seconds),
                                               total: totalSeconds)
        switch PieGeometry.band(radius: r, metrics: m) {
        case .wedge:
            guard let i = PieGeometry.index(at: angle, in: projectAngles) else { return .none }
            return .project(nodes[i].label)
        case .taskRing:
            guard let pi = resolved?.project else { return .none }
            let project = nodes[pi]
            let taskAngles = PieGeometry.angles(weights: project.children.map(\.seconds),
                                                total: project.seconds,
                                                within: projectAngles[pi])
            if let j = PieGeometry.index(at: angle, in: taskAngles) {
                return .task(project.label, project.children[j].label)
            }
            return .project(project.label)
        case .appRing, .outside:
            return .none    // no app level on the phone (no focus spans)
        }
    }

    // MARK: Legend

    private var legend: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(nodes.enumerated()), id: \.element.label) { i, node in
                    Button {
                        selection = selection == .project(node.label)
                            ? .none : .project(node.label)
                    } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(projectColour(node, i))
                                .frame(width: 12, height: 12)
                            Text(node.label).lineLimit(1)
                            Spacer()
                            Text(hm(node.seconds)).foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if resolved?.project == i {
                        ForEach(Array(node.children.enumerated()),
                                id: \.element.label) { _, task in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(taskColour(task))
                                    .frame(width: 9, height: 9)
                                Text(task.label).lineLimit(1)
                                Spacer()
                                Text(hm(task.seconds)).foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .padding(.leading, 20)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Timeline (the day's slices, top to bottom)

/// Today's slices as a simple vertical list: colour bar, task, start–end,
/// duration; the running slice ticks at the bottom. v1 is read-only — edits
/// stay a Mac (and later) feature.
struct TimelinePhoneView: View {
    @ObservedObject var controller: PhoneController
    @State private var sessions: [Session] = []
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        List {
            if sessions.isEmpty && controller.tracking == nil {
                Text("Nothing tracked today")
                    .foregroundStyle(.secondary)
            }
            ForEach(sessions, id: \.id) { s in
                row(task: s.task, start: s.start, end: s.end, live: false)
            }
            if let live = controller.tracking {
                row(task: live.task, start: live.since, end: now, live: true)
            }
        }
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { reload() }
        .onAppear { reload() }
        .onReceive(clock) { now = $0 }
    }

    private func reload() {
        let start = Calendar.current.startOfDay(for: Date())
        sessions = controller.bankedSessions(from: start, to: Date())
    }

    private func row(task: TaskRef, start: Date, end: Date, live: Bool) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(PhonePalette.colour(for: task,
                                          overrides: controller.settings.taskColours))
                .frame(width: 4, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.name(of: task)).lineLimit(1)
                Text(live
                     ? "\(time(start)) – now"
                     : "\(time(start)) – \(time(end))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                if live {
                    Image(systemName: "record.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                Text(duration(start, end))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(live ? .primary : .secondary)
            }
        }
    }

    private func time(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }

    private func duration(_ start: Date, _ end: Date) -> String {
        let m = Int(end.timeIntervalSince(start)) / 60
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }
}
