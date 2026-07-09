import SwiftUI
import andeyeTTCore
import andeyeTTMac

/// The low-certainty review queue: stacked by default (2026-07-06 spec §2/§4,
/// approvals-drawer v1) — one row per identical surface (app · window title ·
/// tab URL), not one row per slice. Multi-select rows (click-drag,
/// shift-click range, ⌘-click toggle, ⇧↑/⇧↓ — native List/NSTableView
/// extended selection) at the STACK level, then one-click assign; a header
/// sort control (newest/oldest by last activity, longest/shortest by total —
/// `ReviewSortOrder`, persisted in settings) reorders the stacks so a
/// shift-click range can sweep everything below a duration or before a date
/// in one assign (Martin, 2026-07-09). Selection is keyed by surface id, so
/// changing the sort keeps the same stacks selected — it means "these
/// surfaces", not "these positions". A stack with more than one slice
/// expands to a read-only list on click. Assign to any task (fuzzy-filtered),
/// to "Do not track", or create a new local (non-OpenProject) task on the
/// spot and assign to it.
struct ReviewView: View {
    @ObservedObject var controller: AppController
    @State private var selection = Set<String>()
    @State private var expanded = Set<String>()
    @State private var aiResponse = ""
    @State private var aiStatus = ""
    @State private var filter = ""
    @State private var newLocalName = ""
    /// The post-assign grain footer (2026-07-03 spec §5.3, "later polish"):
    /// what was just taught, mirroring `PopoverView`'s `justPicked` tuple.
    /// Ignoring it is "once" — it never blocks assigning the next stack.
    @State private var justAssigned: (task: WorkTask, signal: ActivitySignal, identity: ContextIdentity)?
    /// Multi-correspondent checkbox selection for the footer (spec §5.5) —
    /// all checked by default.
    @State private var correspondentChecks: Set<String> = []
    /// "Recently cleared" (spec §3 digest) — collapsed by default; it's a
    /// receipt, not something to review every time the drawer opens.
    @State private var clearedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            List(selection: $selection) {
                ForEach(keyedStacks, id: \.key) { entry in
                    stackRow(entry.stack).tag(entry.key)
                }
            }

            if !selection.isEmpty {
                assignBar
            }
            grainFooter
            clearedSection

            Divider()
            aiSection
        }
        .padding(10)
    }

    /// The window header: decisions (stacks) up front, per spec §7 — the
    /// exact slice count stays here for the curious, never in the badge —
    /// plus the sort control (menu picker, matching Settings' compact
    /// `.menu` + `.fixedSize()` vocabulary).
    private var header: some View {
        HStack {
            Text("\(controller.pendingDecisionCount) to decide").font(.headline)
            Spacer()
            Picker("", selection: $controller.settings.reviewSortOrder) {
                Text("Newest").tag(ReviewSortOrder.newestFirst)
                Text("Oldest").tag(ReviewSortOrder.oldestFirst)
                Text("Longest").tag(ReviewSortOrder.longestFirst)
                Text("Shortest").tag(ReviewSortOrder.shortestFirst)
            }
            .pickerStyle(.menu).fixedSize().controlSize(.small)
            .help("Sort the queue – newest/oldest by last activity, longest/shortest by total time")
            Text("\(totalSlices) slices").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Stacks in the user's chosen order (`ReviewSortOrder`, Core-checked).
    /// The already-selected ids stay selected across a sort change — the
    /// Set survives untouched and the List re-highlights by tag.
    private var stacks: [ReviewStack] { controller.reviewStacks().sorted(by: controller.settings.reviewSortOrder) }

    private var totalSlices: Int { stacks.reduce(0) { $0 + $1.segments.count } }

    private func surfaceKey(_ stack: ReviewStack) -> String {
        "\(stack.app)|\(stack.windowTitle ?? "")|\(stack.tabURL ?? "")"
    }

    private var keyedStacks: [(key: String, stack: ReviewStack)] {
        stacks.map { (surfaceKey($0), $0) }
    }

    private var selectedStacks: [ReviewStack] {
        keyedStacks.filter { selection.contains($0.key) }.map(\.stack)
    }

    private func stackRow(_ stack: ReviewStack) -> some View {
        let key = surfaceKey(stack)
        let expandable = stack.segments.count > 1
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                if expandable {
                    Button {
                        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
                    } label: {
                        Image(systemName: expanded.contains(key) ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text(stackTitle(stack)).lineLimit(1)
                    if let url = stack.tabURL {
                        Text(url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                // Single-slice stacks look like today's rows (duration + start
                // time); a stack the user hasn't split into slices shouldn't
                // read differently from the old flat list.
                if expandable {
                    Text(stackSummaryTail(stack)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(durationText(stack.total)).font(.caption).foregroundStyle(.secondary)
                    Text(stack.first.formatted(date: .omitted, time: .shortened)).font(.caption)
                }
            }
            calendarHintChip(for: stack, key: key)
            if expandable, expanded.contains(key) {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(stack.segments) { segment in
                        HStack {
                            Text(segment.start.formatted(date: .omitted, time: .shortened))
                            Spacer()
                            Text(durationText(segment.end.timeIntervalSince(segment.start)))
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 20)
            }
        }
    }

    /// The review-queue hint chip (calendar-signal spec §7): a past calendar
    /// event overlapping the stack's own span. A resolved rule assigns
    /// straight to its task (same `assignStack` path the pick buttons use —
    /// teaches the calendar ladder from the acceptance like any other
    /// correction); no rule yet just selects this one stack and prefills the
    /// assign bar's filter with the event title, so picking a task is one
    /// less step than typing it from scratch.
    @ViewBuilder
    private func calendarHintChip(for stack: ReviewStack, key: String) -> some View {
        if let hint = controller.calendarHint(for: stack) {
            HStack(spacing: 4) {
                Image(systemName: "calendar").font(.caption2).foregroundStyle(.secondary)
                if let target = hint.target {
                    Text("\(hint.eventTitle) → \(controller.name(of: .task(target)))")
                        .font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Assign") { controller.assignStack(stack, to: .task(target)) }
                        .font(.caption2).buttonStyle(.borderless)
                } else {
                    Text("\(hint.eventTitle) → assign").font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Assign") { selection = [key]; filter = hint.eventTitle }
                        .font(.caption2).buttonStyle(.borderless)
                }
            }
        }
    }

    private func stackTitle(_ s: ReviewStack) -> String {
        "\(s.app)\(s.windowTitle.map { " – \($0)" } ?? "")"
    }

    /// "<total> over N slices, <first> – <last>" — the trailing detail for a
    /// multi-slice stack (spec §4 grouped drawer, amended to group by
    /// surface rather than task/day).
    private func stackSummaryTail(_ s: ReviewStack) -> String {
        let sameDay = Calendar.current.isDate(s.first, inSameDayAs: s.last)
        let span = sameDay
            ? "\(s.first.formatted(date: .omitted, time: .shortened)) – \(s.last.formatted(date: .omitted, time: .shortened))"
            : "\(s.first.formatted(date: .abbreviated, time: .shortened)) – \(s.last.formatted(date: .abbreviated, time: .shortened))"
        return "\(durationText(s.total)) over \(s.segments.count) slices, \(span)"
    }

    private var assignBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Assign \(selection.count):").font(.caption)
                TextField("type to filter tasks", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 180)
                    .onSubmit { if let t = filteredTasks().first { assign(.task(t.ref)) } }
                    .help("Filter tasks; ↵ assigns the selection to the top result")
                Button("Do not track") { assign(.doNotTrack) }
                    .keyboardShortcut("d", modifiers: .command)
                    .help("Mark the selection as not worked (⌘D)")
                Button("Unknown") { assign(.task(WorkTask.unknown.ref)) }
                    .help("Sweep to Unknown – tracked, safe, off your plate, reclaimable")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(filteredTasks(), id: \.ref) { task in
                        Button {
                            assign(.task(task.ref))
                        } label: {
                            HStack(spacing: 3) {
                                if task.isLocalOnly {
                                    Image(systemName: "house").font(.system(size: 8))
                                }
                                Text(task.subject)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "plus.circle").foregroundStyle(.secondary).font(.caption)
                TextField("…or new non-OpenProject task (e.g. Games)", text: $newLocalName)
                    .textFieldStyle(.roundedBorder).font(.caption)
                    .onSubmit(createAndAssign)
                Button("Create & assign", action: createAndAssign)
                    .disabled(newLocalName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func createAndAssign() {
        let name = newLocalName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let ref = controller.addLocalTask(name: name, isLeisure: false,
                                          primeToCurrentSurface: true)
        newLocalName = ""
        assign(.task(ref))
    }

    private func filteredTasks() -> [WorkTask] {
        controller.searchTasks(filter)
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Copy AI prompt") { controller.copyAIPrompt() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy the classification prompt to the clipboard (⌘⇧C)")
                Button("Apply pasted response") {
                    aiStatus = controller.ingestAIResponse(aiResponse)
                    aiResponse = ""
                }
                .disabled(aiResponse.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Apply the pasted AI JSON (⌘↵)")
                Text(aiStatus).font(.caption2).foregroundStyle(.secondary)
            }
            TextEditor(text: $aiResponse)
                .frame(height: 60)
                .font(.system(.caption, design: .monospaced))
                .overlay(alignment: .topLeading) {
                    if aiResponse.isEmpty {
                        Text("Paste the AI's JSON response here…")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .padding(4)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    /// Express path stays one-selection-one-assign fast: a single stack
    /// routes through `assignStack` directly; a multi-stack selection
    /// flattens to the underlying segment ids and goes through the existing
    /// `assignReview` path (both teach the attributor from every distinct
    /// surface covered — approvals-drawer spec §1 side-bug fix).
    private func assign(_ target: Target) {
        let picked = selectedStacks
        guard !picked.isEmpty else { return }
        let assignedSegments = picked.flatMap(\.segments)
        if picked.count == 1 {
            controller.assignStack(picked[0], to: target)
        } else {
            controller.assignReview(assignedSegments.map(\.id), to: target)
        }
        selection.removeAll()
        justAssigned = footerContext(for: assignedSegments, target: target)
        correspondentChecks = justAssigned.map { Set(ContextIdentity.correspondentChoices($0.signal)) } ?? []
    }

    /// The post-assign footer's context, or nil unless EVERY just-assigned
    /// segment shares one email context (spec §5.3) — otherwise there's no
    /// single grain to offer. Mirrors `PopoverView.pick`'s
    /// `justPicked`-building gate (`isEmailGrain`), extended to require
    /// agreement across a multi-row assign. Rows carry the email evidence
    /// their originating signals had, so agreement usually means a full
    /// correspondent/domain/subject ladder; rows whose EVIDENCE disagrees
    /// (two different messages in one batch) retry with the evidence
    /// stripped, so the batch still gets the broader offer the shared
    /// surface supports (typically the whole mail system) instead of none.
    private func footerContext(for segments: [ReviewSegment], target: Target)
        -> (task: WorkTask, signal: ActivitySignal, identity: ContextIdentity)? {
        guard case .task(let ref) = target,
              let task = controller.taskCache.first(where: { $0.ref == ref }),
              !segments.isEmpty else { return nil }
        let signals = segments.map { controller.signal(for: $0) }
        if let shared = sharedEmailIdentity(of: signals) {
            return (task, signals[0], shared)
        }
        let bare = signals.map { signal -> ActivitySignal in
            var s = signal
            s.correspondents = nil
            s.emailSubject = nil
            return s
        }
        guard let shared = sharedEmailIdentity(of: bare) else { return nil }
        return (task, bare[0], shared)
    }

    /// The one identity every signal agrees on, provided it carries an email
    /// grain — the footer's "single grain to offer" gate, factored so the
    /// evidence-bearing pass and the evidence-stripped retry share it.
    private func sharedEmailIdentity(of signals: [ActivitySignal]) -> ContextIdentity? {
        let identities = signals.map { controller.identity(of: $0) }
        guard let shared = identities.first, identities.allSatisfy({ $0 == shared }),
              shared.segments.contains(where: { $0.kind.isEmailGrain }) else { return nil }
        return shared
    }

    /// The assign bar's post-assign grain footer — the same one-line
    /// "remember for <grain> [Remember] [x]" the popover shows after a pick
    /// (2026-07-03 spec §5.3), with the multi-correspondent checkbox
    /// expansion (spec §5.5) when the message has more than one
    /// counterparty. Never blocks assigning the next selection.
    @ViewBuilder
    private var grainFooter: some View {
        if let ja = justAssigned, let count = ja.identity.cardDefaultGrainIndex,
           count >= 1, count <= ja.identity.segments.count {
            let seg = ja.identity.segments[count - 1]
            let choices = ContextIdentity.correspondentChoices(ja.signal)
            let expand = seg.kind == .correspondent && choices.count > 1
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("remember for").font(.caption2).foregroundStyle(.secondary)
                    Text(expand ? "\(seg.display) +\(choices.count - 1)" : seg.display)
                        .font(.caption2).lineLimit(1)
                    Spacer()
                    Button("Remember") {
                        if expand {
                            controller.commitCorrespondentGrain(ja.signal, chosen: correspondentChecks,
                                                                to: ja.task.ref, pinned: false)
                        } else {
                            controller.commitGrain(ja.identity, grainCount: count, signal: ja.signal,
                                                   to: ja.task.ref, pinned: false)
                        }
                        justAssigned = nil
                    }
                    .font(.caption2).buttonStyle(.borderless)
                    Button { justAssigned = nil } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).font(.caption2).foregroundStyle(.tertiary)
                        .help("Dismiss – once (today's soft correction stays; no durable rule)")
                }
                if expand {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(choices, id: \.self) { address in
                            Toggle(isOn: Binding(
                                get: { correspondentChecks.contains(address) },
                                set: { on in
                                    if on { correspondentChecks.insert(address) }
                                    else { correspondentChecks.remove(address) }
                                }
                            )) {
                                Text(address).font(.caption2)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// "Cleared <count> to <task> – <reason>" (spec §3 digest) — collapsed,
    /// hidden entirely when empty so a quiet queue stays quiet.
    @ViewBuilder
    private var clearedSection: some View {
        if !controller.retroDigest.isEmpty {
            DisclosureGroup(isExpanded: $clearedExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(controller.retroDigest, id: \.id) { entry in
                        clearedRow(entry)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Recently cleared (\(controller.retroDigest.count))").font(.caption)
            }
        }
    }

    private func clearedRow(_ entry: RetroDigest) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Cleared \(entry.count) to \(targetName(entry.target)) – \(entry.reason)")
                    .font(.caption).lineLimit(2)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Undo") { controller.undoRetroDigest(entry.id) }
                .font(.caption2).buttonStyle(.borderless)
        }
    }

    private func targetName(_ target: Target) -> String {
        switch target {
        case .doNotTrack: return "Do not track"
        case .task(let ref):
            return controller.taskCache.first(where: { $0.ref == ref })?.subject ?? "unknown task"
        }
    }

    /// "Xm" under an hour, "%dh %02dm" style otherwise — matches the
    /// menu-bar clock's vocabulary (`MenuTitle.text`).
    private func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "<1m" }
        if total < 3600 { return "\(total / 60)m" }
        return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
    }
}
