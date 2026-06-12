import SwiftUI
import AmbitickCore
import AmbitickMac

/// Interactive timeline.
/// - Two-finger scroll pans, pinch and ± zoom, opens framed on the latest
///   work block (sessions separated by < 1 h).
/// - Drag on empty space draws a new slice (snapping to neighbours); a plain
///   click in a gap proposes a slice filling that gap.
/// - Hover near a slice edge for a drag handle; dragging an edge over a
///   neighbour eats into it (sub-minute remnants are deleted). Shrinking
///   leaves a gap untouched.
/// - Click a slice to edit (start / end / duration as clickable h:mm fields,
///   comment, delete); saving an overlap proposes the neighbour trim first.
/// - The live slice supports moving its start (applies immediately).
/// - The detail strip shows the windows inside the selected slice, joined to
///   the bar by connector lines; click a chip for everything recorded.
struct TimelineView: View {
    @ObservedObject var controller: AppController
    @State private var dayOffset = 0
    @State private var viewStart: Date = Calendar.current.startOfDay(for: Date())
    @State private var viewSpan: TimeInterval = 86_400
    @State private var selection = Set<UUID>()
    @State private var editing: Session?
    @State private var isNewEditing = false
    @State private var editStart = Date()
    @State private var editEnd = Date()
    @State private var editComment = ""
    @State private var editTask: TaskRef?
    @State private var conflicts: [Session] = []
    @State private var filter = ""
    @State private var refreshTick = 0
    @State private var pinchBaseSpan: TimeInterval?
    @State private var drawDraft: (start: Date, end: Date)?
    @State private var edgeDrag: (id: UUID, start: Date, end: Date)?
    @State private var hoveredSlice: UUID?
    @State private var barWidth: CGFloat = 900
    @State private var selectedSpanDetail: String?
    @State private var scrollMonitor: Any?

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            GeometryReader { geo in
                bar(width: geo.size.width)
                    .onAppear { barWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in barWidth = w }
            }
            .frame(height: 96)
            if !selection.isEmpty && editing == nil {
                reassignBar
            }
            if let session = editing {
                editor(session)
                detailStrip(session)
            }
            if let detail = selectedSpanDetail {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .coordinateSpace(name: "timeline")
        .overlayPreferenceValue(RectKey.self) { anchors in connectors(anchors) }
        .onReceive(timer) { _ in refreshTick += 1 }
        .onAppear {
            zoomToLatestBlock()
            installScrollPan()
        }
        .onDisappear {
            if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor) }
            scrollMonitor = nil
        }
    }

    // MARK: - Data

    private var sessions: [Session] {
        _ = refreshTick
        var list = controller.timelineSessions(dayOffset: dayOffset)
        if let drag = edgeDrag, let i = list.firstIndex(where: { $0.id == drag.id }) {
            list[i].start = drag.start
            list[i].end = drag.end
        }
        return list
    }

    private var dayStart: Date {
        Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date())
    }

    private var dayEnd: Date { dayStart.addingTimeInterval(86_400) }

    private var snapTolerance: TimeInterval { viewSpan / Double(barWidth) * 8 }

    // MARK: - Viewport

    private func zoomToLatestBlock() {
        guard let block = TimelineMath.latestBlock(in: sessions) else {
            viewStart = dayStart
            viewSpan = 86_400
            return
        }
        let pad = max(block.end.timeIntervalSince(block.start) * 0.1, 300)
        viewStart = max(block.start.addingTimeInterval(-pad), dayStart)
        viewSpan = min(block.end.timeIntervalSince(viewStart) + pad, 86_400)
    }

    private func changeDay(_ delta: Int) {
        dayOffset += delta
        editing = nil
        selection = []
        selectedSpanDetail = nil
        DispatchQueue.main.async { zoomToLatestBlock() }
    }

    private func clampViewport() {
        viewSpan = min(max(viewSpan, 300), 86_400)
        viewStart = max(dayStart, min(viewStart, dayEnd.addingTimeInterval(-viewSpan)))
    }

    private func zoom(by factor: TimeInterval) {
        let centre = viewStart.addingTimeInterval(viewSpan / 2)
        viewSpan *= factor
        viewStart = centre.addingTimeInterval(-viewSpan / 2)
        clampViewport()
    }

    /// Two-finger scroll pans the bar (drag is reserved for drawing).
    private func installScrollPan() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard NSApp.keyWindow?.title.contains("Timeline") == true else { return event }
            let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            viewStart = viewStart.addingTimeInterval(-TimeInterval(dx / barWidth) * viewSpan)
            clampViewport()
            return event
        }
    }

    private func xFor(_ date: Date, width: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(viewStart) / viewSpan) * width
    }

    private func dateFor(_ x: CGFloat, width: CGFloat) -> Date {
        viewStart.addingTimeInterval(TimeInterval(x / width) * viewSpan)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button { changeDay(-1) } label: { Image(systemName: "chevron.left") }
            Text(dayStart.formatted(date: .abbreviated, time: .omitted))
                .font(.headline)
                .frame(width: 130)
            Button { changeDay(1) } label: { Image(systemName: "chevron.right") }
                .disabled(dayOffset >= 0)
            if dayOffset != 0 {
                Button("Today") { dayOffset = 0; changeDay(0) }
            }
            Spacer()
            Button { zoom(by: 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
            Button { zoom(by: 1 / 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
            Button("Block") { zoomToLatestBlock() }
            Button("Day") { viewStart = dayStart; viewSpan = 86_400 }
            Text(totalText).font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private var totalText: String {
        let total = sessions.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        return "tracked: \(MenuTitle.text(elapsed: total, certainty: nil, showPercent: false))"
    }

    // MARK: - Bar

    private func bar(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(0.06))
            gridLines(width: width)
            if let draft = drawDraft {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.4))
                    .frame(width: max(xFor(draft.end, width: width) - xFor(draft.start, width: width), 2),
                           height: 44)
                    .position(x: (xFor(draft.start, width: width) + xFor(draft.end, width: width)) / 2,
                              y: 56)
            }
            ForEach(sessions) { session in
                slice(session, width: width)
            }
        }
        .frame(height: 96)
        .clipped()
        .contentShape(Rectangle())
        .gesture(drawGesture(width: width))
        .onTapGesture(coordinateSpace: .local) { location in gapClick(at: location, width: width) }
        .gesture(MagnificationGesture()
            .onChanged { value in
                if pinchBaseSpan == nil { pinchBaseSpan = viewSpan }
                let centre = viewStart.addingTimeInterval(viewSpan / 2)
                viewSpan = (pinchBaseSpan ?? viewSpan) / TimeInterval(value)
                viewStart = centre.addingTimeInterval(-viewSpan / 2)
                clampViewport()
            }
            .onEnded { _ in pinchBaseSpan = nil })
    }

    /// Drag on empty space draws a new slice, snapping to neighbours.
    private func drawGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let a = dateFor(min(value.startLocation.x, value.location.x), width: width)
                let b = dateFor(max(value.startLocation.x, value.location.x), width: width)
                drawDraft = (
                    TimelineMath.snap(a, to: sessions, tolerance: snapTolerance),
                    TimelineMath.snap(b, to: sessions, tolerance: snapTolerance)
                )
            }
            .onEnded { _ in
                guard let draft = drawDraft else { return }
                drawDraft = nil
                guard draft.end.timeIntervalSince(draft.start) >= 60 else { return }
                openEditor(for: makeDraft(start: draft.start, end: draft.end), isNew: true)
            }
    }

    /// Plain click in a gap proposes a slice filling that gap.
    private func gapClick(at location: CGPoint, width: CGFloat) {
        guard editing == nil, selection.isEmpty else {
            editing = nil
            selection = []
            selectedSpanDetail = nil
            return
        }
        let point = dateFor(location.x, width: width)
        guard let gap = TimelineMath.gap(at: point, in: sessions,
                                         within: dayStart...min(dayEnd, Date())) else { return }
        // Cap a cavernous gap at 2h around the click, snapped to neighbours.
        let start = max(gap.start, point.addingTimeInterval(-3600))
        let end = min(gap.end, point.addingTimeInterval(3600))
        openEditor(for: makeDraft(start: TimelineMath.snap(start, to: sessions, tolerance: snapTolerance),
                                  end: TimelineMath.snap(end, to: sessions, tolerance: snapTolerance)),
                   isNew: true)
    }

    private func makeDraft(start: Date, end: Date) -> Session {
        let likely = controller.pickList().first?.ref ?? .op(0)
        return Session(task: likely, start: start, end: end, certainty: 1.0,
                       comment: nil)
    }

    private func gridLines(width: CGFloat) -> some View {
        let step: TimeInterval = viewSpan > 6 * 3600 ? 3600
            : viewSpan > 3600 ? 900 : 300
        let first = viewStart.timeIntervalSince(dayStart)
        let start = dayStart.addingTimeInterval((first / step).rounded(.down) * step)
        let count = Int(viewSpan / step) + 2
        return ForEach(0..<count, id: \.self) { i in
            let tick = start.addingTimeInterval(TimeInterval(i) * step)
            VStack(alignment: .leading, spacing: 0) {
                Text(tick.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 1, height: 78)
            }
            .position(x: xFor(tick, width: width) + 14, y: 48)
        }
    }

    // MARK: - Slices

    @ViewBuilder
    private func slice(_ session: Session, width: CGFloat) -> some View {
        let isLive = session.id == AppController.liveSessionID
        let x0 = xFor(session.start, width: width)
        let x1 = xFor(session.end, width: width)
        let w = max(x1 - x0, 3)
        let selected = selection.contains(session.id) || editing?.id == session.id
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(nsColor: controller.colour(for: session.task))
                .opacity(isLive ? 0.55 : 0.9))
            .overlay(alignment: .leading) {
                if w > 44 {
                    Text(controller.name(of: .task(session.task)))
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .padding(.leading, 3)
                        .foregroundStyle(.black.opacity(0.8))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .overlay { edgeHandles(session, sliceWidth: w) }
            .frame(width: w, height: 44)
            .position(x: x0 + w / 2, y: 56)
            .help("\(controller.name(of: .task(session.task)))  \(slot(session))")
            .onHover { inside in hoveredSlice = inside ? session.id : nil }
            .anchorPreference(key: RectKey.self, value: .bounds) { anchor in
                editing?.id == session.id ? ["slice": anchor] : [:]
            }
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) {
                    guard !isLive else { return }   // the live slice cannot be batch-edited
                    if selection.contains(session.id) { selection.remove(session.id) }
                    else { selection.insert(session.id) }
                    editing = nil
                } else {
                    selection = []
                    openEditor(for: session, isNew: false)
                }
            }
    }

    /// Hover near an edge → drag handle. Dragging over neighbours eats into
    /// them on release; shrinking leaves the gap (never edits the neighbour).
    @ViewBuilder
    private func edgeHandles(_ session: Session, sliceWidth: CGFloat) -> some View {
        let isLive = session.id == AppController.liveSessionID
        if hoveredSlice == session.id, sliceWidth > 24, !isLive {
            HStack {
                handle(session, edge: .leading)
                Spacer()
                handle(session, edge: .trailing)
            }
        }
    }

    private enum Edge { case leading, trailing }

    private func handle(_ session: Session, edge: Edge) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.85))
            .frame(width: 5, height: 28)
            .cornerRadius(2)
            .padding(2)
            .contentShape(Rectangle().inset(by: -4))
            .gesture(DragGesture(coordinateSpace: .named("timeline"))
                .onChanged { value in
                    let dt = TimeInterval(value.translation.width / barWidth) * viewSpan
                    var start = session.start
                    var end = session.end
                    if edge == .leading {
                        start = TimelineMath.snap(session.start.addingTimeInterval(dt),
                                                  to: sessions, excluding: session.id,
                                                  tolerance: snapTolerance)
                        start = min(start, end.addingTimeInterval(-60))
                    } else {
                        end = TimelineMath.snap(session.end.addingTimeInterval(dt),
                                                to: sessions, excluding: session.id,
                                                tolerance: snapTolerance)
                        end = max(end, start.addingTimeInterval(60))
                    }
                    edgeDrag = (session.id, start, end)
                }
                .onEnded { _ in
                    guard let drag = edgeDrag else { return }
                    edgeDrag = nil
                    var edited = session
                    edited.start = drag.start
                    edited.end = drag.end
                    let base = controller.timelineSessions(dayOffset: dayOffset)
                        .filter { $0.id != AppController.liveSessionID }
                    let trims = TimelineMath.trims(for: drag.start, drag.end,
                                                   excluding: session.id, in: base)
                    Task {
                        for trim in trims {
                            if trim.delete {
                                await controller.deleteTimelineSession(trim.session)
                            } else {
                                await controller.applyTimelineEdit(trim.session)
                            }
                        }
                        await controller.applyTimelineEdit(edited)
                    }
                })
    }

    private func slot(_ session: Session) -> String {
        "\(session.start.formatted(date: .omitted, time: .shortened)) – \(session.end.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: - Reassign

    private var reassignBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Reassign \(selection.count) slices:").font(.caption)
                TextField("type to filter tasks", text: $filter)
                    .textFieldStyle(.roundedBorder).font(.caption).frame(width: 180)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(filteredTasks(), id: \.ref) { task in
                        Button(task.subject) {
                            let picked = sessions.filter { selection.contains($0.id) }
                            Task { await controller.reassignTimelineSessions(picked, to: task.ref) }
                            selection = []
                        }
                    }
                }
            }
        }
    }

    private func filteredTasks() -> [WorkTask] {
        controller.searchTasks(filter)
    }

    // MARK: - Editor

    private func openEditor(for session: Session, isNew: Bool) {
        editing = session
        isNewEditing = isNew
        editStart = session.start
        editEnd = session.end
        editComment = session.comment ?? ""
        editTask = session.task
        conflicts = []
        selectedSpanDetail = nil
    }

    private var durationBinding: Binding<Date> {
        Binding(
            get: { dayStart.addingTimeInterval(editEnd.timeIntervalSince(editStart)) },
            set: { newValue in
                applyDurationChange(max(newValue.timeIntervalSince(dayStart), 60))
            })
    }

    private func applyDurationChange(_ newDuration: TimeInterval) {
        let old = editEnd.timeIntervalSince(editStart)
        if newDuration <= old {
            editEnd = editStart.addingTimeInterval(newDuration)
            return
        }
        let grow = newDuration - old
        let endBlocked = sessions.contains {
            $0.id != editing?.id && $0.start >= editEnd
                && $0.start.timeIntervalSince(editEnd) < grow
        }
        let startBlocked = sessions.contains {
            $0.id != editing?.id && $0.end <= editStart
                && editStart.timeIntervalSince($0.end) < grow
        }
        if endBlocked && !startBlocked {
            editStart = editStart.addingTimeInterval(-grow)
        } else {
            editEnd = editEnd.addingTimeInterval(grow)
        }
    }

    @ViewBuilder
    private func editor(_ session: Session) -> some View {
        let isLive = session.id == AppController.liveSessionID
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if isNewEditing {
                    taskPicker
                } else {
                    Text(controller.name(of: .task(session.task))).font(.headline)
                    if isLive {
                        Text("live").font(.caption2).padding(.horizontal, 4)
                            .background(.green.opacity(0.3), in: Capsule())
                    }
                }
                Spacer()
                Button { editing = nil } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain)
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: controller.colour(for: editTask ?? session.task)) },
                    set: { controller.setColour(NSColor($0), for: editTask ?? session.task) }))
                    .labelsHidden().frame(width: 28)
                    .help("Task colour (used everywhere)")
            }
            if isLive {
                HStack(spacing: 16) {
                    DatePicker("Started", selection: $editStart, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                    Button("Apply") {
                        controller.adjustLiveStart(to: editStart)
                        editing = nil
                    }
                    Text("end follows the clock").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 16) {
                    DatePicker("Start", selection: $editStart, displayedComponents: .hourAndMinute)
                    DatePicker("End", selection: $editEnd, displayedComponents: .hourAndMinute)
                    DatePicker("Duration", selection: durationBinding,
                               displayedComponents: .hourAndMinute)
                }
                .datePickerStyle(.field)
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left").foregroundStyle(.secondary).font(.caption)
                    TextField("comment (sent to OP)", text: $editComment)
                        .textFieldStyle(.roundedBorder).font(.caption)
                }
                if !conflicts.isEmpty {
                    conflictProposal
                }
                HStack {
                    Button {
                        attemptSave(session)
                    } label: {
                        Label(isNewEditing ? "Create" : "Save",
                              systemImage: "checkmark.circle")
                    }
                    if !isNewEditing {
                        Button(role: .destructive) {
                            Task { await controller.deleteTimelineSession(session) }
                            editing = nil
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                    Spacer()
                    if !isNewEditing {
                        Text("\(Int((session.certainty * 100).rounded()))% certain · \(session.pushedToOP ? "in OP" : "local")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var taskPicker: some View {
        HStack {
            TextField("filter tasks", text: $filter)
                .textFieldStyle(.roundedBorder).font(.caption).frame(width: 140)
            Picker("Task", selection: Binding(
                get: { editTask ?? .op(0) },
                set: { editTask = $0 })) {
                ForEach(filteredTasks(), id: \.ref) { task in
                    Text(task.subject).tag(task.ref)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
        }
    }

    private func attemptSave(_ session: Session) {
        let overlapping = sessions.filter {
            $0.id != session.id && $0.id != AppController.liveSessionID
                && $0.end > editStart && $0.start < editEnd
        }
        if overlapping.isEmpty || !conflicts.isEmpty {
            var edited = session
            edited.task = editTask ?? session.task
            edited.start = editStart
            edited.end = max(editEnd, editStart.addingTimeInterval(60))
            edited.comment = editComment.isEmpty ? nil : editComment
            let isNew = isNewEditing
            Task {
                for trim in TimelineMath.trims(for: edited.start, edited.end,
                                               excluding: edited.id,
                                               in: overlapping) {
                    if trim.delete {
                        await controller.deleteTimelineSession(trim.session)
                    } else {
                        await controller.applyTimelineEdit(trim.session)
                    }
                }
                if isNew {
                    await controller.createTimelineSession(edited)
                } else {
                    await controller.applyTimelineEdit(edited)
                }
            }
            editing = nil
            conflicts = []
        } else {
            conflicts = overlapping
        }
    }

    private var conflictProposal: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(conflicts) { conflict in
                Text("Overlaps \(controller.name(of: .task(conflict.task))) \(slot(conflict)) — saving will trim it to avoid the overlap.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("Press \(isNewEditing ? "Create" : "Save") again to apply, or adjust the times.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Detail strip + connectors

    private func detailStrip(_ session: Session) -> some View {
        let spans = controller.timelineSpans(for: session)
        let total = max(session.end.timeIntervalSince(session.start), 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Windows during this slice").font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                        let fraction = span.end.timeIntervalSince(span.start) / total
                        let label = [span.signal.app, span.signal.windowTitle]
                            .compactMap { $0 }.joined(separator: " – ")
                        Rectangle()
                            .fill(Color(nsColor: controller.colour(for: session.task))
                                .opacity(span.certainty >= 0.6 ? 0.8 : 0.35))
                            .overlay {
                                if fraction * geo.size.width > 50 {
                                    Text(label).font(.system(size: 9)).lineLimit(1)
                                        .foregroundStyle(.black.opacity(0.8))
                                }
                            }
                            .frame(width: max(fraction * geo.size.width, 2))
                            .help(label)
                            .onTapGesture { selectedSpanDetail = detailText(span) }
                    }
                    if spans.isEmpty {
                        Text("no span detail recorded for this period")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(height: 26)
            .anchorPreference(key: RectKey.self, value: .bounds) { ["strip": $0] }
        }
    }

    private func detailText(_ span: FocusSpan) -> String {
        """
        \(span.signal.app)\(span.signal.windowTitle.map { " – \($0)" } ?? "")
        \(span.start.formatted(date: .omitted, time: .standard)) – \(span.end.formatted(date: .omitted, time: .standard))  (\(Int(span.end.timeIntervalSince(span.start)))s)
        attributed: \(controller.name(of: span.target))  certainty \(String(format: "%.0f%%", span.certainty * 100))
        url: \(span.signal.tabURL ?? "-")
        """
    }

    /// Lines from the selected slice's bottom corners to the strip's top
    /// corners — the visual statement that the strip is a zoom of the slice.
    private func connectors(_ anchors: [String: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            if editing != nil, let sliceAnchor = anchors["slice"],
               let stripAnchor = anchors["strip"] {
                let sliceRect = proxy[sliceAnchor]
                let stripRect = proxy[stripAnchor]
                Path { path in
                    path.move(to: CGPoint(x: sliceRect.minX, y: sliceRect.maxY))
                    path.addLine(to: CGPoint(x: stripRect.minX, y: stripRect.minY))
                    path.move(to: CGPoint(x: sliceRect.maxX, y: sliceRect.maxY))
                    path.addLine(to: CGPoint(x: stripRect.maxX, y: stripRect.minY))
                }
                .stroke(Color.accentColor.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Anchor plumbing for the connector lines.
struct RectKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
