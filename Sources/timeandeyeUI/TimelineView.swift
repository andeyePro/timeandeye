import SwiftUI
import timeandeyeCore
import timeandeyeMac

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
/// - Shift-drag (or shift-click, then shift-click again to extend) selects a
///   time RANGE instead — not bound to any slice's edges — and a small bar
///   offers Allocate…/Unknown/Cancel; a slice only partly inside the range
///   is split at its edge (`SpanAllocation.plan` in Core).
/// A slice: rounded rect, but the live slice gets a zig-zag right edge to
/// signal "ongoing" while keeping the task's full colour.
/// Reference holder so the scroll-wheel NSEvent monitor (captured once at
/// onAppear) can read a flag that SwiftUI @State updates live.
final class ScrollGate { var overDetail = false }

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

/// Diagonal 45° hatch lines across the whole rect. Clipped by the caller to
/// the provisional sub-range (a `BandRect`) AND the live `SliceShape`, so the
/// lines read as "provisional, not yet committed" only over the undecided
/// tail, and stop at the torn live edge. Static (no marching-ants animation)
/// so it costs nothing under prefers-reduced-motion.
struct Hatch: Shape {
    var spacing: CGFloat = 5
    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x = rect.minX - rect.height
        while x <= rect.maxX {
            p.move(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return p
    }
}

/// A vertical band [xStart, xEnd] in the shape's own coordinate space, used to
/// clip the full-slice hatch down to just the undecided sub-range.
struct BandRect: Shape {
    var xStart: CGFloat
    var xEnd: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: xStart, y: rect.minY, width: max(xEnd - xStart, 0), height: rect.height))
    }
}

struct TimelineView: View {
    @ObservedObject var controller: AppController
    /// In-window navigation to the pie view (and the second-window escape hatch).
    let nav: TimeNav
    /// Continuous timeline: the viewport is an absolute [viewStart, +viewSpan]
    /// window that pans/zooms freely across midnight. No per-day bucketing —
    /// the only bounds are a history floor and the live edge (now).
    @State private var viewStart: Date = Calendar.current.startOfDay(for: Date())
    @State private var viewSpan: TimeInterval = 86_400
    @State private var selection = Set<UUID>()
    @State private var editing: Session?
    @State private var isNewEditing = false
    @State private var editStart = Date()
    @State private var editEnd = Date()
    @State private var editComment = ""
    /// Live slice only: the stored comments of the journalled rows the
    /// displayed block folds — shown read-only beside the editable in-flight
    /// note (they belong to journalled slices, not to `manualNote`).
    @State private var editStoredComment = ""
    @State private var editTask: TaskRef?
    @State private var conflicts: [Session] = []
    @State private var filter = ""
    @State private var pinchBaseSpan: TimeInterval?
    /// The date under the pinch start + its screen fraction, held fixed for the
    /// whole gesture so a pinch zooms around the cursor, not the centre.
    @State private var pinchAnchor: (date: Date, frac: Double)?
    @State private var drawDraft: (start: Date, end: Date)?
    @State private var edgeOrigin: (start: Date, end: Date)?
    /// Committed span selection (shift-drag or shift-click-extend) — a TIME
    /// RANGE, not bound to any slice's edges, driving the Allocate bar.
    @State private var rangeSelection: (start: Date, end: Date)?
    /// The fixed end of a shift-extend, seeded by the last plain click (or
    /// the end of the last shift-drag). A further shift-click extends from
    /// here, matching a text selection's fixed anchor.
    @State private var rangeAnchor: Date?
    /// Live band while a shift-drag is in flight (mirrors `drawDraft`'s role
    /// for the plain-drag draw gesture).
    @State private var rangeDraft: (start: Date, end: Date)?
    /// Which mode THIS drag is in, latched on its first move so a shift key
    /// released mid-drag doesn't flip it — nil between gestures.
    @State private var dragIsRange: Bool?
    @State private var showAllocatePicker = false
    @State private var barWidth: CGFloat = 900
    @State private var selectedSpanIdx = Set<Int>()
    /// Anchor for Finder-style shift-range selection in the window strip.
    @State private var spanAnchor: Int?
    /// Anchor for the same in the slice bar (by slice id).
    @State private var sliceAnchor: UUID?
    /// Keyboard focus cursor for the slice bar (by slice id). Distinct from
    /// `sliceAnchor`: the anchor pins a shift-range, this is the moving end that
    /// arrows walk. Kept in lockstep with the anchor on a plain click.
    @State private var sliceFocus: UUID?
    /// Whether the slice bar holds key focus, so the arrow / Return key presses
    /// route here (the editor's text fields take their own focus when active).
    @FocusState private var barFocused: Bool
    /// Last pointer x over the bar (view coords), so zoom keeps the time under
    /// the cursor fixed instead of fixing the viewport centre.
    @State private var cursorX: CGFloat?
    @State private var stripPxPerSec: CGFloat = 2
    @State private var stripPinchBase: CGFloat?
    @State private var scrollMonitor: Any?
    /// The window actually hosting THIS view — the scroll-pan gate's
    /// identity (two timeline windows share the "timeline" identifier).
    @State private var hostWindow: NSWindow?
    /// Live flag (a reference so the scroll-wheel monitor reads it after install)
    /// telling the main-timeline pan to stand down while the cursor is over the
    /// window detail section — otherwise scrolling the strip pans both.
    @State private var scrollGate = ScrollGate()

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    /// A 1 Hz tick that advances ONLY the live slice's trailing edge (and its
    /// provisional hatch), so the ongoing block tracks the clock like the menu
    /// bar instead of jumping every 30 s. It never re-queries the journal — the
    /// handler just moves `liveNow`, and `sessions` remaps the cached slices in
    /// memory. When nothing is tracking the handler early-returns without
    /// touching state, so a stopped timeline does no per-second redraw.
    private let liveTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    /// "Now" for the live slice's trailing edge, moved by `liveTick`. Held as
    /// state (not a fresh `Date()` per body eval) so a redraw only happens when
    /// the tick actually advances it.
    @State private var liveNow = Date()

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
            if let range = rangeSelection, editing == nil {
                allocateBar(range)
            }
            if let session = editing {
                editor(session)
                detailStrip(session)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        // Keyboard parity: delete/backspace removes the selected slice(s), or
        // the slice open in the editor. Fires only when no text field is
        // editing (an editing field consumes the key itself).
        .onDeleteCommand { Task { await deleteSelection() } }
        .coordinateSpace(name: "timeline")
        // Don't rebuild while the editor is open: the 30 s tick recomputes the
        // bar, which re-renders the editor subtree and steals focus from the
        // h:mm field you just clicked — the intermittent "it didn't go blue, so
        // I couldn't tell I could type" bug. Pause the tick during an edit.
        .onReceive(timer) { _ in if editing == nil { reloadSessions(); reloadTodayPreview() } }
        // Live-edge tick: advance the ongoing slice's edge ~1 Hz (never reloads
        // the journal — only `liveNow` moves). Paused while ANY editor is open:
        // the per-second body re-eval is almost certainly harmless (a stable
        // slice identity is preserved and mouse-move already re-renders during
        // edits), but focus-steal from a periodic re-render is a bug this view
        // has had before, so we don't gamble on it — the live edge simply
        // catches up the instant the editor closes. No-op while stopped.
        .onReceive(liveTick) { now in
            guard editing == nil, case .tracking = controller.trackerState else { return }
            liveNow = now
        }
        // Task flips (e.g. "Change to X") land off the SAME @Published tracker
        // state the menu bar reads, so the two agree instantly instead of
        // lagging up to 30 s. A full reload — only when no editor is open —
        // re-folds the live slice into any now-contiguous same-task neighbour;
        // `sessions` mirrors the task meanwhile so an in-edit flip still shows.
        .onChange(of: controller.trackerState) { _, _ in
            liveNow = Date()
            if editing == nil { reloadSessions() }
        }
        // Cache invalidation: viewport moved out of the loaded range, or the
        // journal mutated (revision bumps on every edit, even same-duration).
        .onChange(of: viewStart) { _, _ in reloadIfNeeded() }
        .onChange(of: viewSpan) { _, _ in reloadIfNeeded() }
        .onChange(of: controller.journalRevision) { _, _ in reloadSessions(); reloadTodayPreview() }
        .onChange(of: controller.pendingTimelineFocus) { _, _ in focusOnPendingSlice() }
        .onAppear {
            controller.noteTimeViewOpened(.timeline)
            liveNow = Date()
            zoomToLatestBlock()
            reloadSessions()
            reloadTodayPreview()
            focusOnPendingSlice()
            installScrollPan()
            barFocused = true
        }
        .onDisappear {
            if let monitor = scrollMonitor { NSEvent.removeMonitor(monitor) }
            scrollMonitor = nil
        }
        // Resolve the ACTUAL window hosting this view — the scroll-pan gate
        // compares window instances, because two open timeline windows share
        // the "timeline" identifier and both panned on either's scroll.
        .background(HostWindowAccessor { hostWindow = $0 })
    }

    // MARK: - Data

    /// Cached journal fetch for the (padded) visible window. Reading the journal
    /// is a SQLite query + JSON decode; `sessions` is read many times per body
    /// eval AND inside every gesture .onChanged (and a mouse-move retriggers
    /// body via cursorX), so a computed re-fetch ran SQLite per frame. The cache
    /// is refreshed only when the viewport leaves the loaded range, on the timer
    /// tick, or when the journal actually mutates (controller.journalRevision).
    @State private var cachedSessions: [Session] = []
    @State private var cachedRange: ClosedRange<Date>?
    /// Cached today's-breakdown for the header mini-pie (a journal query — don't
    /// recompute per body eval).
    @State private var todayNodes: [TimeAggregator.Node] = []

    private var sessions: [Session] {
        var list = cachedSessions
        // The live slice grows in real time: advance its trailing edge to the
        // current tick and mirror the just-changed task straight off the
        // @Published tracker state, so a "Change to X" flips here the instant it
        // flips in the menu bar — with no wait for the next journal reload. Both
        // are pure display remaps of the cache; the journal is never touched.
        if let i = list.firstIndex(where: { $0.id == AppController.liveSessionID }) {
            list[i].end = max(liveNow, list[i].start.addingTimeInterval(1))
            if case .tracking(.task(let ref), let cert) = controller.trackerState {
                list[i].task = ref
                list[i].certainty = cert
            }
        }
        // While editing an existing slice, the bar reflects the editor's live
        // values — applied to the CACHE in memory (cheap), so a handle drag
        // moves the slice and the numbers below in lock-step with no re-query.
        if let editing, !isNewEditing,
           let i = list.firstIndex(where: { $0.id == editing.id }) {
            list[i].start = editStart
            list[i].end = editEnd
        }
        return list
    }

    /// Fetch the visible window padded a full span each side, so panning within
    /// the buffer needs no re-query. Range-based, so it spans midnight.
    private func reloadSessions() {
        let from = viewStart.addingTimeInterval(-viewSpan)
        let to = viewEnd.addingTimeInterval(viewSpan)
        cachedSessions = controller.timelineSessions(from: from, to: to)
        cachedRange = from...to
    }

    /// Re-fetch only when the viewport has moved outside the loaded range (a
    /// cheap range check on the frames where it hasn't).
    private func reloadIfNeeded() {
        if let r = cachedRange, r.lowerBound <= viewStart, viewEnd <= r.upperBound { return }
        reloadSessions()
    }

    private var viewEnd: Date { viewStart.addingTimeInterval(viewSpan) }

    /// You can't track the future: the viewport's right bound is now.
    private var liveEdge: Date { Date() }

    /// How far back the timeline can be panned. Generous — covers any
    /// cross-midnight / recent-week navigation — without scanning all history.
    private var historyFloor: Date { Date().addingTimeInterval(-90 * 86_400) }

    /// Widest zoom-out: a week on screen at once. Tightest is 5 min (below).
    private let maxViewSpan: TimeInterval = 7 * 86_400

    private var snapTolerance: TimeInterval { viewSpan / Double(barWidth) * 8 }

    // MARK: - Viewport

    private func zoomToLatestBlock() {
        // Look across the last couple of days so a block that began before
        // midnight is found whole.
        let recent = controller.timelineSessions(from: liveEdge.addingTimeInterval(-2 * 86_400),
                                                  to: liveEdge)
        guard let block = TimelineMath.latestBlock(in: recent) else {
            viewStart = Calendar.current.startOfDay(for: Date())
            viewSpan = 86_400
            clampViewport()
            return
        }
        let pad = max(block.end.timeIntervalSince(block.start) * 0.1, 300)
        viewStart = block.start.addingTimeInterval(-pad)
        viewSpan = block.end.timeIntervalSince(viewStart) + pad
        clampViewport()
    }

    /// Pan by whole days (the ‹ › buttons) — the continuous-timeline analogue
    /// of the old day-stepper, but it just slides the same-width window.
    private func pan(days: Int) {
        viewStart = viewStart.addingTimeInterval(Double(days) * 86_400)
        editing = nil
        selection = []
        sliceFocus = nil
        sliceAnchor = nil
        selectedSpanIdx = []
        clearRangeSelection()
        clampViewport()
    }

    private func showToday() {
        viewStart = Calendar.current.startOfDay(for: Date())
        viewSpan = 86_400
        clampViewport()
    }

    private func clampViewport() {
        viewSpan = min(max(viewSpan, 300), maxViewSpan)
        // Free across midnight; the only bounds are the history floor and the
        // live edge (now) — never drift into empty future time.
        let maxStart = max(historyFloor, liveEdge.addingTimeInterval(-viewSpan))
        viewStart = max(historyFloor, min(viewStart, maxStart))
    }

    /// Zoom keeping `anchor` (a date) pinned at the same screen position — so
    /// zooming homes in on what's under the cursor, not the viewport centre.
    private func zoomAround(_ anchor: Date, factor: TimeInterval) {
        let frac = viewSpan > 0 ? anchor.timeIntervalSince(viewStart) / viewSpan : 0.5
        viewSpan *= factor
        viewStart = anchor.addingTimeInterval(-frac * viewSpan)
        clampViewport()
    }

    /// The anchor a button/pinch zoom should hold fixed: the time under the
    /// cursor when the pointer is over the bar, else the viewport centre.
    private func zoomAnchor(width: CGFloat) -> Date {
        if let x = cursorX { return dateFor(x, width: width) }
        return viewStart.addingTimeInterval(viewSpan / 2)
    }

    private func zoom(by factor: TimeInterval) {
        zoomAround(zoomAnchor(width: barWidth), factor: factor)
    }

    /// Two-finger scroll pans the bar (drag is reserved for drawing).
    private func installScrollPan() {
        // Idempotent: a re-entrant onAppear must not stack a second process-
        // global monitor (that double-panned, app-wide). onDisappear nils it.
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Gate on THIS view's window INSTANCE: two open timeline windows
            // share the "timeline" identifier, so an identifier gate panned
            // both on either's scroll (the known cross-pan TODO). The
            // identifier check remains only as a fallback for the instant
            // before the accessor resolves.
            if let host = hostWindow {
                guard NSApp.keyWindow === host else { return event }
            } else {
                let w = NSApp.keyWindow
                guard w?.identifier?.rawValue == "timeline"
                        || w?.title.contains("Timeline") == true else { return event }
            }
            // Over the window detail section the inner ScrollViews handle their
            // own scrolling — don't ALSO pan the main bar (that moved both).
            if scrollGate.overDetail { return event }
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
            Button { pan(days: -1) } label: { Image(systemName: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back a day (⌘[)")
            Text(viewportLabel)
                .font(.headline)
                .frame(width: 168)
            Button { pan(days: 1) } label: { Image(systemName: "chevron.right") }
                .disabled(viewEnd >= liveEdge)
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward a day (⌘])")
            Spacer()
            Button { zoom(by: 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-", modifiers: .command)
                .help("Zoom out (⌘−)")
            Button { zoom(by: 1 / 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=", modifiers: .command)
                .help("Zoom in (⌘+)")
            Button("Block") { zoomToLatestBlock() }
                .keyboardShortcut("b", modifiers: .command)
                .help("Zoom to the latest run of work (⌘B)")
            Button("Today") { showToday() }
                .keyboardShortcut("0", modifiers: .command)
                .help("Today, midnight to now (⌘0)")
            Text(totalText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            // Cross-preview / navigation: today's pie + total. Click flips this
            // window to the pie; ⌃-click / right-click opens it in a 2nd window.
            Button {
                if NSEvent.modifierFlags.contains(.control) { nav.openSecond(.spent) }
                else { nav.switchTo(.spent) }
            } label: {
                MiniPie(nodes: todayNodes, colour: { Color(nsColor: controller.colour(for: $0)) })
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("\\", modifiers: .command)
            .help("Today's breakdown — click for the pie, ⌘\\ to flip (⌃/right-click: 2nd window)")
            .contextMenu { Button("Open the pie in a 2nd window") { nav.openSecond(.spent) } }
            Text("today \(MenuTitle.text(elapsed: todayTotalSeconds, certainty: nil, showPercent: false))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private var todayTotalSeconds: TimeInterval { todayNodes.reduce(0) { $0 + $1.seconds } }
    private func reloadTodayPreview() { todayNodes = controller.todaySpentNodes() }

    /// Frame and open the slice the pie view asked us to focus (clicking a slice
    /// in its mini-timeline), then clear the request.
    private func focusOnPendingSlice() {
        guard let s = controller.pendingTimelineFocus else { return }
        controller.pendingTimelineFocus = nil
        let dur = max(s.end.timeIntervalSince(s.start), 60)
        let pad = max(dur * 0.5, 300)
        viewStart = s.start.addingTimeInterval(-pad)
        viewSpan = dur + 2 * pad
        clampViewport()
        reloadSessions()
        openEditor(for: s, isNew: false)
    }

    /// The visible date span: one date when the window sits inside a day, else
    /// a "Jun 24 – 25" range across the midnight it crosses.
    private var viewportLabel: String {
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: viewStart)
        let endDay = cal.startOfDay(for: viewEnd)
        if startDay == endDay {
            return viewStart.formatted(date: .abbreviated, time: .omitted)
        }
        let a = viewStart.formatted(date: .abbreviated, time: .omitted)
        let b = viewEnd.formatted(date: .abbreviated, time: .omitted)
        return "\(a) – \(b)"
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
            liveHatch(width: width)
            unknownHatch(width: width)
            rangeSelectionBand(width: width)
        }
        .frame(height: 96)
        .clipped()
        .contentShape(Rectangle())
        // Make the bar a key-focus target so arrows / Return drive it. The
        // editor's text fields take their own focus when active, so they keep
        // their keystrokes; clicking the bar re-takes focus (below).
        .focusable()
        .focusEffectDisabled()   // keep key focus for arrows, but no blue focus ring round the whole bar
        .focused($barFocused)
        // Keyboard navigation over slices. Left/right move the selection to the
        // previous/next slice (by start time); ⇧ extends a contiguous range;
        // Return opens the editor on the focused slice. Esc clears an active
        // span selection when there's no editor to cancel instead (that has
        // its own cancelAction shortcut). Everything else is ignored so
        // delete/backspace still reach .onDeleteCommand, and typing elsewhere
        // is untouched.
        .onKeyPress { press in
            let extend = press.modifiers.contains(.shift)
            switch press.key {
            case .leftArrow:  moveSelection(forward: false, extend: extend); return .handled
            case .rightArrow: moveSelection(forward: true,  extend: extend); return .handled
            case .return:     openFocusedEditor(); return .handled
            case .escape:
                guard rangeSelection != nil || rangeAnchor != nil || rangeDraft != nil else { return .ignored }
                clearRangeSelection()
                return .handled
            default:          return .ignored
            }
        }
        // Over the bar, scroll pans it — clear the detail gate so panning
        // resumes even if the editor was dismissed while hovering the strip.
        .onHover { if $0 { scrollGate.overDetail = false } }
        // Track the pointer so zoom (± buttons and pinch) homes in on the time
        // under the cursor.
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let loc): cursorX = loc.x
            case .ended: cursorX = nil
            }
        }
        .gesture(drawGesture(width: width))
        .onTapGesture(coordinateSpace: .local) { location in gapClick(at: location, width: width) }
        .gesture(MagnificationGesture()
            .onChanged { value in
                if pinchBaseSpan == nil {
                    pinchBaseSpan = viewSpan
                    let ax = cursorX ?? width / 2
                    pinchAnchor = (dateFor(ax, width: width), Double(ax / width))
                }
                viewSpan = (pinchBaseSpan ?? viewSpan) / TimeInterval(value)
                if let a = pinchAnchor {
                    viewStart = a.date.addingTimeInterval(-a.frac * viewSpan)
                }
                clampViewport()
            }
            .onEnded { _ in pinchBaseSpan = nil; pinchAnchor = nil })
    }

    /// Drag on empty space draws a new slice, snapping to neighbours — UNLESS
    /// shift is held, which latches this drag into span-selection mode
    /// instead (a plain time RANGE, not snapped to any slice's edges). The
    /// mode is decided on the drag's first move so releasing shift mid-drag
    /// doesn't flip it underneath you.
    private func drawGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragIsRange == nil { dragIsRange = NSEvent.modifierFlags.contains(.shift) }
                let a = dateFor(min(value.startLocation.x, value.location.x), width: width)
                let b = dateFor(max(value.startLocation.x, value.location.x), width: width)
                if dragIsRange == true {
                    rangeDraft = (a, b)
                } else {
                    drawDraft = (
                        TimelineMath.snap(a, to: sessions, tolerance: snapTolerance),
                        TimelineMath.snap(b, to: sessions, tolerance: snapTolerance)
                    )
                }
            }
            .onEnded { _ in
                defer { dragIsRange = nil }
                if dragIsRange == true {
                    guard let draft = rangeDraft else { return }
                    rangeDraft = nil
                    guard draft.end.timeIntervalSince(draft.start) >= 60 else { return }
                    editing = nil
                    selection = []
                    rangeSelection = draft
                    rangeAnchor = draft.end   // further shift-clicks extend from the drag's far edge
                    return
                }
                guard let draft = drawDraft else { return }
                drawDraft = nil
                guard draft.end.timeIntervalSince(draft.start) >= 60 else { return }
                openEditor(for: makeDraft(start: draft.start, end: draft.end), isNew: true)
            }
    }

    /// Plain click in a gap proposes a slice filling that gap. A single click
    /// always works: any open editor / selection is cleared first, then if the
    /// click landed in a real gap a fill is proposed in the SAME click (the old
    /// two-step "first click just dismisses" made gaps feel un-fillable).
    /// Shift-click instead extends/starts the span selection from the last
    /// plain click (or drag), same as a shift-click on a slice.
    private func gapClick(at location: CGPoint, width: CGFloat) {
        let point = dateFor(location.x, width: width)
        if NSEvent.modifierFlags.contains(.shift) {
            extendRangeSelection(to: point)
            return
        }
        editing = nil
        selection = []
        sliceFocus = nil
        sliceAnchor = nil
        selectedSpanIdx = []
        rangeAnchor = point
        rangeSelection = nil
        showAllocatePicker = false
        guard point <= liveEdge,
              let gap = TimelineMath.gap(at: point, in: sessions,
                                         within: historyFloor...liveEdge) else { return }
        // Cap a cavernous gap at 2h around the click, snapped to neighbours.
        let start = max(gap.start, point.addingTimeInterval(-3600))
        let end = min(gap.end, point.addingTimeInterval(3600))
        openEditor(for: makeDraft(start: TimelineMath.snap(start, to: sessions, tolerance: snapTolerance),
                                  end: TimelineMath.snap(end, to: sessions, tolerance: snapTolerance)),
                   isNew: true)
    }

    private func makeDraft(start: Date, end: Date) -> Session {
        let likely = controller.fullPickList().first?.ref ?? .op(0)
        return Session(task: likely, start: start, end: end, certainty: 1.0,
                       comment: nil)
    }

    private func gridLines(width: CGFloat) -> some View {
        // Step scales with the zoom so the tick count stays bounded even at a
        // multi-day span.
        let step: TimeInterval =
            viewSpan > 3 * 86_400 ? 86_400 :
            viewSpan > 86_400 ? 6 * 3600 :
            viewSpan > 6 * 3600 ? 3600 :
            viewSpan > 3600 ? 900 : 300
        // Anchor ticks to LOCAL midnight (not the absolute epoch) so a day
        // boundary lands on 00:00, then step forward. Midnight ticks carry the
        // date and a darker line, so crossing midnight reads clearly.
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: viewStart)
        let firstK = (viewStart.timeIntervalSince(anchor) / step).rounded(.down)
        let firstTick = anchor.addingTimeInterval(firstK * step)
        let count = Int(viewSpan / step) + 2
        return ForEach(0..<count, id: \.self) { i in
            let tick = firstTick.addingTimeInterval(TimeInterval(i) * step)
            let isMidnight = cal.component(.hour, from: tick) == 0
                && cal.component(.minute, from: tick) == 0
            VStack(alignment: .leading, spacing: 0) {
                Text(isMidnight ? tick.formatted(.dateTime.month(.abbreviated).day())
                                : tick.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 9, weight: isMidnight ? .semibold : .regular))
                    .foregroundStyle(isMidnight ? Color.primary.opacity(0.7) : .secondary)
                    .fixedSize()
                Rectangle()
                    .fill(Color.secondary.opacity(isMidnight ? 0.45 : 0.2))
                    .frame(width: isMidnight ? 1.5 : 1, height: 78)
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
        let comment = session.comment ?? ""
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
            // At-a-glance "this slice has a comment": a tiny bubble in the
            // slice's own label colour. The live block's comment includes its
            // folded rows' stored comments + the in-flight note, and a merged
            // slice keeps its joined comment — so the dot never disappears
            // just because tracking continued or slices fused. Skipped on
            // slivers where it would smear; hover/editor still show the text.
            .overlay(alignment: .topTrailing) {
                if !comment.isEmpty, w > 16 {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(labelColour(for: session.task).opacity(0.65))
                        .padding(.top, 2)
                        .padding(.trailing, isLive ? 8 : 3)   // clear the torn edge
                        .allowsHitTesting(false)
                }
            }
            .overlay(shape.stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            .frame(width: w, height: 44)
            // Handles overlaid AFTER the frame so the HStack spans the slice
            // width (previously sized to nothing → handles only landed on the
            // last-drawn slice).
            .overlay { edgeHandles(session, sliceWidth: w) }
            .position(x: x0 + w / 2, y: 56)
            // The hover tooltip carries the comment too, so reading one needs
            // no click even on a sliver too thin for the bubble.
            .help("\(controller.name(of: .task(session.task)))  \(slot(session))"
                  + (comment.isEmpty ? "" : "\n\(comment)"))
            // `.local` here is the SLICE's own frame (0..<w); add its x0 to get
            // back to a bar-relative x, so a shift-click's date is exactly
            // where you clicked rather than snapping to the slice's edge.
            .onTapGesture(coordinateSpace: .local) { location in
                selectSlice(session, isLive: isLive, atX: x0 + location.x, width: width)
            }
    }

    /// Hatch the "undecided" tail of the live slice: after a confident switch
    /// the display follows the new task instantly, but that run only commits
    /// once it has held past the grace floor — until then it can revert to the
    /// prior task. The cross-hatch marks exactly that provisional sub-range,
    /// [start-of-provisional-run, min(now, graceEnds)], and solidifies (the
    /// hatch clears) the moment the switch commits. A settled task, a reverted
    /// excursion, or a fresh start (manual pick / idle-resume) has no pending
    /// switch, so nothing is hatched — the smallest honest mapping onto the
    /// tracker's real provisional state, inventing no new segmentation.
    @ViewBuilder
    private func liveHatch(width: CGFloat) -> some View {
        if case .tracking(.task(let ref), _) = controller.trackerState,
           let g = controller.liveGraceRange,
           let live = sessions.first(where: { $0.id == AppController.liveSessionID }) {
            let x0 = xFor(live.start, width: width)
            let x1 = xFor(live.end, width: width)
            let w = max(x1 - x0, 3)
            // Band in the slice's own coords: from the provisional-run start to
            // the commit deadline, never past the drawn live edge (`live.end`
            // is already `liveNow`, so an un-elapsed grace hatches the whole
            // tail-so-far and grows with the clock).
            let a = xFor(max(live.start, g.since), width: width) - x0
            let b = Swift.min(x1, xFor(g.graceEnds, width: width)) - x0
            if b > a + 0.5 {
                Hatch(spacing: 5)
                    .stroke(labelColour(for: ref).opacity(0.5), lineWidth: 1)
                    .frame(width: w, height: 44)
                    .clipShape(BandRect(xStart: a, xEnd: b))
                    .clipShape(SliceShape(zigzag: true))
                    .position(x: x0 + w / 2, y: 56)
                    // Decorative: clicks pass through to the live slice beneath.
                    .allowsHitTesting(false)
            }
        }
    }

    /// Unknown task category §5: every Unknown-assigned slice gets a static
    /// cross-hatch over its whole width, on top of the fixed-grey fill
    /// `colour(for:)` already gives it — "swept, not decided", legible at a
    /// glance and distinct from `liveHatch`'s provisional TAIL (which marks
    /// only the undecided edge of an otherwise-normal live slice).
    private func unknownHatch(width: CGFloat) -> some View {
        ForEach(sessions.filter { $0.task == WorkTask.unknown.ref }) { session in
            let x0 = xFor(session.start, width: width)
            let x1 = xFor(session.end, width: width)
            let w = max(x1 - x0, 3)
            Hatch(spacing: 5)
                .stroke(labelColour(for: session.task).opacity(0.5), lineWidth: 1)
                .frame(width: w, height: 44)
                .clipShape(SliceShape(zigzag: session.id == AppController.liveSessionID))
                .position(x: x0 + w / 2, y: 56)
                // Decorative: clicks pass through to the slice beneath.
                .allowsHitTesting(false)
        }
    }

    /// The span-select highlight: a translucent band over whatever's live
    /// right now — the in-flight shift-drag, else the committed selection —
    /// with its time range labelled above. Decorative only (clicks/shift-clicks
    /// on the slices or gaps beneath still drive the selection), so it never
    /// blocks the gestures that grow or replace it.
    @ViewBuilder
    private func rangeSelectionBand(width: CGFloat) -> some View {
        if let range = rangeDraft ?? rangeSelection {
            let x0 = xFor(range.start, width: width)
            let x1 = xFor(range.end, width: width)
            let w = max(x1 - x0, 2)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.accentColor.opacity(0.6), lineWidth: 1))
                .frame(width: w, height: 78)
                .position(x: x0 + w / 2, y: 48)
                .overlay(alignment: .top) {
                    Text("\(range.start.formatted(date: .omitted, time: .shortened)) – \(range.end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
                        .position(x: x0 + w / 2, y: 6)
                }
                .allowsHitTesting(false)
        }
    }

    /// Finder-style slice selection, matching the window strip: ⌘-click toggles
    /// one into the multi-select, ⇧⌘ extends a contiguous ID range (by start
    /// time) from the anchor onto that multi-select, and a plain click opens
    /// the editor (and sets the anchor for a later ⇧⌘-click). The live slice
    /// can't be batch-selected. Bare ⇧ (no ⌘) is span-select instead — see
    /// `extendRangeSelection` — so it never reaches the ID-range branch below.
    private func selectSlice(_ session: Session, isLive: Bool, atX x: CGFloat, width: CGFloat) {
        let flags = NSEvent.modifierFlags
        // Bare shift (no ⌘) is the span-select modifier — same as a
        // shift-click on empty space — so it bypasses the ID-based
        // multi-select/editor entirely.
        if flags.contains(.shift), !flags.contains(.command) {
            extendRangeSelection(to: dateFor(x, width: width))
            return
        }
        let ids = sessions.filter { $0.id != AppController.liveSessionID }
            .sorted { $0.start < $1.start }.map(\.id)
        if flags.contains(.shift), let anchor = sliceAnchor,
           let a = ids.firstIndex(of: anchor), let b = ids.firstIndex(of: session.id) {
            let range = Set(ids[min(a, b)...max(a, b)])
            selection = flags.contains(.command) ? selection.union(range) : range
            editing = nil
        } else if flags.contains(.command) {
            guard !isLive else { return }
            if selection.contains(session.id) { selection.remove(session.id) }
            else { selection.insert(session.id) }
            sliceAnchor = session.id
            editing = nil
        } else {
            selection = []
            sliceAnchor = isLive ? nil : session.id
            rangeAnchor = dateFor(x, width: width)
            rangeSelection = nil
            showAllocatePicker = false
            openEditor(for: session, isNew: false)
        }
        // Keep the keyboard cursor in step with the mouse and take key focus, so
        // an arrow press right after a click continues from the clicked slice.
        sliceFocus = isLive ? nil : session.id
        barFocused = true
    }

    /// Shift-click(-drag) span selection: extend from the fixed anchor (the
    /// last plain click, or the far edge of the last shift-drag) to `date`,
    /// same shape as a shift-click's Finder-style range-extend. With no prior
    /// anchor (shift-click out of the blue, nothing clicked yet this
    /// session), it just seeds one — a real, visible range needs two points.
    private func extendRangeSelection(to date: Date) {
        guard let anchor = rangeAnchor else {
            rangeAnchor = date
            return
        }
        rangeSelection = (min(anchor, date), max(anchor, date))
        editing = nil
        selection = []
    }

    /// Esc, clicking empty space, or completing the allocate/cancel action
    /// all drop the span selection the same way.
    private func clearRangeSelection() {
        dismissRangeBand()
        rangeAnchor = nil
    }

    /// Drop just the visible band/picker, leaving the click anchor alone —
    /// used where a plain click is ALSO about to (re-)seed a fresh anchor of
    /// its own (opening the editor), so the two writes don't race each other.
    private func dismissRangeBand() {
        rangeSelection = nil
        rangeDraft = nil
        showAllocatePicker = false
    }

    /// Selectable slices in start order (live excluded), matching selectSlice.
    private func selectableIDs() -> [UUID] {
        sessions.filter { $0.id != AppController.liveSessionID }
            .sorted { $0.start < $1.start }.map(\.id)
    }

    /// Arrow-key move: shift `selection` (and the focus cursor) to the
    /// previous/next slice, or extend a contiguous range when `extend`.
    private func moveSelection(forward: Bool, extend: Bool) {
        guard let nav = TimelineMath.keyboardMove(in: selectableIDs(),
                                                  anchor: sliceAnchor,
                                                  focus: sliceFocus,
                                                  forward: forward, extend: extend)
        else { return }
        sliceAnchor = nav.anchor
        sliceFocus = nav.focus
        selection = nav.selection
        editing = nil   // arrows are pure selection nav; Return opens the editor
    }

    /// Return opens the editor on the focused slice (falling back to a lone
    /// selection), resolving the id back to its Session.
    private func openFocusedEditor() {
        let id = sliceFocus ?? (selection.count == 1 ? selection.first : nil)
        guard let id, let session = sessions.first(where: { $0.id == id }) else { return }
        openEditor(for: session, isNew: false)
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
                Spacer()
                Button(role: .destructive) {
                    Task { await deleteSelection() }
                } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete the selected slice\(selection.count == 1 ? "" : "s") (⌫)")
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

    /// The span-select "Allocate" action: with a time range selected (drawn
    /// by a shift-drag or shift-click-extend, not bound to any slice's
    /// edges), point it at a task — or straight at Unknown, no picker
    /// needed. "Allocate…" opens the same filter+button task picker the
    /// reassign bar and editor use (`filteredTasks`/`searchTasks`).
    private func allocateBar(_ range: (start: Date, end: Date)) -> some View {
        let duration = range.end.timeIntervalSince(range.start)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(MenuTitle.text(elapsed: duration, certainty: nil, showPercent: false)) selected")
                    .font(.caption)
                Spacer()
                Button("Allocate…") { showAllocatePicker.toggle() }
                Button("Unknown") {
                    Task {
                        await controller.allocateSpan(from: range.start, to: range.end,
                                                      target: WorkTask.unknown.ref)
                    }
                    clearRangeSelection()
                }
                Button("Cancel") { clearRangeSelection() }
                    .keyboardShortcut(.cancelAction)   // Esc cancels, same as the editor
            }
            if showAllocatePicker {
                HStack {
                    TextField("type to filter tasks", text: $filter)
                        .textFieldStyle(.roundedBorder).font(.caption).frame(width: 180)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(filteredTasks(), id: \.ref) { task in
                                Button(task.subject) {
                                    Task {
                                        await controller.allocateSpan(from: range.start, to: range.end,
                                                                      target: task.ref)
                                    }
                                    clearRangeSelection()
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func filteredTasks() -> [WorkTask] {
        controller.searchTasks(filter)
    }

    /// Delete what's selected (one undo step), or the slice open in the editor.
    /// Never deletes the live slice — you stop the clock for that. Backed by the
    /// keyboard (delete/backspace) and the reassign bar's Delete button.
    private func deleteSelection() async {
        let live = AppController.liveSessionID
        let targets: [Session]
        if !selection.isEmpty {
            targets = sessions.filter { selection.contains($0.id) && $0.id != live }
        } else if let e = editing, !isNewEditing, e.id != live {
            targets = [e]
        } else {
            targets = []
        }
        guard !targets.isEmpty else { return }
        await controller.undoGroup("delete \(targets.count) slice\(targets.count == 1 ? "" : "s")") {
            for s in targets { await controller.deleteTimelineSession(s) }
        }
        selection = []
        editing = nil
    }

    /// The editor's task list always contains the slice's current task, even
    /// when the filter would exclude it — otherwise the Picker shows blank for
    /// the very task you clicked to edit. The Unknown sentinel is never in
    /// `taskCache` (it's excluded from every pick list on purpose), so an
    /// Unknown-assigned slice falls back to the constant directly — the
    /// Picker still shows "Unknown", and reassigning away from it works
    /// exactly like any other slice.
    private func editorTasks() -> [WorkTask] {
        var list = filteredTasks()
        if let t = editTask, !list.contains(where: { $0.ref == t }) {
            if let task = controller.taskCache.first(where: { $0.ref == t }) {
                list.insert(task, at: 0)
            } else if t == WorkTask.unknown.ref {
                list.insert(WorkTask.unknown, at: 0)
            }
        }
        return list
    }

    // MARK: - Editor

    private func openEditor(for session: Session, isNew: Bool) {
        editing = session
        isNewEditing = isNew
        editStart = session.start
        editEnd = session.end
        // The live slice's EDITABLE comment is the in-flight note; the stored
        // comments of the rows the displayed block folds show read-only beside
        // it, so nothing the block carries is hidden while tracking — and
        // saving still writes only the note (no duplication either way).
        if session.id == AppController.liveSessionID {
            editComment = controller.manualNote
            editStoredComment = controller.liveFoldedComment() ?? ""
        } else {
            editComment = session.comment ?? ""
            editStoredComment = ""
        }
        editTask = session.task
        conflicts = []
        selectedSpanIdx = []
        spanAnchor = nil
        // Drop the visible band/picker (mutually exclusive with the editor) —
        // but NOT the click anchor: a plain click that opens the editor still
        // seeds the point a LATER shift-click extends from, same as any other
        // plain click.
        dismissRangeBand()
        // Leftover filter text used to hide the clicked slice's own task from
        // the picker (it lists only matches), so the editor opened on a blank
        // task. Clear it on open; the picker also force-includes the current
        // task below as a belt-and-braces guard.
        filter = ""
    }

    /// A stable local-midnight epoch the Duration field encodes a length
    /// against (the picker shows h:mm, so a duration is rendered as "midnight +
    /// duration"). Keyed to the edited slice's day so get/set agree.
    private var durationEpoch: Date { Calendar.current.startOfDay(for: editStart) }

    private var durationBinding: Binding<Date> {
        Binding(
            get: { durationEpoch.addingTimeInterval(editEnd.timeIntervalSince(editStart)) },
            set: { newValue in
                applyDurationChange(max(newValue.timeIntervalSince(durationEpoch), 60))
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
                    .help("Close the editor without saving (esc)")
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
                if !editStoredComment.isEmpty {
                    // Comments already journalled under this live block — read-
                    // only here (they live on flushed slices); the field edits
                    // only the in-flight note that follows them.
                    Text(editStoredComment)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                        .help(editStoredComment)
                }
                TextField(editStoredComment.isEmpty ? "comment" : "add to comment",
                          text: $editComment)
                    .textFieldStyle(.roundedBorder).font(.caption)
                    .frame(minWidth: 140)
                    .onSubmit { commitEditor(session) }
            }
            if isLive, editEnd > Date().addingTimeInterval(60) {
                Text("End is in the future → keeps tracking, then stops then.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !conflicts.isEmpty { conflictProposal }
            HStack {
                if conflicts.isEmpty || isLive {
                    Button { commitEditor(session) } label: {
                        Label(isNewEditing ? "Create" : "Save", systemImage: "checkmark.circle")
                    }
                    .keyboardShortcut(.defaultAction)   // Enter saves
                    .help(isNewEditing ? "Create the slice (↵)" : "Save changes (↵)")
                } else {
                    // Overlap pending: two ways to resolve it. Enter (default) /
                    // rightmost snaps the boundary to a whole-window edge so each
                    // tracked window lands entirely in one task; Space / leftmost
                    // keeps the exact time you typed.
                    Button { resolveOverlap(session, snapWindows: false) } label: {
                        Label("Exact time", systemImage: "clock")
                    }
                    .keyboardShortcut(.space, modifiers: [])
                    .help("Keep the exact time you typed (space)")
                    Button { resolveOverlap(session, snapWindows: true) } label: {
                        Label("Snap to windows", systemImage: "rectangle.split.2x1")
                    }
                    .keyboardShortcut(.defaultAction)
                    .help("Move the boundary to the nearest tracked-window edge (↵)")
                }
                if !isNewEditing, !isLive {
                    Button {
                        Task { await controller.markSessionDoNotTrack(session) }
                        editing = nil
                    } label: { Label("Don't track", systemImage: "nosign") }
                        .help("Drop this from tracked time (keeps the window detail) and stop auto-tracking this surface — e.g. an away stretch you didn't work.")
                    Button(role: .destructive) {
                        Task { await controller.deleteTimelineSession(session) }
                        editing = nil
                    } label: { Label("Delete", systemImage: "trash") }
                        .keyboardShortcut(.delete, modifiers: .command)
                        .help("Delete this slice (⌘⌫)")
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
        // Dragging the live start back over OTHER tasks behaves like any edge
        // drag: warn once (listing what gets trimmed), absorb on the next Save.
        let liveConf = controller.liveStartConflicts(newStart: editStart)
        if !liveConf.isEmpty, conflicts.isEmpty {
            conflicts = liveConf
            return
        }
        let absorb = !conflicts.isEmpty
        let newStart = editStart
        controller.manualNote = editComment
        controller.scheduleStop(at: editEnd > Date().addingTimeInterval(60) ? editEnd : nil)
        Task { await controller.adjustLiveStart(to: newStart, absorbOtherTasks: absorb) }
        conflicts = []
        editing = nil
    }

    private var taskPicker: some View {
        HStack {
            TextField("filter tasks", text: $filter)
                .textFieldStyle(.roundedBorder).font(.caption).frame(width: 140)
            Picker("Task", selection: Binding(
                get: { editTask ?? .op(0) },
                set: { editTask = $0 })) {
                ForEach(editorTasks(), id: \.ref) { task in
                    Text(task.subject).tag(task.ref)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)
        }
    }

    /// Resolve a pending overlap. `snapWindows` (Enter / default) moves the
    /// edited boundaries to the nearest tracked-window edge first, so a window
    /// straddling the boundary goes wholly to one task rather than being split
    /// (and duplicated under both slices). `false` (Space) keeps the exact time
    /// the user typed. Either way the existing trim path then applies it.
    private func resolveOverlap(_ session: Session, snapWindows: Bool) {
        if snapWindows {
            editStart = snapToWindowEdge(editStart)
            editEnd = snapToWindowEdge(editEnd)
        }
        attemptSave(session)   // conflicts already set → applies with these times
    }

    /// Nearest tracked-window edge to `date` (within ±30 min), or `date` itself
    /// when there are no windows nearby.
    private func snapToWindowEdge(_ date: Date) -> Date {
        let edges = controller.windowBoundaries(from: date.addingTimeInterval(-1800),
                                                to: date.addingTimeInterval(1800))
        return edges.min { abs($0.timeIntervalSince(date)) < abs($1.timeIntervalSince(date)) } ?? date
    }

    private func attemptSave(_ session: Session) {
        let overlapping = sessions.filter {
            $0.id != session.id && $0.end > editStart && $0.start < editEnd
        }
        if overlapping.isEmpty || !conflicts.isEmpty {
            var edited = session
            edited.task = editTask ?? session.task
            edited.start = editStart
            // The 1-minute hand-edit minimum applies only when the TIMES were
            // actually edited: a comment-only save must never grow a
            // sub-minute tracked slice (Martin, 2026-07-09 — editing a 40s
            // slice's comment silently stretched it to exactly a minute, and
            // the growth even triggered a neighbour coalesce).
            let timesEdited = editStart != session.start || editEnd != session.end
            edited.end = timesEdited ? max(editEnd, editStart.addingTimeInterval(60)) : editEnd
            edited.comment = editComment.isEmpty ? nil : editComment
            let isNew = isNewEditing
            let liveOverlap = overlapping.first { $0.id == AppController.liveSessionID }
            Task {
                await controller.undoGroup("\(isNew ? "create" : "edit") \(controller.name(of: .task(edited.task)))") {
                    if let live = liveOverlap, edited.end > live.start, edited.end < Date() {
                        // The live clock cannot overlap recorded history: its
                        // start moves to the edited slice's end.
                        await controller.adjustLiveStart(to: edited.end)
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
                    // Same-task slices now butting up are fused (no data
                    // lost) — INSIDE the group, so the fusion's compensating
                    // undo folds into this edit's own ⌘Z step and undoing
                    // the save restores the exact pre-edit rows, never a
                    // fused row.
                    await controller.coalesceAdjacent(around: edited.start)
                }
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
            Text("Snap to windows (↵) keeps each tracked window whole on one task; Exact time (space) uses the time you typed. Or adjust the times.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Detail strip + connectors

    private func detailStrip(_ session: Session) -> some View {
        let spans = controller.timelineSpans(for: session)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Windows in \(controller.name(of: .task(session.task))) · \(slot(session))  —  click one for why it tracked here")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !spans.isEmpty {
                    Spacer()
                    // [+all]: with a window selected, one click extends the
                    // selection to every window carrying the SAME recorded
                    // data (app + title + tab, NOT the times) — the "move all
                    // the Calendar windows at once" gesture. Appears only
                    // when it would actually add something.
                    let addable = identicalUnselected(in: spans)
                    if !addable.isEmpty {
                        Button {
                            selectedSpanIdx.formUnion(addable)
                        } label: {
                            Text("+ all")
                                .font(.caption.weight(.semibold))
                        }
                        .help("Select the \(addable.count) other window\(addable.count == 1 ? "" : "s") recorded with the same app + title")
                    }
                    Button { stripPxPerSec = max(stripPxPerSec / 1.6, 0.2) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .help("Zoom the window strip out")
                    Button { stripPxPerSec = min(stripPxPerSec * 1.6, 40) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("Zoom the window strip in")
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
                selectedSpanPanes(session, spans: spans)   // the data, one pane per window
                spanReassignBar(session, spans: spans)     // then the move dialogue
            }
        }
        // Scrolling anywhere in the detail section drives its own inner
        // ScrollViews, not the main bar (see the scroll-wheel monitor).
        .onHover { scrollGate.overDetail = $0 }
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
            .onTapGesture { selectSpan(index) }
    }

    /// A window's identity for [+all]: everything the window reported about
    /// ITSELF (app, title, tab URL) — never the times.
    private func spanIdentity(_ span: FocusSpan) -> String {
        "\(span.signal.app)|\(span.signal.windowTitle ?? "")|\(span.signal.tabURL ?? "")"
    }

    /// Unselected span indices whose identity matches ANY selected span —
    /// what [+all] would add. Empty when nothing is selected or every twin
    /// is already in the selection.
    private func identicalUnselected(in spans: [FocusSpan]) -> Set<Int> {
        let selectedKeys = Set(selectedSpanIdx.compactMap { i -> String? in
            i < spans.count ? spanIdentity(spans[i]) : nil
        })
        guard !selectedKeys.isEmpty else { return [] }
        return Set(spans.indices.filter { i in
            !selectedSpanIdx.contains(i) && selectedKeys.contains(spanIdentity(spans[i]))
        })
    }

    /// Finder-style selection: plain click selects just this one, ⌘-click
    /// toggles it, ⇧-click extends a contiguous range from the anchor, and
    /// ⇧⌘ adds that range to the existing selection.
    private func selectSpan(_ index: Int) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = spanAnchor {
            let range = Set(min(anchor, index)...max(anchor, index))
            selectedSpanIdx = flags.contains(.command)
                ? selectedSpanIdx.union(range)
                : range
        } else if flags.contains(.command) {
            if selectedSpanIdx.contains(index) { selectedSpanIdx.remove(index) }
            else { selectedSpanIdx.insert(index) }
            spanAnchor = index
        } else {
            selectedSpanIdx = [index]
            spanAnchor = index
        }
    }

    private func spanReassignBar(_ session: Session, spans: [FocusSpan]) -> some View {
        let isLive = session.id == AppController.liveSessionID
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
                    .help("Clear the window selection")
                Text("⌘A all").font(.caption2).foregroundStyle(.tertiary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(filteredTasks(), id: \.ref) { task in
                        Button {
                            // The live slice has no journal row yet — materialise
                            // it first (keeps tracking), then split the real slice
                            // it became. Finished slices split directly.
                            let target = isLive ? controller.commitLiveSlice() : session
                            if let target {
                                Task { await controller.splitAndReassign(target, ranges: ranges,
                                                                         to: task.ref) }
                            }
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
        // ⌘A selects every window in the slice once you've selected at least one
        // (this bar only shows while a selection exists, so the shortcut is live
        // only in window-selection mode).
        .background(
            Button("") { selectedSpanIdx = Set(spans.indices) }
                .keyboardShortcut("a", modifiers: .command)
                .opacity(0)
        )
    }

    /// One Evidence Card per selected window, in a horizontally scrollable set
    /// directly below the strip — so a second selection adds a card rather
    /// than replacing the one detail view (the full record stays visible for
    /// every window you pick). Replaces the monospaced why-pane (2026-07-03
    /// context-rules spec §5.3/§5.6): picking a task from a card's own
    /// "Wrong? file as" reassigns JUST that window's time range.
    @ViewBuilder
    private func selectedSpanPanes(_ session: Session, spans: [FocusSpan]) -> some View {
        let idxs = selectedSpanIdx.sorted().filter { $0 < spans.count }
        let isLive = session.id == AppController.liveSessionID
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(idxs, id: \.self) { i in
                    // Scrolls VERTICALLY so the full card is reachable even
                    // when it's taller than the fixed pane height.
                    ScrollView(.vertical, showsIndicators: true) {
                        EvidenceCardView(controller: controller, signal: spans[i].signal, host: .timeline,
                                        onPick: { task in
                            let target = isLive ? controller.commitLiveSlice() : session
                            if let target {
                                Task {
                                    await controller.splitAndReassign(
                                        target, ranges: [(spans[i].start, spans[i].end)], to: task.ref)
                                }
                            }
                        })
                    }
                    .frame(width: 372)
                }
            }
            .padding(.bottom, 2)
        }
        .frame(maxHeight: 320)
    }
}

/// Resolves the NSWindow hosting a SwiftUI view (async, once attached).
/// Used by the timeline's scroll-pan gate to compare WINDOW INSTANCES —
/// identifiers can't distinguish two open timeline windows.
private struct HostWindowAccessor: NSViewRepresentable {
    var onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in onResolve(view?.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in onResolve(view?.window) }
    }
}
