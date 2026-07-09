import SwiftUI
import andeyeTTCore
import andeyeTTPhone

// The phone's Time pages: the Spent donut (project wedges, tap to expand a
// task ring — the Mac SpentView's interaction reshaped for touch), the
// day's slices as a simple vertical timeline, and the LIVE mini-pie that
// lives in NowView's toolbar. All geometry comes from Core's PieGeometry;
// only the SwiftUI drawing lives here.

// MARK: - Colours (override, then the LEGACY hash)
// The Mac now allocates engine colours (ColourEngine, persisted first-sight
// records in colours.json); the phone keeps the pre-engine hash until those
// records ride a sync pipe, so AUTO colours can differ between devices —
// user overrides (settings.taskColours) agree everywhere.

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

// MARK: - Timeline (the Mac's drawn timeline, reshaped for touch)

/// Today's slices as a real drawn timeline, matching the Mac app's: a
/// horizontal time axis with hour ticks, coloured slice bars with task
/// labels, gaps visible as gaps, a red "now" line, and the live slice
/// growing at the right with the Mac's zig-zag edge. Pinch zooms (anchored
/// on the pinch point), drag pans, both clamped to today; opens framed on
/// the latest block of work like the Mac. Tap a slice for a read-only
/// detail card — edits stay a Mac (and later) feature. Drawing lives in
/// TimelineCanvas (injected slices) so it renders headless for checks.
struct TimelinePhoneView: View {
    @ObservedObject var controller: PhoneController
    @State private var sessions: [Session] = []
    @State private var viewStart = Calendar.current.startOfDay(for: Date())
    @State private var viewSpan: TimeInterval = 86_400
    @State private var selectedID: UUID?
    /// viewStart captured when a pan starts (translation is cumulative).
    @State private var panBase: Date?
    /// Span + the date under the pinch start (and its screen fraction),
    /// held for the whole gesture so the pinch zooms around the fingers.
    @State private var pinchBase: (span: TimeInterval, anchor: Date, frac: Double)?
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    private let minSpan: TimeInterval = 900

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                TimelineCanvas(slices: slices, viewStart: viewStart,
                               viewSpan: viewSpan, now: now, selectedID: selectedID)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        tap(at: location, width: geo.size.width)
                    }
                    .gesture(panGesture(width: geo.size.width))
                    .simultaneousGesture(pinchGesture(width: geo.size.width))
            }
            .frame(height: TimelineCanvas.height)

            if let slice = slices.first(where: { $0.id == selectedID }) {
                detailCard(slice)
            } else if slices.isEmpty {
                Text("Nothing tracked today")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            } else {
                Text("Pinch to zoom · drag to pan · tap a slice for detail")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Day") { showWholeDay() }
                    .accessibilityLabel("Zoom out to the whole day")
            }
        }
        .onAppear { reload(); frameLatestBlock() }
        .onReceive(clock) { tick in
            now = tick
            // Cheap re-query once a minute so slices banked elsewhere appear.
            if Int(tick.timeIntervalSince1970) % 60 == 0 { reload() }
        }
    }

    // MARK: Data

    private var dayBounds: ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: now)
        return start...start.addingTimeInterval(86_400)
    }

    private func reload() {
        sessions = controller.bankedSessions(from: dayBounds.lowerBound, to: Date())
    }

    /// Banked slices + the live one, resolved to labels/colours for drawing.
    private var slices: [TimelineSlice] {
        var out = sessions.map { s in
            TimelineSlice(id: s.id, label: controller.name(of: s.task),
                          start: s.start, end: s.end,
                          colour: PhonePalette.colour(for: s.task,
                                                      overrides: controller.settings.taskColours),
                          isLive: false)
        }
        if let live = controller.tracking {
            out.append(TimelineSlice(id: PhoneController.liveCheckpointID,
                                     label: controller.name(of: live.task),
                                     start: live.since, end: max(now, live.since),
                                     colour: PhonePalette.colour(for: live.task,
                                                                 overrides: controller.settings.taskColours),
                                     isLive: true))
        }
        return out
    }

    // MARK: Viewport

    private func setViewport(start: Date, span: TimeInterval) {
        (viewStart, viewSpan) = TimelineMath.clampViewport(
            start: start, span: span, bounds: dayBounds, minSpan: minSpan)
    }

    private func showWholeDay() {
        setViewport(start: dayBounds.lowerBound, span: 86_400)
    }

    /// Open framed on the latest run of work (like the Mac), padded a touch;
    /// whole day when nothing is tracked yet.
    private func frameLatestBlock() {
        var all = sessions
        if let live = controller.tracking {
            all.append(Session(task: live.task, start: live.since, end: now, certainty: 1))
        }
        guard let block = TimelineMath.latestBlock(in: all) else {
            showWholeDay()
            return
        }
        let pad = max(block.end.timeIntervalSince(block.start) * 0.15, 900)
        setViewport(start: block.start.addingTimeInterval(-pad),
                    span: block.end.timeIntervalSince(block.start) + 2 * pad)
    }

    private func panGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if panBase == nil { panBase = viewStart }
                let dt = -TimeInterval(value.translation.width / width) * viewSpan
                setViewport(start: (panBase ?? viewStart).addingTimeInterval(dt),
                            span: viewSpan)
            }
            .onEnded { _ in panBase = nil }
    }

    private func pinchGesture(width: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchBase == nil {
                    let x = value.startLocation.x
                    let anchor = viewStart.addingTimeInterval(
                        TimeInterval(x / width) * viewSpan)
                    pinchBase = (viewSpan, anchor, Double(x / width))
                }
                guard let base = pinchBase, value.magnification > 0 else { return }
                let span = min(max(base.span / TimeInterval(value.magnification),
                                   minSpan), 86_400)
                setViewport(start: base.anchor.addingTimeInterval(-base.frac * span),
                            span: span)
            }
            .onEnded { _ in pinchBase = nil }
    }

    // MARK: Tap → detail card

    private func tap(at location: CGPoint, width: CGFloat) {
        let date = viewStart.addingTimeInterval(TimeInterval(location.x / width) * viewSpan)
        // Nearest slice under the finger, with a few points of slack so thin
        // slivers stay tappable.
        let slack = TimeInterval(6 / width) * viewSpan
        let hit = slices.first {
            date >= $0.start.addingTimeInterval(-slack)
                && date < $0.end.addingTimeInterval(slack)
        }
        selectedID = hit?.id == selectedID ? nil : hit?.id
    }

    private func detailCard(_ slice: TimelineSlice) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(slice.colour)
                .frame(width: 4, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(slice.label).lineLimit(2)
                Text("\(time(slice.start)) – \(slice.isLive ? "now" : time(slice.end))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 4) {
                if slice.isLive {
                    Image(systemName: "record.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                Text(duration(slice.start, slice.isLive ? now : slice.end))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(slice.isLive ? .primary : .secondary)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func time(_ d: Date) -> String {
        d.formatted(date: .omitted, time: .shortened)
    }

    private func duration(_ start: Date, _ end: Date) -> String {
        let m = Int(end.timeIntervalSince(start)) / 60
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }
}
