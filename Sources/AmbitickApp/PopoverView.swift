import SwiftUI
import AmbitickCore
import AmbitickMac

struct PopoverView: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow
    @State private var filter = ""
    @State private var note = ""
    /// Today's breakdown for the footer launch button (a live mini-pie). Cached —
    /// it's a journal query, not for every popover render.
    @State private var todayNodes: [TimeAggregator.Node] = []
    @State private var changeMode = false
    @FocusState private var noteFocused: Bool
    @FocusState private var filterFocused: Bool
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
    // Hamburger modes: the visual blue/grey Components editor, or a typed
    // boolean Expression. (AI mode lands in a later pass.)
    enum PinMode { case components, expression }
    @State private var pinMode: PinMode = .components
    @State private var pinExpression = ""
    @State private var pinExprError: String?
    // Advanced (geek) option: a manual priority that overrides specificity-based
    // precedence when several pins match. Off by default → nil priority, so an
    // ordinary pin behaves exactly as before. On → pinPriority (higher wins).
    @State private var pinPriorityOn = false
    @State private var pinPriority = 5

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
        .onChange(of: controller.trackerState) { _, _ in note = controller.manualNote; todayNodes = controller.todaySpentNodes() }
        .onChange(of: controller.journalRevision) { _, _ in todayNodes = controller.todaySpentNodes() }
        // Focus the filter when the popover opens so you can type-to-search
        // immediately (the "type to search…" hint promised typing would work).
        .onAppear {
            changeMode = controller.settings.popoverDefaultsToChangeMode
            todayNodes = controller.todaySpentNodes()
            DispatchQueue.main.async { filterFocused = true }
        }
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
                    .help(changeMode
                          ? "In Change-to mode — click to switch to Switch-to (start a new session)"
                          : "In Switch-to mode — click to switch to Change-to (relabel this session)")
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
                        // the task name, already shown above) re-opens the
                        // editor, where the ✕ unpins (no separate badge ✕).
                        Text(controller.elapsedText)
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
                        .help("Pinned — click to adjust the scope or unpin")
                    } else {
                        Text("\(controller.elapsedText)  ·  \(Int((certainty * 100).rounded()))% certain")
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
            if pinMode == .components {
                componentsEditor
            } else {
                expressionEditor
            }
            priorityControl
            // Parse errors get their OWN full-width, wrapping line — not crammed
            // into the button row where they overlapped the icons.
            if let err = pinExprError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack(spacing: 6) {
                Text(modeHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button { commitPinning() } label: { Image(systemName: "return") }
                    .buttonStyle(.plain).help("Pin (↵)")
                // The hamburger sits between Pin and Cancel — switch editor mode.
                Menu {
                    Button { switchMode(.components) } label: {
                        Label("Components", systemImage: pinMode == .components ? "checkmark" : "rectangle.split.3x1")
                    }
                    Button { switchMode(.expression) } label: {
                        Label("Expression", systemImage: pinMode == .expression ? "checkmark" : "curlybraces")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Pin mode: Components or Expression")
                Button { cancelPinning() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(pinEditingID != nil ? "Unpin (esc)" : "Don't pin (esc)")
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.08)))
    }

    /// The visual blue/grey prefix selector (Components mode).
    private var componentsEditor: some View {
        // Each part is clickable: tap a segment to make IT the rightmost pinned
        // part. Blue = pinned, grey = not. ← / → do the same by key.
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
        .focusable()
        .focused($pinFocused)
        .onKeyPress(.leftArrow) { pinCount = max(1, pinCount - 1); return .handled }
        .onKeyPress(.rightArrow) { pinCount = min(pinSegments.count, pinCount + 1); return .handled }
        .onKeyPress(.return) { commitPinning(); return .handled }
        .onKeyPress(.escape) { cancelPinning(); return .handled }
        .onAppear { pinFocused = true }
    }

    /// Advanced (geek) priority control: a collapsed disclosure so it stays out
    /// of the way. Open it, flip the toggle on, and a stepper sets the manual
    /// priority (higher wins ties against looser/less-specific pins). Off → nil,
    /// i.e. ordinary specificity-then-recency precedence.
    private var priorityControl: some View {
        DisclosureGroup {
            HStack(spacing: 6) {
                Toggle("Manual priority", isOn: $pinPriorityOn)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                if pinPriorityOn {
                    Stepper(value: $pinPriority, in: 1...100) {
                        Text("\(pinPriority)").font(.caption2).monospacedDigit()
                    }
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .help("Higher priority wins when several pins match the same window — overrides the usual most-specific-wins rule.")
        } label: {
            Text("Advanced").font(.caption2).foregroundStyle(.tertiary)
        }
        .font(.caption2)
    }

    /// Footer mode help (the parse error has its own line above).
    private var modeHint: String {
        pinMode == .components
            ? "← wider · → narrower · click a part"
            : "fields: app·title·url   ops: is·contains·starts with·matches   logic: and·or·not·( )"
    }

    /// The typed boolean Expression editor.
    private var expressionEditor: some View {
        TextField("e.g. title contains \"Ambitick\" and not url contains \"github\"",
                  text: $pinExpression)
            .textFieldStyle(.roundedBorder)
            .font(.system(.callout, design: .monospaced))
            .focused($pinFocused)
            .onSubmit { commitPinning() }
            .onChange(of: pinExpression) { _, _ in pinExprError = nil }
            .onAppear { pinFocused = true }
    }

    private func beginPinning() {
        guard let draft = controller.pinDraft() else { return }
        pinKind = draft.kind
        pinSegments = draft.segments
        pinCount = draft.defaultCount
        pinEditingID = nil
        pinMode = .components
        pinExpression = ""
        pinExprError = nil
        pinPriorityOn = false
        pinPriority = 5
        pinning = true
    }

    /// Re-open the editor on an existing pin to adjust it. A Components pin opens
    /// in Components mode; an Expression pin opens in Expression mode with its
    /// rule rendered back to text, fully editable.
    private func reopenPinning(_ pin: Pin) {
        guard let draft = controller.pinDraft() else { return }
        pinKind = draft.kind
        pinSegments = draft.segments
        pinExprError = nil
        switch pin.rule {
        case .components(let scope):
            pinMode = .components
            pinCount = min(scope.prefix.count, draft.segments.count)
            pinExpression = ""
        case .expression(let predicate):
            pinMode = .expression
            pinCount = draft.defaultCount
            pinExpression = PredicateParser.string(from: predicate)
        }
        if let p = pin.priority {
            pinPriorityOn = true
            pinPriority = p
        } else {
            pinPriorityOn = false
            pinPriority = 5
        }
        pinEditingID = pin.id
        pinning = true
    }

    /// Switch hamburger mode. Crossing into Expression with an empty box seeds it
    /// from the current Components selection, so the typed rule starts where the
    /// visual one left off (converting what's convertible).
    private func switchMode(_ mode: PinMode) {
        if mode == .expression, pinExpression.trimmingCharacters(in: .whitespaces).isEmpty {
            pinExpression = componentsAsExpression()
        }
        pinExprError = nil
        pinMode = mode
    }

    /// The current Components selection as an equivalent typed expression.
    private func componentsAsExpression() -> String {
        let prefix = Array(pinSegments.prefix(pinCount))
        guard !prefix.isEmpty else { return "" }
        switch pinKind {
        case .url:
            return "url contains \"\(prefix.joined(separator: "/"))\""
        case .app:
            if prefix.count == 1 { return "app is \"\(prefix[0])\"" }
            let rest = prefix.dropFirst().joined(separator: " ")
            return "app is \"\(prefix[0])\" and title contains \"\(rest)\""
        }
    }

    private func commitPinning() {
        guard case .tracking(.task(let ref), _) = controller.trackerState else { pinning = false; return }
        let priority = pinPriorityOn ? pinPriority : nil
        if pinMode == .expression {
            switch PredicateParser.parse(pinExpression) {
            case .success(let predicate):
                controller.commitPin(rule: .expression(predicate), to: ref,
                                     replacingID: pinEditingID, priority: priority)
            case .failure(let error):
                pinExprError = message(for: error)
                return   // keep the editor open so the user can fix it
            }
        } else {
            controller.commitPin(kind: pinKind, prefix: Array(pinSegments.prefix(pinCount)),
                                 to: ref, replacingID: pinEditingID, priority: priority)
        }
        pinning = false
        pinEditingID = nil
    }

    private func message(for error: PredicateParser.ParseError) -> String {
        switch error {
        case .empty: return "Type an expression, or switch to Components."
        case .unbalancedParens: return "Unbalanced parentheses."
        case .expectedValue: return "An operator needs a value, e.g. contains \"…\"."
        case .unexpected(let what): return "Didn't understand near: \(what)"
        }
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
                    .focused($filterFocused)
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
            } else if filter.isEmpty, filterFocused, !controller.taskCache.isEmpty {
                // Only when the filter has focus — otherwise it promised typing
                // would do something when focus was elsewhere and it didn't.
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
            // One combined Time entry point — opens the timeline, the pie, or
            // whichever was viewed last (Settings ▸ Time view). Each window has
            // a switcher to the other in its top-right.
            Button {
                controller.timeWindowView = controller.initialTimeView()
                openWindow(id: "time")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                if todayNodes.isEmpty {
                    Image(systemName: "chart.pie")
                } else {
                    MiniPie(nodes: todayNodes, colour: { Color(nsColor: controller.colour(for: $0)) })
                        .frame(width: 22, height: 22)
                }
            }
            .help("Time – today's breakdown; click for the timeline / pie")
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
