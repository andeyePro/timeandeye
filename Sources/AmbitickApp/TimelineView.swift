import SwiftUI
import AmbitickCore
import AmbitickMac

/// Timeline: explicit-viewport day bar (no ScrollView — pan by drag, zoom by
/// pinch/slider/buttons), opening zoomed to the most recent work block
/// (sessions separated by <1 h). Click to edit (start/end/duration as
/// clickable h:mm fields, comment always editable); saving an overlap
/// proposes trimming the neighbour. ⌘-click multi-select reassigns.
struct TimelineView: View {
    @ObservedObject var controller: AppController
    @State private var dayOffset = 0
    @State private var viewStart: Date = Calendar.current.startOfDay(for: Date())
    @State private var viewSpan: TimeInterval = 86_400
    @State private var didInitialZoom = false
    @State private var selection = Set<UUID>()
    @State private var editing: Session?
    @State private var editStart = Date()
    @State private var editEnd = Date()
    @State private var editComment = ""
    @State private var conflicts: [Session] = []
    @State private var filter = ""
    @State private var refreshTick = 0
    @State private var panBase: Date?
    @State private var pinchBaseSpan: TimeInterval?

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            GeometryReader { geo in
                bar(width: geo.size.width)
            }
            .frame(height: 96)
            if !selection.isEmpty && editing == nil {
                reassignBar
            }
            if let session = editing {
                editor(session)
                detailStrip(session)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .onReceive(timer) { _ in refreshTick += 1 }
        .onAppear { zoomToLatestBlock() }
    }

    private var sessions: [Session] {
        _ = refreshTick
        return controller.timelineSessions(dayOffset: dayOffset)
    }

    private var dayStart: Date {
        Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date())
    }

    private var dayEnd: Date { dayStart.addingTimeInterval(86_400) }

    // MARK: - Block zoom

    /// The most recent run of sessions separated by < 1 h, padded.
    private func zoomToLatestBlock() {
        let ordered = sessions.sorted { $0.start < $1.start }
        guard var blockEnd = ordered.last?.end, var blockStart = ordered.last?.start else {
            viewStart = dayStart
            viewSpan = 86_400
            return
        }
        for session in ordered.reversed().dropFirst() {
            if blockStart.timeIntervalSince(session.end) < 3_600 {
                blockStart = min(blockStart, session.start)
                blockEnd = max(blockEnd, session.end)
            } else {
                break
            }
        }
        let pad = max(blockEnd.timeIntervalSince(blockStart) * 0.1, 300)
        viewStart = max(blockStart.addingTimeInterval(-pad), dayStart)
        viewSpan = min(blockEnd.timeIntervalSince(viewStart) + pad, 86_400)
    }

    private func changeDay(_ delta: Int) {
        dayOffset += delta
        editing = nil
        selection = []
        didInitialZoom = false
        DispatchQueue.main.async { zoomToLatestBlock() }
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

    private func zoom(by factor: TimeInterval) {
        let centre = viewStart.addingTimeInterval(viewSpan / 2)
        viewSpan = min(max(viewSpan * factor, 300), 86_400)
        viewStart = max(dayStart, min(centre.addingTimeInterval(-viewSpan / 2),
                                      dayEnd.addingTimeInterval(-viewSpan)))
    }

    private var totalText: String {
        let total = sessions.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        return "tracked: \(MenuTitle.text(elapsed: total, certainty: nil, showPercent: false))"
    }

    // MARK: - The bar (explicit viewport)

    private func xFor(_ date: Date, width: CGFloat) -> CGFloat {
        CGFloat(date.timeIntervalSince(viewStart) / viewSpan) * width
    }

    private func bar(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(0.06))
            gridLines(width: width)
            ForEach(sessions) { session in
                slice(session, width: width)
            }
        }
        .frame(height: 96)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture()
            .onChanged { value in
                if panBase == nil { panBase = viewStart }
                let dt = -TimeInterval(value.translation.width / width) * viewSpan
                let proposed = (panBase ?? viewStart).addingTimeInterval(dt)
                viewStart = max(dayStart, min(proposed, dayEnd.addingTimeInterval(-viewSpan)))
            }
            .onEnded { _ in panBase = nil })
        .gesture(MagnificationGesture()
            .onChanged { value in
                if pinchBaseSpan == nil { pinchBaseSpan = viewSpan }
                let centre = viewStart.addingTimeInterval(viewSpan / 2)
                viewSpan = min(max((pinchBaseSpan ?? viewSpan) / TimeInterval(value), 300), 86_400)
                viewStart = max(dayStart, min(centre.addingTimeInterval(-viewSpan / 2),
                                              dayEnd.addingTimeInterval(-viewSpan)))
            }
            .onEnded { _ in pinchBaseSpan = nil })
    }

    private func gridLines(width: CGFloat) -> some View {
        // Tick spacing adapts to zoom: hour ticks zoomed out, 5-min zoomed in.
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

    private func slice(_ session: Session, width: CGFloat) -> some View {
        let isLive = session.id == AppController.liveSessionID
        let x0 = xFor(session.start, width: width)
        let x1 = xFor(session.end, width: width)
        let w = max(x1 - x0, 3)
        let selected = selection.contains(session.id) || editing?.id == session.id
        return RoundedRectangle(cornerRadius: 3)
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
            .frame(width: w, height: 44)
            .position(x: x0 + w / 2, y: 56)
            .help("\(controller.name(of: .task(session.task)))  \(slot(session))")
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) {
                    if selection.contains(session.id) { selection.remove(session.id) }
                    else { selection.insert(session.id) }
                    editing = nil
                } else if !isLive {
                    selection = []
                    editing = session
                    editStart = session.start
                    editEnd = session.end
                    editComment = session.comment ?? ""
                    conflicts = []
                }
            }
    }

    private func slot(_ session: Session) -> String {
        "\(session.start.formatted(date: .omitted, time: .shortened)) – \(session.end.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: - Reassign (multi-select)

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
        controller.fullPickList().filter {
            filter.isEmpty
                || $0.subject.localizedCaseInsensitiveContains(filter)
                || ($0.project?.localizedCaseInsensitiveContains(filter) ?? false)
        }
    }

    // MARK: - Editor

    /// Duration as a clickable h:mm field: bound to a Date anchored at the
    /// day start, so the hour and minute segments adjust like start/end.
    private var durationBinding: Binding<Date> {
        Binding(
            get: { dayStart.addingTimeInterval(editEnd.timeIntervalSince(editStart)) },
            set: { newValue in
                let newDuration = max(newValue.timeIntervalSince(dayStart), 60)
                applyDurationChange(newDuration)
            })
    }

    /// Martin's rules: grow extends the end unless a slice abuts it (then the
    /// start moves earlier if that side is free); shrink pulls the end in.
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

    private func editor(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(controller.name(of: .task(session.task))).font(.headline)
                Spacer()
                Button { editing = nil } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain)
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
                TextField("comment (sent to OP)", text: $editComment)
                    .textFieldStyle(.roundedBorder).font(.caption)
            }
            if !conflicts.isEmpty {
                conflictProposal
            }
            HStack {
                Button {
                    attemptSave(session)
                } label: { Label("Save", systemImage: "checkmark.circle") }
                Button(role: .destructive) {
                    Task { await controller.deleteTimelineSession(session) }
                    editing = nil
                } label: { Label("Delete", systemImage: "trash") }
                Spacer()
                Text("\(Int((session.certainty * 100).rounded()))% certain · \(session.pushedToOP ? "in OP" : "local")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Overlap handling: saving never silently creates overlaps — the
    /// conflicting neighbours are listed with the trim that would fix them.
    private func attemptSave(_ session: Session) {
        let overlapping = sessions.filter {
            $0.id != session.id && $0.id != AppController.liveSessionID
                && $0.end > editStart && $0.start < editEnd
        }
        if overlapping.isEmpty || !conflicts.isEmpty {
            // Second press (or no conflict): apply, trimming neighbours.
            var edited = session
            edited.start = editStart
            edited.end = max(editEnd, editStart.addingTimeInterval(60))
            edited.comment = editComment.isEmpty ? nil : editComment
            Task {
                for neighbour in overlapping {
                    var trimmed = neighbour
                    if neighbour.start < editStart {
                        trimmed.end = editStart      // neighbour before: pull its end in
                    } else {
                        trimmed.start = editEnd      // neighbour after: push its start back
                    }
                    if trimmed.end.timeIntervalSince(trimmed.start) < 60 {
                        await controller.deleteTimelineSession(neighbour)
                    } else {
                        await controller.applyTimelineEdit(trimmed)
                    }
                }
                await controller.applyTimelineEdit(edited)
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
            Text("Press Save again to apply, or adjust the times.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Window-detail strip

    private func detailStrip(_ session: Session) -> some View {
        let spans = controller.timelineSpans(for: session)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Windows during this slice").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                        let label = [span.signal.app, span.signal.windowTitle]
                            .compactMap { $0 }.joined(separator: " – ")
                        Text("\(label) (\(Int(span.end.timeIntervalSince(span.start)))s)")
                            .font(.system(size: 9))
                            .lineLimit(1)
                            .padding(4)
                            .background(Color(nsColor: controller.colour(for: session.task))
                                .opacity(0.25), in: RoundedRectangle(cornerRadius: 4))
                            .help("\(label)\n\(span.start.formatted(date: .omitted, time: .standard)) – \(span.end.formatted(date: .omitted, time: .standard))\ncertainty \(String(format: "%.2f", span.certainty))\nurl: \(span.signal.tabURL ?? "-")")
                    }
                    if spans.isEmpty {
                        Text("no span detail recorded for this period (recording started 2026-06-12)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
