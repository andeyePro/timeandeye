import SwiftUI
import AmbitickCore
import AmbitickMac

struct PopoverView: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow
    @State private var filter = ""
    @State private var note = ""
    @State private var changeMode = false
    @FocusState private var noteFocused: Bool
    // Inline pin editor: blue = the chosen prefix, grey = the rest;
    // ← widens, → narrows, ↵ pins, esc abandons.
    @State private var pinning = false
    @State private var pinKind: PinScope.Kind = .url
    @State private var pinSegments: [String] = []
    @State private var pinCount = 1
    // The id of the pin being edited (re-opened from the badge), so committing
    // updates it in place instead of duplicating. nil = creating a new pin.
    @State private var pinEditingID: UUID?
    @FocusState private var pinFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if pinning { pinEditor }
            Divider()
            promptSection
            switchList
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
        // Make every label selectable so text (build version, errors, names)
        // can be copied out to share — screenshots are painful to send.
        .textSelection(.enabled)
        // Edit a LOCAL copy and push to the controller without republishing
        // (a @Published binding would rebuild the popover each keystroke and
        // steal focus). Re-sync when tracking state changes (the controller
        // clears the note on task-switch/stop).
        .onChange(of: note) { _, new in controller.manualNote = new }
        .onChange(of: controller.trackerState) { _, _ in note = controller.manualNote }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .tracking = controller.trackerState {
                // Clicking the running task name flips the list below into
                // "Change to" mode (relabel the current session).
                HStack(alignment: .firstTextBaseline) {
                    Button { changeMode.toggle() } label: {
                        Text(controller.currentTaskName()).font(.headline).lineLimit(2)
                    }
                    .buttonStyle(.plain)
                    .help("Click to change this task")
                    Spacer()
                    // One-click "that switch was wrong": fold the current slice
                    // back onto the previous task. Deliberately light (non-bold)
                    // so it reads as a quiet undo, not the primary action.
                    if let prev = controller.revertTargetTask() {
                        Button { controller.revertToLastTask() } label: {
                            Label(prev.subject, systemImage: "arrow.uturn.left")
                                .font(.callout).lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Back to \(prev.subject) — moves the current slice onto it")
                    }
                }
            } else {
                Text(controller.currentTaskName()).font(.headline).lineLimit(2)
            }
            if case .tracking(_, let certainty) = controller.trackerState {
                HStack {
                    if let pin = controller.currentPin {
                        // Pinned: drop the redundant "% certain" — the chip says
                        // it's locked. Pin icon + the scope's last segment (NOT
                        // the task name, which is already shown above) re-opens
                        // the editor; only the ✕ unpins.
                        Text(controller.menuText)
                            .font(.caption).foregroundStyle(.secondary)
                        Button { reopenPinning(pin.pin) } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "pin.fill")
                                Text(pin.pin.rule.shortLabel)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)   // white in dark mode, visible in light
                        .help("Pinned — click to adjust the scope")
                        Button { controller.unpinCurrentSurface() } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.caption2)
                        .help("Unpin")
                    } else {
                        Text("\(controller.menuText)  ·  \(Int((certainty * 100).rounded()))% certain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Pin the current window/site to the running task at 100%.
                    if controller.currentPin == nil, !pinning, controller.pinDraft() != nil {
                        Button { beginPinning() } label: {
                            Image(systemName: "pin")
                        }
                        .buttonStyle(.plain)
                        .help("Pin this window/site to the current task (always 100%)")
                    }
                    Button { changeMode.toggle() } label: {
                        Image(systemName: changeMode ? "arrow.left.arrow.right" : "pencil")
                    }
                    .buttonStyle(.plain)
                    .help(changeMode ? "Back to Switch to" : "Change the current task")
                    Button { controller.setAway(!controller.away) } label: {
                        Image(systemName: controller.away ? "figure.walk.motion" : "figure.walk")
                            .foregroundStyle(controller.away ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .help(controller.away
                          ? "I'm back — resume normal tracking"
                          : "I'm leaving my desk — keep tracking this task (⌘⇧L)")
                    Button { controller.userStopped() } label: {
                        Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop tracking")
                }
                if CommentRouting.noteInputVisible(
                    toTrackedTime: controller.settings.commentToTrackedTime,
                    toTask: controller.settings.commentToTask) {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        TextField("", text: $note)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .focused($noteFocused)
                            .onSubmit { noteFocused = false }
                            .help("A note for this task's time — goes to the time entry and/or the task (see Settings ▸ Comments)")
                    }
                }
            } else {
                HStack {
                    Text("Not tracking")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let last = controller.lastTrackedTask() {
                        Button {
                            controller.userPicked(last)
                        } label: {
                            Label("Resume \(last.subject)", systemImage: "play.circle.fill")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.green)
                        .font(.caption)
                        .help("Restart the clock on the last tracked task")
                    }
                }
            }
        }
    }

    // MARK: - Inline pin editor

    private var pinEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Each part is clickable: tap a segment to make IT the rightmost
            // pinned part. Blue = pinned, grey = not. ← / → do the same by key.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(pinSegments.enumerated()), id: \.offset) { i, seg in
                        let piece = (i == 0 ? "" : PinScope.separator(for: pinKind)) + seg
                        Button { pinCount = i + 1 } label: {
                            Text(piece).foregroundColor(i < pinCount ? .accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .font(.callout)
            HStack(spacing: 6) {
                Text("← wider · → narrower · click a part")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button { commitPinning() } label: { Image(systemName: "return") }
                    .buttonStyle(.plain).help("Pin (↵)")
                Button { cancelPinning() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(pinEditingID != nil ? "Unpin (esc)" : "Don't pin (esc)")
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
        .focusable()
        .focused($pinFocused)
        .onKeyPress(.leftArrow) { pinCount = max(1, pinCount - 1); return .handled }
        .onKeyPress(.rightArrow) { pinCount = min(pinSegments.count, pinCount + 1); return .handled }
        .onKeyPress(.return) { commitPinning(); return .handled }
        .onKeyPress(.escape) { cancelPinning(); return .handled }
        .onAppear { pinFocused = true }
    }

    private func beginPinning() {
        guard let draft = controller.pinDraft() else { return }
        pinKind = draft.kind
        pinSegments = draft.segments
        pinCount = draft.defaultCount
        pinEditingID = nil
        pinning = true
    }

    /// Re-open the editor on an existing pin to adjust its scope. (Phase 1 only
    /// the component form is editable here; boolean/AI rules get their editors
    /// next phase.)
    private func reopenPinning(_ pin: Pin) {
        guard let draft = controller.pinDraft() else { return }
        pinKind = draft.kind
        pinSegments = draft.segments
        if case .components(let scope) = pin.rule {
            pinCount = min(scope.prefix.count, draft.segments.count)
        } else {
            pinCount = draft.defaultCount
        }
        pinEditingID = pin.id
        pinning = true
    }

    private func commitPinning() {
        guard case .tracking(.task(let ref), _) = controller.trackerState else { pinning = false; return }
        controller.commitPin(kind: pinKind, prefix: Array(pinSegments.prefix(pinCount)),
                             to: ref, replacingID: pinEditingID)
        pinning = false
        pinEditingID = nil
    }

    /// No "exit without saving": Enter is the only way to keep a pin. The ✕
    /// (and esc) mean "no pin here" — so they UNPIN when we opened on an
    /// existing pin (the same benefit as the badge's ✕), and simply close the
    /// never-committed draft when creating a new one. Same glyph, same meaning
    /// as the badge ✕ now — no longer two different things wearing one icon.
    private func cancelPinning() {
        if pinEditingID != nil { controller.unpinCurrentSurface() }
        pinning = false
        pinEditingID = nil
    }

    @ViewBuilder
    private var promptSection: some View {
        // The gap already defaults to a break (nothing recorded). One tap claims
        // it as the task you were on — no timeline needed. The little × just
        // hides the offer early.
        if let gap = controller.pendingGap,
           Date().timeIntervalSince(gap.to) < controller.settings.idleBackfillWindowSeconds {
            HStack(spacing: 6) {
                Button { controller.claimIdleGap() } label: {
                    Label("Worked \(gapText(gap)) on \(controller.name(of: .task(gap.task)))?",
                          systemImage: "arrow.uturn.backward.circle")
                        .font(.caption).lineLimit(2)
                }
                .buttonStyle(.borderedProminent)
                .help("You were away — one tap counts the gap as that task. Ignore it and it stays a break.")
                Spacer(minLength: 0)
                Button { controller.dismissIdleGap() } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain)
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func gapText(_ gap: IdleGap) -> String {
        "\(gap.from.formatted(date: .omitted, time: .shortened))–\(gap.to.formatted(date: .omitted, time: .shortened))"
    }

    private var switchList: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(changeMode ? "Change to" : "Switch to")
                    .font(.caption)
                    .foregroundStyle(changeMode ? Color.accentColor : .secondary)
                if changeMode {
                    Button { changeMode = false } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).font(.caption2)
                }
                Spacer()
                TextField("filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 120)
            }
            // Default view: recent + likely first, then the rest of the ranked
            // set — all of it scrollable, so a task that isn't in the top picks
            // is still reachable by scrolling (not only by typing a filter).
            // Typing fuzzy-searches every task.
            let shown = filter.isEmpty ? controller.fullPickList() : controller.searchTasks(filter)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown, id: \.ref) { task in
                        taskRow(task)
                    }
                }
            }
            // Explicit height: an unconstrained ScrollView collapses to one
            // row inside the MenuBarExtra popover. Cap it so a long list
            // actually scrolls rather than growing the popover off-screen.
            .frame(height: min(CGFloat(max(shown.count, 1)) * 26, 240))
            if noteFocused {
                Text("type a comment on your current work, ↵ when done")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else if filter.isEmpty, !controller.taskCache.isEmpty {
                Text("type to search all \(controller.taskCache.count) tasks")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if controller.taskCache.isEmpty {
                Text("No tasks yet – set OP URL + API key in Settings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let error = controller.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    private func taskRow(_ task: WorkTask) -> some View {
        Button {
            if changeMode {
                controller.changeCurrentTask(to: task.ref)
                changeMode = false
                filter = ""
            } else {
                controller.userPicked(task)
            }
        } label: {
            HStack {
                Text(task.subject).lineLimit(1)
                Spacer()
                Text(task.project.map { "\($0) · " } ?? "" )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                + Text(task.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                openWindow(id: "timeline")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                // Horizontal segmented bar — matches our left-to-right timeline
                // (the old calendar.day.timeline.left glyph reads vertical).
                Image(systemName: "rectangle.split.3x1")
            }
            .help("Timeline – today's tracked time")
            Button {
                openWindow(id: "spent")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "chart.pie")
            }
            .help("Time Spent – period breakdown")
            Button {
                openWindow(id: "review")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("\(controller.pendingReview.count)", systemImage: "tray.full")
            }
            .help("Review queue")
            Spacer()
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .help("Quit Ambitick")
        }
        .buttonStyle(.plain)
        .font(.body)
        .foregroundStyle(.secondary)
    }
}
