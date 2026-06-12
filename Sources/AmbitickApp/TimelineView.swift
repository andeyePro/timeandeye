import SwiftUI
import AmbitickCore
import AmbitickMac

/// Phase-1 timeline: horizontal day bar of task-coloured slices (live session
/// included), day paging, zoom (slider + pinch), click-to-edit with logical
/// duration rules, ⌘-click multi-select + reassign, and a window-detail strip
/// for the selected slice. Phase 2 adds draw-to-create, edge-drag handles and
/// the connected zoom strip.
struct TimelineView: View {
    @ObservedObject var controller: AppController
    @State private var dayOffset = 0
    @State private var zoom: CGFloat = 1.0
    @State private var pinchBase: CGFloat = 1.0
    @State private var selection = Set<UUID>()
    @State private var editing: Session?
    @State private var editStart = Date()
    @State private var editEnd = Date()
    @State private var filter = ""
    @State private var refreshTick = 0

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            bar
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
    }

    private var sessions: [Session] {
        _ = refreshTick
        return controller.timelineSessions(dayOffset: dayOffset)
    }

    private var dayStart: Date {
        Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date())
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button { dayOffset -= 1; editing = nil; selection = [] } label: {
                Image(systemName: "chevron.left")
            }
            Text(dayStart.formatted(date: .abbreviated, time: .omitted))
                .font(.headline)
                .frame(width: 130)
            Button { dayOffset += 1; editing = nil; selection = [] } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(dayOffset >= 0)
            if dayOffset != 0 {
                Button("Today") { dayOffset = 0; editing = nil; selection = [] }
            }
            Spacer()
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $zoom, in: 1...24).frame(width: 160)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            Text(totalText).font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private var totalText: String {
        let total = sessions.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        return "tracked: \(MenuTitle.text(elapsed: total, certainty: nil, showPercent: false))"
    }

    // MARK: - The bar

    private var bar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    hourGrid
                    ForEach(sessions) { session in
                        slice(session)
                    }
                }
                .frame(width: barWidth, height: 88)
            }
            .gesture(MagnificationGesture()
                .onChanged { value in zoom = min(max(pinchBase * value, 1), 24) }
                .onEnded { _ in pinchBase = zoom })
            .onAppear {
                pinchBase = zoom
                if let first = sessions.first { proxy.scrollTo("h\(hour(of: first.start))", anchor: .leading) }
            }
        }
        .frame(height: 96)
    }

    private var barWidth: CGFloat { 900 * zoom }

    private func x(_ date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(dayStart) / 86_400) * barWidth
    }

    private func hour(of date: Date) -> Int {
        Calendar.current.component(.hour, from: date)
    }

    private var hourGrid: some View {
        ForEach(0..<25, id: \.self) { h in
            VStack(alignment: .leading, spacing: 0) {
                Text(h < 24 ? String(format: "%02d", h) : "")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color.secondary.opacity(h % 6 == 0 ? 0.35 : 0.15))
                    .frame(width: 1, height: 72)
            }
            .offset(x: CGFloat(h) / 24 * barWidth)
            .id("h\(h)")
        }
    }

    private func slice(_ session: Session) -> some View {
        let isLive = session.id == AppController.liveSessionID
        let width = max(x(session.end) - x(session.start), 3)
        let selected = selection.contains(session.id) || editing?.id == session.id
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color(nsColor: controller.colour(for: session.task))
                .opacity(isLive ? 0.55 : 0.9))
            .overlay(alignment: .leading) {
                if width > 40 {
                    Text(controller.name(of: .task(session.task)))
                        .font(.system(size: 9))
                        .lineLimit(1)
                        .padding(.leading, 3)
                        .foregroundStyle(.black.opacity(0.8))
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .frame(width: width, height: 40)
            .offset(x: x(session.start), y: 22)
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
                Stepper("Duration: \(durationText)", onIncrement: { bumpDuration(60) },
                        onDecrement: { bumpDuration(-60) })
                    .font(.caption)
            }
            .datePickerStyle(.field)
            HStack {
                Button {
                    var s = session
                    s.start = editStart
                    s.end = max(editEnd, editStart.addingTimeInterval(60))
                    Task { await controller.applyTimelineEdit(s) }
                    editing = nil
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

    private var durationText: String {
        MenuTitle.text(elapsed: editEnd.timeIntervalSince(editStart), certainty: nil,
                       showPercent: false)
    }

    /// Martin's duration logic: growing moves the end later unless another
    /// slice sits right behind it (then the start moves earlier if free);
    /// shrinking always pulls the end in.
    private func bumpDuration(_ delta: TimeInterval) {
        if delta < 0 {
            editEnd = max(editEnd.addingTimeInterval(delta), editStart.addingTimeInterval(60))
            return
        }
        let endBlocked = sessions.contains {
            $0.id != editing?.id && abs($0.start.timeIntervalSince(editEnd)) < 1
        }
        let startBlocked = sessions.contains {
            $0.id != editing?.id && abs($0.end.timeIntervalSince(editStart)) < 1
        }
        if endBlocked && !startBlocked {
            editStart = editStart.addingTimeInterval(-delta)
        } else {
            editEnd = editEnd.addingTimeInterval(delta)
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
