import SwiftUI
import andeyeTTCore
import andeyeTTMac

struct PopoverView: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow
    @State private var filter = ""
    // The comment field now holds only the UNcommitted draft (what's being
    // typed). Enter commits it — accumulating into `controller.manualNote`,
    // the text the flush path banks onto the slice — then clears the field so
    // another comment can be added to the same slice. So this is NOT mirrored
    // to manualNote on every keystroke any more (that's what let text bleed
    // across slices); it's a local draft only.
    @State private var commentDraft = ""
    // Green after a successful commit (flashes, then fades out); red when the
    // tracked task/slice changed with an uncommitted draft still in the field
    // (a warning that it will orphan onto the new slice if entered now, or be
    // dropped). Both are transient view state, never persisted.
    @State private var commentFlash = false
    @State private var commentWarning = false
    // Honour Reduce Motion: skip the green fade animation, show a brief static
    // confirmation instead (spec: "no green-fade animation; static or skip").
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Today's breakdown for the footer launch button (a live mini-pie). Cached —
    /// it's a journal query, not for every popover render.
    @State private var todayNodes: [TimeAggregator.Node] = []
    @State private var changeMode = false
    /// Task whose locally-stored comment list is showing (right-click → Comments…).
    @State private var commentsFor: WorkTask?
    @FocusState private var noteFocused: Bool
    @FocusState private var filterFocused: Bool
    // The Evidence Card's inline expansion under the why-caption (⌘E) — see
    // the 2026-07-03 context-rules spec §5.3.
    @State private var showEvidenceCard = false
    // The popover's post-pick grain footer: set the moment a task is picked
    // on a surface that carries email evidence, offering the ONE optional
    // follow-up durable-rule commit (this is what replaced the retired
    // silent `learnEmailRule` — spec §5.4). Cleared on dismiss or commit.
    @State private var justPicked: (task: WorkTask, signal: ActivitySignal, identity: ContextIdentity)?
    // Inline pin editor: blue = the chosen prefix, grey = the rest;
    // ← widens, → narrows, ↵ pins, esc abandons.
    @State private var pinning = false
    @State private var pinKind: PinScope.Kind = .url
    @State private var pinSegments: [String] = []
    @State private var pinCount = 1
    // Set when the pinned surface carries email evidence (2026-07-03
    // context-rules spec, pin-editor slice): drives the email grain ladder
    // in Components mode instead of the bare url/app strip. nil = plain
    // surface, `componentsEditor` is unchanged.
    @State private var pinIdentity: ContextIdentity?
    // The id of the pin being edited (re-opened from the badge), so committing
    // updates it in place instead of duplicating. nil = creating a new pin.
    @State private var pinEditingID: UUID?
    @FocusState private var pinFocused: Bool
    // Hamburger modes: the visual blue/grey Components editor, a typed boolean
    // Expression, or AI (copy a prompt, paste back a rule).
    enum PinMode { case components, expression, ai }
    @State private var pinMode: PinMode = .components
    @State private var pinExpression = ""
    @State private var pinExprError: String?
    // AI mode: editable guidance, the generated prompt (auto-copied), and the
    // pasted-back reply that deserialises into an editable Expression rule.
    @State private var pinAIAdvice = AIAssist.defaultPinAdvice
    @State private var pinAIPrompt = ""
    @State private var pinAIResponse = ""
    @State private var pinAICopied = false
    // Advanced (geek) option: a manual priority that overrides specificity-based
    // precedence when several pins match. Off by default → nil priority, so an
    // ordinary pin behaves exactly as before. On → pinPriority (higher wins).
    @State private var pinPriorityOn = false
    @State private var pinPriority = 5

    var body: some View {
        // NOTE: exactly 10 children — SwiftUI's ViewBuilder.buildBlock caps at
        // 10. Adding an 11th here won't compile; wrap a couple into a Group{}
        // or a computed subview first.
        VStack(alignment: .leading, spacing: 10) {
            header
            if pinning { pinEditor }
            if showEvidenceCard, !pinning, let sig = controller.currentFocusSignal() {
                EvidenceCardView(controller: controller, signal: sig, host: .popover,
                                 onPick: { task in
                    if changeMode {
                        controller.changeCurrentTask(to: task.ref)
                        // Return to the DEFAULT mode, not a hardcoded false —
                        // else, with Reassign as the default, the header would
                        // flash the non-default blue+(x) override styling right
                        // after every relabel instead of the plain resting look.
                        changeMode = controller.settings.popoverDefaultsToChangeMode
                    } else {
                        controller.userPicked(task)
                    }
                    showEvidenceCard = false
                })
            }
            Divider()
            promptSection
            switchList
            if let jp = justPicked { grainFooter(jp) }
            Divider()
            // Grouped so the notices don't push the 10-child VStack over
            // SwiftUI's ViewBuilder.buildBlock cap (see the NOTE above).
            Group {
                commentBar
                contextNotices
            }
            footer
        }
        .padding(12)
        .frame(width: 300)
        // Make every label selectable so text (build version, errors, names)
        // can be copied out to share — screenshots are painful to send.
        .textSelection(.enabled)
        // The draft is local (a @Published binding would rebuild the popover
        // each keystroke and steal focus). Clearing the field clears the
        // uncommitted-on-switch warning — it resolves either by entering the
        // draft or by clearing it.
        .onChange(of: commentDraft) { _, new in
            if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { commentWarning = false }
        }
        .onChange(of: controller.trackerState) { _, new in
            // The slice changed. The committed text (manualNote) is banked onto
            // the OLD slice by the flush path (onSession) and cleared there, so
            // the new slice starts empty — committed comments belong to the
            // slice they were entered on. We do NOT mirror manualNote back into
            // the field. If the user had typed but not entered a comment, warn
            // (red): it would otherwise silently orphan onto the new slice.
            commentWarning = !commentDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            todayNodes = controller.todaySpentNodes()
            showEvidenceCard = false
            // Keep a freshly-set grain footer: picking a task CHANGES
            // trackerState in the same transaction, so an unconditional
            // reset here clobbers it before it ever renders (the footer is
            // the replacement for the retired silent learnEmailRule — it
            // must survive its own trigger). Clear only when tracking moved
            // somewhere OTHER than the just-picked task (stop, or an
            // unrelated switch making the footer stale).
            if case .tracking(.task(let ref), _) = new, ref == justPicked?.task.ref { return }
            justPicked = nil
        }
        .onChange(of: controller.journalRevision) { _, _ in todayNodes = controller.todaySpentNodes() }
        // Focus the filter when the popover opens so you can type-to-search
        // immediately (the "type to search…" hint promised typing would work).
        .onAppear {
            changeMode = controller.settings.popoverDefaultsToChangeMode
            todayNodes = controller.todaySpentNodes()
            DispatchQueue.main.async { filterFocused = true }
            // Calendar-signal spec §6: opening the popover — the same click
            // that already surfaces the mismatch banner below — pauses the
            // menu-bar flash for this mismatch episode. A no-op outside a
            // live mismatch.
            controller.pauseCalendarFlashForEpisode()
        }
        .sheet(item: $commentsFor) { task in
            commentsSheet(task)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .tracking = controller.trackerState {
                // Clicking the running task name flips the list below into
                // "Reassign" mode (relabel the current session).
                HStack(alignment: .firstTextBaseline) {
                    Button { changeMode.toggle() } label: {
                        Text(controller.currentTaskName()).font(.headline).lineLimit(2)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("t", modifiers: .command)
                    .help(changeMode
                          ? "In Reassign mode — click to switch to Switch-to mode, start a new session (⌘T)"
                          : "In Switch-to mode — click to switch to Reassign mode, relabel this session (⌘T)")
                    // Billable glyph at the end of the running-task display,
                    // matching the pick-list rows. Same effective-billability
                    // source; nil currentTask (leisure/uncached) → no glyph.
                    if let t = controller.currentTask(), controller.isTaskBillable(t) {
                        Image(systemName: "sterlingsign")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
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
                        .help("Back to \(prev.subject) — moves the current slice onto it (⌘Z)")
                    }
                }
            } else {
                Text(controller.currentTaskName()).font(.headline).lineLimit(2)
            }
            if case .tracking(_, let certainty) = controller.trackerState {
                HStack {
                    if let pin = controller.currentPin {
                        // Pinned: drop the redundant "% certain" — the chip says
                        // it's locked. Elapsed time is also redundant with the
                        // always-visible menu-bar clock while tracking, so the
                        // pin badge (icon + the scope's last segment, NOT the
                        // task name already shown above) is the whole row; it
                        // re-opens the editor, where the ✕ unpins (no separate
                        // badge ✕).
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
                        .keyboardShortcut("p", modifiers: .command)
                        .help("Pinned — click to adjust the scope or unpin (⌘P)")
                    } else {
                        HStack(spacing: 4) {
                            // Elapsed time is redundant with the always-visible
                            // menu-bar clock while tracking — certainty is the
                            // one thing NOT shown there, so it's all that's left.
                            Text("\(Int((certainty * 100).rounded()))% certain")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let sig = controller.currentFocusSignal() {
                                Button { showEvidenceCard.toggle() } label: {
                                    HStack(spacing: 2) {
                                        Text(whyGlyph(controller.explain(sig))).lineLimit(1)
                                        Image(systemName: showEvidenceCard ? "chevron.up" : "chevron.down")
                                    }
                                    .font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .keyboardShortcut("e", modifiers: .command)
                                .help("Why this was tracked here — evidence + un-learn (⌘E)")
                            }
                        }
                    }
                    Spacer()
                    // Pin the current window/site to the running task at 100%.
                    if controller.currentPin == nil, !pinning, controller.pinDraft() != nil {
                        Button { beginPinning() } label: {
                            Image(systemName: "pin")
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("p", modifiers: .command)
                        .help("Pin this window/site to the current task, always 100% (⌘P)")
                    }
                    Button { controller.setAway(!controller.away) } label: {
                        Image(systemName: controller.away ? "figure.walk.motion" : "figure.walk")
                            .foregroundStyle(controller.away ? AndeyeColors.highlight : .primary)
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
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Stop tracking (⌘.)")
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
                        .keyboardShortcut("r", modifiers: .command)
                        .help("Restart the clock on the last tracked task (⌘R)")
                    }
                }
            }
        }
    }

    /// The manual-note field, gated the same as before — moved out of the
    /// header and down to just above the footer so it doesn't compete with
    /// the running-task/certainty line for attention.
    @ViewBuilder
    private var commentBar: some View {
        if case .tracking = controller.trackerState,
           CommentRouting.noteInputVisible(
               toTrackedTime: controller.settings.commentToTrackedTime,
               toTask: controller.settings.commentToTask) {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left")
                    .foregroundStyle(commentAccent ?? .secondary)
                    .font(.caption)
                TextField("", text: $commentDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .focused($noteFocused)
                    // Enter COMMITS (accumulates + clears + flashes green), so
                    // one slice can carry several comments; it no longer merely
                    // unfocuses.
                    .onSubmit { submitComment() }
                    .overlay {
                        // Green commit flash — fades out (opacity-driven so the
                        // fade is honest, not a pop). Steady red sits under it
                        // for the uncommitted-on-switch warning.
                        ZStack {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.red, lineWidth: 1.5)
                                .opacity(commentWarning ? 1 : 0)
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.green, lineWidth: 1.5)
                                .opacity(commentFlash ? 1 : 0)
                        }
                    }
                    .help(commentWarning
                          ? "Uncommitted comment — the tracked task changed. ↵ to add it, or clear the field."
                          : "Add a comment on this time — ↵ commits it and clears for the next")
            }
        }
    }

    /// Green while a just-committed comment flashes, red while an uncommitted
    /// draft is orphaned by a slice change, else nil (plain). Green wins the
    /// icon tint the instant after a commit.
    private var commentAccent: Color? {
        if commentFlash { return .green }
        if commentWarning { return .red }
        return nil
    }

    /// Enter in the comment field: commit the current draft. The controller
    /// accumulates it for the tracked-time comment AND (when the toggle is
    /// on) posts it to the DISPLAYED task's activity feed immediately — see
    /// commitComment for why immediacy matters (the flush path once stole
    /// notes onto whichever slice happened to close next). Then clear the
    /// field and flash green.
    private func submitComment() {
        let trimmed = commentDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { noteFocused = false; return }
        controller.commitComment(commentDraft)
        commentDraft = ""
        commentWarning = false
        flashCommitted()
    }

    /// The green confirmation. With Reduce Motion: a brief static show, no fade.
    /// Otherwise: fade in fast, fade out slower. The controller banking is what
    /// makes a comment durable — this is purely a visual receipt.
    private func flashCommitted() {
        if reduceMotion {
            commentFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { commentFlash = false }
        } else {
            withAnimation(.easeIn(duration: 0.12)) { commentFlash = true }
            withAnimation(.easeOut(duration: 0.8).delay(0.12)) { commentFlash = false }
        }
    }

    // MARK: - Inline pin editor

    private var pinEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch pinMode {
            case .components:
                if let identity = pinIdentity {
                    emailComponentsEditor(identity)
                } else {
                    componentsEditor
                }
            case .expression: expressionEditor
            case .ai: aiEditor
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
                // A parse error in Expression mode → hand the failed rule to AI.
                if pinMode == .expression {
                    Button { fixExpressionWithAI() } label: {
                        Label("Fix with AI", systemImage: "sparkles").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Build an AI prompt from this failed expression")
                }
            }
            HStack(spacing: 6) {
                Text(modeHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                // Dismiss and the hamburger sit LEFT of Pin: Pin (↵) is the
                // rightmost control, since users instinctively hit the
                // rightmost icon — it must be the confirm, not the ✕ dismiss
                // (2026-07 hardware-test feedback).
                Button { cancelPinning() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(pinEditingID != nil ? "Unpin (esc)" : "Don't pin (esc)")
                Menu {
                    Button { switchMode(.components) } label: {
                        Label("Components", systemImage: pinMode == .components ? "checkmark" : "rectangle.split.3x1")
                    }
                    Button { switchMode(.expression) } label: {
                        Label("Expression", systemImage: pinMode == .expression ? "checkmark" : "curlybraces")
                    }
                    Button { switchMode(.ai) } label: {
                        Label("AI", systemImage: pinMode == .ai ? "checkmark" : "sparkles")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Pin mode: Components or Expression")
                Button { commitPinning() } label: { Image(systemName: "return") }
                    .buttonStyle(.plain).help("Pin (↵)")
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
                        Text(piece).foregroundColor(i < pinCount ? AndeyeColors.highlight : .secondary)
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

    /// The email flavour of the Components strip (pin-editor slice of the
    /// 2026-07-03 context-rules spec, Option B): same interaction as
    /// `componentsEditor` — click a segment, ← wider, → narrower, ↵ commits —
    /// fed by the email/correspondent/subject ladder instead of the bare
    /// url/app segments. Clicking a segment SETS that grain (not a cumulative
    /// prefix like the plain strip); earlier segments stay lit purely to show
    /// the broader context the grain sits within. Ghost ("not captured")
    /// segments render greyed and are never selectable — the spec's "rows are
    /// never hidden, their absence IS the coverage signal" (§5.5).
    private func emailComponentsEditor(_ identity: ContextIdentity) -> some View {
        let segments = identity.segments
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { i, seg in
                    let piece = (i == 0 ? "" : "  ▸  ") + seg.display
                    Button {
                        guard seg.available else { return }
                        pinCount = i + 1
                    } label: {
                        Text(piece)
                            .foregroundColor(!seg.available ? Color.secondary.opacity(0.4)
                                             : i < pinCount ? AndeyeColors.highlight : .secondary)
                            .italic(!seg.available)
                    }
                    .buttonStyle(.plain)
                    .disabled(!seg.available)
                    .help(seg.available ? "Pin at this grain" : "not captured on this window")
                }
            }
        }
        .font(.callout)
        .focusable()
        .focused($pinFocused)
        .onKeyPress(.leftArrow) {
            pinCount = identity.steppedGrainCount(from: pinCount, narrower: false)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            pinCount = identity.steppedGrainCount(from: pinCount, narrower: true)
            return .handled
        }
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
        switch pinMode {
        case .components: return "← wider · → narrower · click a part"
        case .expression: return "fields: app·title·url·from·subject·any   ops: is·contains·starts with·matches   logic: and·or·not·( )"
        case .ai: return "copy the prompt → paste the AI's reply → ↵ applies it as an editable rule"
        }
    }

    /// AI mode: an editable guidance box, the generated prompt (scrollable,
    /// auto-copied), and a paste-back that deserialises into an Expression rule.
    private var aiEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("guidance for the AI", text: $pinAIAdvice, axis: .vertical)
                .textFieldStyle(.roundedBorder).font(.caption2).lineLimit(1...3)
                .onChange(of: pinAIAdvice) { _, _ in buildAIPrompt() }
            HStack {
                Button { buildAIPrompt() } label: {
                    Label(pinAICopied ? "Copied" : "Copy prompt", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                Spacer()
            }
            ScrollView {
                Text(pinAIPrompt)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 72)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
            TextField("paste the AI's rule here, ↵ to apply", text: $pinAIResponse)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
                .focused($pinFocused)
                .onSubmit { applyAIResponse() }
        }
        .onAppear { if pinAIPrompt.isEmpty { buildAIPrompt() }; pinFocused = true }
    }

    /// Build the AI prompt from the current surface + guidance, and copy it.
    private func buildAIPrompt() {
        guard let f = controller.currentSurfaceFields() else { pinAIPrompt = ""; return }
        pinAIPrompt = AIAssist.pinRulePrompt(app: f.app, title: f.title, url: f.url,
                                             advice: pinAIAdvice)
        controller.copyToClipboard(pinAIPrompt)
        pinAICopied = true
    }

    /// Deserialise the pasted AI reply into an editable Expression rule (or show a
    /// parse error). On success it flips to Expression mode so ↵ then pins.
    private func applyAIResponse() {
        let cleaned = AIAssist.cleanRuleReply(pinAIResponse)
        guard !cleaned.isEmpty else { pinExprError = "Paste the AI's reply first."; return }
        switch PredicateParser.parse(cleaned) {
        case .success(let predicate):
            // Same B13 gate as commit: catch a broken `matches` pattern in
            // the AI's reply before it reaches the editor as "valid".
            let broken = predicate.invalidRegexPatterns
            guard broken.isEmpty else {
                pinExprError = "matches pattern isn't a valid regex: \(broken.joined(separator: ", "))"
                return
            }
            pinExpression = cleaned
            pinExprError = nil
            pinMode = .expression
        case .failure(let error):
            pinExprError = message(for: error)
        }
    }

    /// Parse-error escape hatch: hand the failed expression to AI mode.
    private func fixExpressionWithAI() {
        pinAIAdvice = AIAssist.defaultPinAdvice +
            " The expression \"\(pinExpression)\" didn't parse — return a corrected one."
        pinExprError = nil
        switchMode(.ai)
    }

    /// The typed boolean Expression editor.
    private var expressionEditor: some View {
        TextField("e.g. title contains \"andeye\" and not url contains \"github\"",
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
        pinIdentity = controller.pinEmailIdentity()
        pinCount = pinIdentity.map { max(1, $0.defaultGrainCount) } ?? draft.defaultCount
        pinEditingID = nil
        pinMode = .components
        pinExpression = ""
        pinExprError = nil
        pinPriorityOn = false
        pinPriority = 5
        resetAIState()
        pinning = true
    }

    private func resetAIState() {
        pinAIAdvice = AIAssist.defaultPinAdvice
        pinAIPrompt = ""
        pinAIResponse = ""
        pinAICopied = false
    }

    /// Re-open the editor on an existing pin to adjust it. A Components pin opens
    /// in Components mode; an Expression pin opens in Expression mode with its
    /// rule rendered back to text, fully editable.
    private func reopenPinning(_ pin: Pin) {
        guard let draft = controller.pinDraft() else { return }
        pinKind = draft.kind
        pinSegments = draft.segments
        pinIdentity = controller.pinEmailIdentity()
        pinExprError = nil
        resetAIState()
        switch pin.rule {
        case .components(let scope):
            pinMode = .components
            pinExpression = ""
            // A ROOT host pin on an email surface maps cleanly onto the
            // ladder's system/site grain, so reopen INTO the ladder with
            // that grain selected — this is the "the whole site is pinned,
            // narrow it to this correspondent" flow, and re-committing the
            // selected system grain rebuilds the identical root PinScope
            // (id reused), so the round-trip is exact even under a
            // reordered ladder (we select the system segment's own index).
            if let identity = pinIdentity, scope.kind == .url, scope.prefix.count == 1,
               let sys = identity.segments.firstIndex(where: { $0.kind == .emailSystem }) {
                pinCount = sys + 1
            } else {
                // Deeper path pins and app pins have no ladder equivalent —
                // classic strip. pinCount is an index into draft.segments
                // (the URL strip), so the ladder must not consume it: under
                // a reordered ladder its first grain can be a correspondent,
                // and re-committing would silently convert this .components
                // pin into an .expression one.
                pinIdentity = nil
                pinCount = min(scope.prefix.count, draft.segments.count)
            }
        case .expression(let predicate):
            // An email grain (correspondent/domain/subject) is an Expression
            // pin under the hood — reopening in Expression mode with the rule
            // rendered back to text round-trips it; no need to reverse-map it
            // onto the ladder (pin-editor slice, kept deliberately simple).
            pinMode = .expression
            pinCount = pinIdentity.map { max(1, $0.defaultGrainCount) } ?? draft.defaultCount
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
        if mode == .ai { buildAIPrompt() }
    }

    /// The current Components selection as an equivalent typed expression.
    /// On the email ladder this renders the SELECTED grain's rule (not a
    /// prefix union — same "one grammar" mapping `commitPinning` uses).
    private func componentsAsExpression() -> String {
        if let identity = pinIdentity {
            return emailGrainAsExpression(identity) ?? rootScopeExpression()
        }
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

    /// The typed rendering of the currently selected email grain, or nil for
    /// the system/site grain (which stays on the PinScope path — see
    /// `rootScopeExpression`).
    private func emailGrainAsExpression(_ identity: ContextIdentity) -> String? {
        guard pinCount >= 1, pinCount <= identity.segments.count,
              let predicate = identity.segments[pinCount - 1].pinPredicate else { return nil }
        return PredicateParser.string(from: predicate)
    }

    /// The root (broadest) PinScope segment as a typed expression — what the
    /// email ladder's system/site grain and any nil `pinPredicate` fall back
    /// to, since "this whole site" is exactly a root component pin.
    private func rootScopeExpression() -> String {
        guard let root = pinSegments.first else { return "" }
        switch pinKind {
        case .url:  return "url contains \"\(root)\""
        case .app:  return "app is \"\(root)\""
        }
    }

    private func commitPinning() {
        // In AI mode ↵ applies the pasted reply (→ Expression for review); a
        // second ↵ then pins it.
        if pinMode == .ai { applyAIResponse(); return }
        guard case .tracking(.task(let ref), _) = controller.trackerState else { pinning = false; return }
        let priority = pinPriorityOn ? pinPriority : nil
        if pinMode == .expression {
            switch PredicateParser.parse(pinExpression) {
            case .success(let predicate):
                // B13: a syntactically-fine `matches` with a broken PATTERN
                // would persist a rule that silently never fires — refuse it
                // here, where the user can fix it.
                let broken = predicate.invalidRegexPatterns
                guard broken.isEmpty else {
                    pinExprError = "matches pattern isn't a valid regex: \(broken.joined(separator: ", "))"
                    return
                }
                controller.commitPin(rule: .expression(predicate), to: ref,
                                     replacingID: pinEditingID, priority: priority)
            case .failure(let error):
                pinExprError = message(for: error)
                return   // keep the editor open so the user can fix it
            }
        } else if let identity = pinIdentity, pinCount >= 1, pinCount <= identity.segments.count {
            let segment = identity.segments[pinCount - 1]
            guard segment.available else { return }   // a ghost can't be committed
            if let predicate = segment.pinPredicate {
                // A correspondent/domain/subject grain — a single Expression
                // leaf (pin-editor slice of the 2026-07-03 context-rules spec
                // §5.1/§5.4).
                controller.commitPin(rule: .expression(predicate), to: ref,
                                     replacingID: pinEditingID, priority: priority)
            } else {
                // The system/site grain: always the ROOT segment alone (the
                // ladder's user-configured order may put it anywhere, but its
                // meaning is always "this whole site" — not `pinCount`
                // segments of the unrelated URL/app chain).
                controller.commitPin(kind: pinKind, prefix: Array(pinSegments.prefix(1)),
                                     to: ref, replacingID: pinEditingID, priority: priority)
            }
        } else {
            // A plain, non-email surface: the existing component-prefix path.
            controller.commitPin(kind: pinKind, prefix: Array(pinSegments.prefix(pinCount)),
                                 to: ref, replacingID: pinEditingID, priority: priority)
        }
        pinning = false
        pinEditingID = nil
        pinIdentity = nil
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
        pinIdentity = nil
    }

    @ViewBuilder
    private var promptSection: some View {
        // The gap already defaults to a break (nothing recorded). One tap claims
        // it as the task you were on — no timeline needed. The little × just
        // hides the offer early.
        if controller.settings.offerIdleBackfill,
           let gap = controller.pendingGap,
           Date().timeIntervalSince(gap.to) < controller.settings.idleBackfillWindowSeconds {
            HStack(spacing: 6) {
                Button { controller.claimIdleGap() } label: {
                    Label("Worked \(gapText(gap)) on \(controller.name(of: .task(gap.task)))?",
                          systemImage: "arrow.uturn.backward.circle")
                        .font(.caption).lineLimit(2)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .help("You were away — one tap counts the gap as that task. Ignore it and it stays a break. (⌘↵)")
                Spacer(minLength: 0)
                Button { controller.dismissIdleGap() } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain)
                    .help("Dismiss — leave the gap as a break")
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        // Calendar-signal spec §6: the mismatch banner. Only shows once the
        // disagreement has held the settle window (controller.calendarMismatchActive) —
        // a brief walk-in never flashes this either.
        if controller.calendarMismatchActive, let match = controller.currentCalendarMatch {
            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.caption2).foregroundStyle(.secondary)
                Text("Calendar: \(match.eventTitle)")
                    .font(.caption).lineLimit(1)
                Spacer(minLength: 0)
                Button("Switch") { controller.changeCurrentTask(to: match.task) }
                    .font(.caption).buttonStyle(.borderless)
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .help(match.tentative ? "Tentative on your calendar right now" : "On your calendar right now")
        }
    }

    private func gapText(_ gap: IdleGap) -> String {
        "\(gap.from.formatted(date: .omitted, time: .shortened))–\(gap.to.formatted(date: .omitted, time: .shortened))"
    }

    private var switchList: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                // The DEFAULT mode is the resting state, so it reads plain/grey
                // with no revert control; the NON-default mode is the temporary
                // override, so IT wears the blue highlight + the (x) that reverts
                // to the default. Driven off "current mode == the default", NOT
                // off changeMode alone, so it stays correct when the user flips
                // popoverDefaultsToChangeMode (then Switch-to is the plain one).
                let inDefaultMode = changeMode == controller.settings.popoverDefaultsToChangeMode
                Text(changeMode ? "Reassign" : "Switch to")
                    .font(.caption)
                    .foregroundStyle(inDefaultMode ? .secondary : AndeyeColors.highlight)
                if !inDefaultMode {
                    Button { changeMode = controller.settings.popoverDefaultsToChangeMode } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain).font(.caption2)
                    .help("Back to the default mode")
                }
                Spacer()
                TextField("filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 120)
                    .focused($filterFocused)
                    .onSubmit { pickFirstFiltered() }
                    .help("Search your tasks")
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

    /// Pick a task (switch or relabel, per mode). Shared by a row click and the
    /// filter's ↵. On an email/recipe surface this ALSO offers the post-pick
    /// grain footer (2026-07-03 spec §5.3) — the one optional follow-up that
    /// replaced the retired silent `learnEmailRule`.
    private func pick(_ task: WorkTask) {
        let sig = controller.currentFocusSignal()
        // STOPPED overrides the mode: there is nothing to reassign, so a
        // task click always STARTS tracking that task (Martin, 2026-07-09:
        // after an idle stop, Reassign-mode clicks silently did nothing).
        if case .stopped = controller.trackerState {
            controller.userPicked(task)
            changeMode = controller.settings.popoverDefaultsToChangeMode
            filter = ""
        } else if changeMode {
            controller.changeCurrentTask(to: task.ref)
            // Reset to the DEFAULT mode (not hardcoded false) so the header
            // returns to its plain resting look after a relabel.
            changeMode = controller.settings.popoverDefaultsToChangeMode
            filter = ""
        } else {
            controller.userPicked(task)
        }
        if let sig {
            let identity = controller.identity(of: sig)
            justPicked = identity.segments.contains { $0.kind.isEmailGrain }
                ? (task, sig, identity) : nil
        } else {
            justPicked = nil
        }
    }

    /// Short "why?" label for the caption suffix — the winning rule's value
    /// when a learned email rule fired, else a terse source name.
    private func whyGlyph(_ e: AttributionExplanation) -> String {
        if let rule = e.matchedEmailRule { return "✉ \(rule.value.isEmpty ? "any mail" : rule.value)" }
        switch e.source {
        case .sessionSticky: return "categorised today"
        case .primedSurface: return "remembered"
        case .pendingPrime: return "just opened"
        case .ranked: return "learned"
        case .opTaskURL, .opTaskTitle: return "OP task"
        case .pin, .emailRule, .none: return ""
        }
    }

    /// The post-pick grain footer: the conservative default grain for the
    /// surface just picked, with a one-click Remember and a dismiss. Ignoring
    /// it (or picking another task) is "once" — the express path never blocks.
    @ViewBuilder
    private func grainFooter(_ jp: (task: WorkTask, signal: ActivitySignal, identity: ContextIdentity)) -> some View {
        if let count = jp.identity.cardDefaultGrainIndex, count >= 1, count <= jp.identity.segments.count {
            let seg = jp.identity.segments[count - 1]
            HStack(spacing: 6) {
                Text("remember for").font(.caption2).foregroundStyle(.secondary)
                Text(seg.display).font(.caption2).lineLimit(1)
                Spacer()
                Button("Remember") {
                    controller.commitGrain(jp.identity, grainCount: count, signal: jp.signal,
                                           to: jp.task.ref, pinned: false)
                    justPicked = nil
                }
                .font(.caption2).buttonStyle(.borderless)
                Button { justPicked = nil } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.tertiary)
                    .help("Dismiss – once (today's soft correction stays; no durable rule)")
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// First-LEARN + First-FIRE notices (2026-07-03 spec §6): popover-anchored
    /// only, never a system notification, never blocking. Both auto-dismiss on
    /// the controller's own timer or the next pick — this view just renders
    /// whatever's currently live and offers undo/dismiss.
    @ViewBuilder
    private var contextNotices: some View {
        if let notice = controller.learnNotice, let first = notice.rules.first {
            HStack(spacing: 6) {
                Text("✉ \(noticeValue(first))"
                     + (notice.rules.count > 1 ? " +\(notice.rules.count - 1)" : "")
                     + " → \(notice.taskName)")
                    .font(.caption2).lineLimit(1)
                Spacer()
                Button("Undo") { controller.undoLearnNotice() }
                    .font(.caption2).buttonStyle(.borderless)
                Button { controller.dismissLearnNotice() } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.tertiary)
                    .help("Dismiss")
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        if let notice = controller.fireNotice {
            HStack(spacing: 6) {
                Text("✉ \(noticeValue(notice.rule)) matched → \(notice.taskName)")
                    .font(.caption2).lineLimit(1)
                Spacer()
                Button { controller.dismissFireNotice() } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.tertiary)
                    .help("Dismiss")
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// The rule's matched value for a notice line — the system row's value is
    /// empty ("any mail in the system"), same fallback as `whyGlyph`.
    private func noticeValue(_ rule: EmailRule) -> String {
        rule.value.isEmpty ? "any mail" : rule.value
    }

    /// ↵ in the filter selects the top of the current list — keyboard route to
    /// task selection without reaching for the mouse.
    private func pickFirstFiltered() {
        let shown = filter.isEmpty ? controller.fullPickList() : controller.searchTasks(filter)
        if let first = shown.first { pick(first) }
    }

    private func taskRow(_ task: WorkTask) -> some View {
        Button {
            pick(task)
        } label: {
            HStack {
                HStack(spacing: 3) {
                    if task.isLocalOnly { Image(systemName: "house").font(.system(size: 8)) }
                    // Independent of the house glyph: a task can be both local
                    // and billable. Cash glyph shows on EFFECTIVE billability
                    // (task override else project flag else non-billable).
                    if controller.isTaskBillable(task) {
                        Image(systemName: "sterlingsign").font(.system(size: 8))
                    }
                    // The "now:" badge (calendar-signal spec §5) — shown on
                    // whichever task the live calendar match resolves to,
                    // independent of whether you're already tracking it.
                    if controller.currentCalendarMatch?.task == task.ref {
                        Image(systemName: "clock").font(.system(size: 8))
                            .help("On your calendar now: \(controller.currentCalendarMatch?.eventTitle ?? "")")
                    }
                    Text(task.subject).lineLimit(1)
                }
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
        // Right-click: the task's out-of-band actions (TODO 2026-06-22).
        .contextMenu {
            if let id = task.ref.backendTaskID, let url = controller.taskWebURL(id: id) {
                Button("Open in \(controller.primaryBackendName ?? "backend")") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Comments…") { commentsFor = task }
        }
    }

    /// Timestamped locally-stored notes for one task (the standalone half of
    /// comment-to-task): read-only list, newest at the bottom like a chat.
    private func commentsSheet(_ task: WorkTask) -> some View {
        let comments = controller.storedTaskComments(for: task.ref)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Comments — \(task.subject)").font(.headline)
            if comments.isEmpty {
                Text("No local comments yet. Notes typed in the comment bar land here when they can't (or shouldn't) go to a backend.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(comments.enumerated()), id: \.offset) { _, c in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2).foregroundStyle(.tertiary)
                                Text(c.text).font(.callout).textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            }
            HStack { Spacer(); Button("Done") { commentsFor = nil } }
        }
        .padding(14)
        .frame(width: 340)
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
            .keyboardShortcut("y", modifiers: .command)
            .help("Time – today's breakdown; click for the timeline / pie (⌘Y)")
            Button {
                openWindow(id: "review")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("\(controller.pendingDecisionCount)", systemImage: "tray.full")
            }
            .keyboardShortcut("u", modifiers: .command)
            .help("Review queue (⌘U)")
            Spacer()
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings (⌘,)")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit andeye (⌘Q)")
        }
        .buttonStyle(.plain)
        .font(.body)
        .foregroundStyle(.secondary)
    }
}
