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
/// A slice: rounded rect, but the live slice gets a zig-zag right edge to
/// signal "ongoing" while keeping the task's full colour.
struct SliceShape: Shape {
    var zigzag: Bool
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 3
        guard zigzag else { return Path(roundedRect: rect, cornerRadius: r) }
        var p = Path()
        let tooth: CGFloat = 5
        let xR = rect.maxX - tooth
        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: xR, y: rect.minY))
        let steps = 5
        let dy = rect.height / CGFloat(steps)
        for i in 0..<steps {
            let y = rect.minY + dy * CGFloat(i)
            p.addLine(to: CGPoint(x: rect.maxX, y: y + dy / 2))
            p.addLine(to: CGPoint(x: xR, y: y + dy))
        }
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addArc(center: CGPoint(x: rect.minX + r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

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
    @State private var edgeOrigin: (start: Date, end: Date)?
    @State private var barWidth: CGFloat = 900
    @State private var selectedSpanIdx = Set<Int>()
    @State private var stripPxPerSec: CGFloat = 2
    @State private var stripPinchBase: CGFloat?
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
                if let detail = singleSpanDetail(session) {
                    Text(detail)
                        .font(.system(.caption, design: .monospaced))
                        .padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .coordinateSpace(name: "timeline")
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
        // While editing an existing slice, the bar reflects the editor's live
        // values — so a handle drag (which updates editStart/editEnd) moves the
        // slice AND the numbers below in lock-step, and Save commits exactly
        // what is shown.
        if let editing, !isNewEditing,
           let i = list.firstIndex(where: { $0.id == editing.id }) {
            list[i].start = editStart
            list[i].end = editEnd
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
        selectedSpanIdx = []
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
            if isNewEditing, editing != nil {
                let px0 = xFor(editStart, width: width)
                let px1 = xFor(editEnd, width: width)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    .frame(width: max(px1 - px0, 2), height: 44)
                    .position(x: (px0 + px1) / 2, y: 56)
            }
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
            selectedSpanIdx = []
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
        // Same colour/opacity as the task's other slices; the live one is told
        // apart by a zig-zag (torn) right edge meaning "ongoing", not by being
        // dimmer.
        let shape = SliceShape(zigzag: isLive)
        shape
            .fill(Color(nsColor: controller.colour(for: session.task)).opacity(0.9))
            .overlay(alignment: .leading) {
                if w > 44 {
                    Text(controller.name(of: .task(session.task)))
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .padding(.leading, 3)
                        .foregroundStyle(labelColour(for: session.task))
                }
            }
            .overlay(shape.stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .frame(width: w, height: 44)
            // Handles overlaid AFTER the frame so the HStack spans the slice
            // width (previously sized to nothing → handles only landed on the
            // last-drawn slice).
            .overlay { edgeHandles(session, sliceWidth: w) }
            .position(x: x0 + w / 2, y: 56)
            .help("\(controller.name(of: .task(session.task)))  \(slot(session))")
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

    /// Grips appear only on the slice you've clicked to edit (hover detection
    /// on positioned views was unreliable; click-to-reveal is the agreed
    /// alternative). Dragging a grip over neighbours eats into them on
    /// release; shrinking leaves the gap.
    @ViewBuilder
    private func edgeHandles(_ session: Session, sliceWidth: CGFloat) -> some View {
        if editing?.id == session.id, sliceWidth > 14 {
            HStack(spacing: 0) {
                handle(session, edge: .leading)
                Spacer(minLength: 0)
                handle(session, edge: .trailing)
            }
        }
    }

    private enum Edge { case leading, trailing }

    private func handle(_ session: Session, edge: Edge) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(.white.opacity(0.9))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.5), lineWidth: 0.5))
            .frame(width: 5, height: 34)
            .contentShape(Rectangle().inset(by: -6))   // fat hit target
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                .onChanged { value in
                    // Drive the editor's live values directly so the slice, the
                    // numbers below and the eventual Save all agree. Anchor to
                    // the bounds captured at gesture start (translation is
                    // cumulative; reading the moving slice would compound).
                    if edgeOrigin == nil { edgeOrigin = (editStart, editEnd) }
                    let origin = edgeOrigin ?? (editStart, editEnd)
                    let dt = TimeInterval(value.translation.width / barWidth) * viewSpan
                    if edge == .leading {
                        var s = TimelineMath.snap(origin.start.addingTimeInterval(dt),
                                                  to: sessions, excluding: session.id,
                                                  tolerance: snapTolerance)
                        s = min(s, editEnd.addingTimeInterval(-60))
                        editStart = s
                    } else {
                        var e = TimelineMath.snap(origin.end.addingTimeInterval(dt),
                                                  to: sessions, excluding: session.id,
                                                  tolerance: snapTolerance)
                        e = max(e, editStart.addingTimeInterval(60))
                        editEnd = e
                    }
                }
                .onEnded { _ in edgeOrigin = nil })
    }

    private func slot(_ session: Session) -> String {
        "\(session.start.formatted(date: .omitted, time: .shortened)) – \(session.end.formatted(date: .omitted, time: .shortened))"
    }

    /// Black on light fills, white on dark — readable on any task colour.
    private func labelColour(for ref: TaskRef) -> Color {
        Color(nsColor: controller.colour(for: ref).readableTextColour)
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
        // The live slice's comment is the in-flight note, not a stored field.
        editComment = session.id == AppController.liveSessionID
            ? controller.manualNote : (session.comment ?? "")
        editTask = session.task
        conflicts = []
        selectedSpanIdx = []
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
                taskPicker   // filter + change/reassign — for the live slice too
                if isLive {
                    Text("live").font(.caption2).padding(.horizontal, 4)
                        .background(.green.opacity(0.3), in: Capsule())
                }
                Spacer()
                Button { editing = nil } label: { Image(systemName: "xmark.circle") }
                    .keyboardShortcut(.cancelAction)   // Esc cancels
                    .buttonStyle(.plain)
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: controller.colour(for: editTask ?? session.task)) },
                    set: { controller.setColour(NSColor($0), for: editTask ?? session.task) }))
                    .labelsHidden().frame(width: 28)
                    .help("Task colour")
            }
            HStack(spacing: 16) {
                DatePicker("Start", selection: $editStart, displayedComponents: .hourAndMinute)
                DatePicker("End", selection: $editEnd, displayedComponents: .hourAndMinute)
                DatePicker("Duration", selection: durationBinding,
                           displayedComponents: .hourAndMinute)
            }
            .datePickerStyle(.field)
            HStack(spacing: 4) {
                Image(systemName: "bubble.left").foregroundStyle(.secondary).font(.caption)
                TextField("comment", text: $editComment)
                    .textFieldStyle(.roundedBorder).font(.caption)
                    .onSubmit { commitEditor(session) }
            }
            if isLive, editEnd > Date().addingTimeInterval(60) {
                Text("End is in the future → keeps tracking, then stops then.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !conflicts.isEmpty { conflictProposal }
            HStack {
                Button { commitEditor(session) } label: {
                    Label(isNewEditing ? "Create" : "Save", systemImage: "checkmark.circle")
                }
                .keyboardShortcut(.defaultAction)   // Enter saves
                if !isNewEditing, !isLive {
                    Button(role: .destructive) {
                        Task { await controller.deleteTimelineSession(session) }
                        editing = nil
                    } label: { Label("Delete", systemImage: "trash") }
                }
                Spacer()
                if !isNewEditing, !isLive {
                    Text("\(Int((session.certainty * 100).rounded()))% · \(session.pushedToOP ? "in OP" : "local")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Route Save to the right path: live slice vs an existing/new slice.
    private func commitEditor(_ session: Session) {
        if session.id == AppController.liveSessionID { saveLive(session) } else { attemptSave(session) }
    }

    /// Commit live-slice edits: change task / start / comment / scheduled end.
    private func saveLive(_ session: Session) {
        if let t = editTask, t != session.task { controller.changeCurrentTask(to: t) }
        controller.adjustLiveStart(to: editStart)
        controller.manualNote = editComment
        controller.scheduleStop(at: editEnd > Date().addingTimeInterval(60) ? editEnd : nil)
        editing = nil
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
            $0.id != session.id && $0.end > editStart && $0.start < editEnd
        }
        if overlapping.isEmpty || !conflicts.isEmpty {
            var edited = session
            edited.task = editTask ?? session.task
            edited.start = editStart
            edited.end = max(editEnd, editStart.addingTimeInterval(60))
            edited.comment = editComment.isEmpty ? nil : editComment
            let isNew = isNewEditing
            let liveOverlap = overlapping.first { $0.id == AppController.liveSessionID }
            Task {
                await controller.undoGroup("\(isNew ? "create" : "edit") \(controller.name(of: .task(edited.task)))") {
                    if let live = liveOverlap, edited.end > live.start, edited.end < Date() {
                        // The live clock cannot overlap recorded history: its
                        // start moves to the edited slice's end.
                        controller.adjustLiveStart(to: edited.end)
                    }
                    for trim in TimelineMath.trims(for: edited.start, edited.end,
                                                   excluding: edited.id,
                                                   in: overlapping.filter { $0.id != AppController.liveSessionID }) {
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
                // Same-task slices now butting up are fused (no data lost).
                await controller.coalesceAdjacent(around: edited.start)
            }
            editing = nil
            conflicts = []
            drawDraft = nil
        } else {
            conflicts = overlapping
        }
    }

    private var conflictProposal: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(conflicts) { conflict in
                Text(conflict.id == AppController.liveSessionID
                     ? "Overlaps the LIVE clock — saving moves its start to \(editEnd.formatted(date: .omitted, time: .shortened))."
                     : "Overlaps \(controller.name(of: .task(conflict.task))) \(slot(conflict)) — saving will trim it to avoid the overlap.")
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
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Windows in \(controller.name(of: .task(session.task))) · \(slot(session))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !spans.isEmpty {
                    Spacer()
                    Button { stripPxPerSec = max(stripPxPerSec / 1.6, 0.2) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    Button { stripPxPerSec = min(stripPxPerSec * 1.6, 40) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                }
            }
            .buttonStyle(.plain)

            if spans.isEmpty {
                Text("no window detail recorded for this period")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(spacing: 1) {
                        ForEach(Array(spans.enumerated()), id: \.offset) { idx, span in
                            spanChip(span, index: idx, task: session.task)
                        }
                    }
                }
                .frame(height: 30)
                .gesture(MagnificationGesture()
                    .onChanged { value in
                        if stripPinchBase == nil { stripPinchBase = stripPxPerSec }
                        stripPxPerSec = min(max((stripPinchBase ?? stripPxPerSec)
                            * CGFloat(value), 0.2), 40)
                    }
                    .onEnded { _ in stripPinchBase = nil })
            }

            if !selectedSpanIdx.isEmpty {
                spanReassignBar(session, spans: spans)
            }
        }
    }

    private func spanChip(_ span: FocusSpan, index: Int, task: TaskRef) -> some View {
        let secs = span.end.timeIntervalSince(span.start)
        let label = [span.signal.app, span.signal.windowTitle].compactMap { $0 }
            .joined(separator: " – ")
        let selected = selectedSpanIdx.contains(index)
        return Rectangle()
            .fill(Color(nsColor: controller.colour(for: task))
                .opacity(span.certainty >= 0.6 ? 0.8 : 0.35))
            .overlay {
                if secs * stripPxPerSec > 44 {
                    Text(label).font(.system(size: 9)).lineLimit(1).padding(.horizontal, 3)
                        .foregroundStyle(labelColour(for: task))
                }
            }
            .overlay(Rectangle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .frame(width: max(secs * stripPxPerSec, 3), height: 28)
            .help("\(label)\n\(secs < 60 ? "\(Int(secs))s" : "\(Int(secs/60))m")  ·  \(span.start.formatted(date: .omitted, time: .standard))")
            .onTapGesture {
                if selectedSpanIdx.contains(index) { selectedSpanIdx.remove(index) }
                else { selectedSpanIdx.insert(index) }
            }
    }

    private func spanReassignBar(_ session: Session, spans: [FocusSpan]) -> some View {
        let ranges = selectedSpanIdx.sorted().compactMap { i -> (start: Date, end: Date)? in
            i < spans.count ? (spans[i].start, spans[i].end) : nil
        }
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Move \(selectedSpanIdx.count) window\(selectedSpanIdx.count == 1 ? "" : "s") to →")
                    .font(.caption)
                TextField("filter tasks", text: $filter)
                    .textFieldStyle(.roundedBorder).font(.caption).frame(width: 150)
                Button { selectedSpanIdx = [] } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(filteredTasks(), id: \.ref) { task in
                        Button {
                            Task { await controller.splitAndReassign(session, ranges: ranges,
                                                                     to: task.ref) }
                            selectedSpanIdx = []
                            editing = nil
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
        .padding(6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Full detail for exactly-one selected window (the "all the data you hold
    /// on that tracking" view), shown beneath the strip.
    private func singleSpanDetail(_ session: Session) -> String? {
        guard selectedSpanIdx.count == 1, let i = selectedSpanIdx.first else { return nil }
        let spans = controller.timelineSpans(for: session)
        guard i < spans.count else { return nil }
        return detailText(spans[i])
    }

    private func detailText(_ span: FocusSpan) -> String {
        """
        \(span.signal.app)\(span.signal.windowTitle.map { " – \($0)" } ?? "")
        \(span.start.formatted(date: .omitted, time: .standard)) – \(span.end.formatted(date: .omitted, time: .standard))  (\(Int(span.end.timeIntervalSince(span.start)))s)
        attributed: \(controller.name(of: span.target))  certainty \(String(format: "%.0f%%", span.certainty * 100))
        url: \(span.signal.tabURL ?? "-")
        """
    }
}
