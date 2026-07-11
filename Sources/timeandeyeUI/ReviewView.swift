import SwiftUI
import timeandeyeCore
import timeandeyeMac

/// The low-certainty review queue: stacked by default (2026-07-06 spec §2/§4,
/// approvals-drawer v1) — one row per identical surface (app · window title ·
/// tab URL), not one row per slice. Selection follows the macOS default
/// (Martin, 2026-07-10, second pass: "single click changes selection, shift
/// click spans, cmd click toggles"): a plain click replaces the selection
/// with the clicked row (a stack's header or left margin means the whole
/// group), ⌘-click toggles a row in or out, ⇧-click spans from the last
/// non-shift click through the clicked row in the visible order — groups
/// and slices alike (`ReviewSelection`, Core-checked; sort first via the
/// header control, then span). Rows highlight with the solid accent fill a
/// native List uses, text going white. A
/// selection freely mixes lone slices and whole groups, and the assign bar
/// below acts on ALL of it: its per-task certainty is the mean over every
/// selected slice, group-selected ones included. Assigning removes exactly
/// those slices; their stacks recalculate over what remains. Every stack
/// expands on its chevron; each slice inside carries its own disclosure
/// revealing 100% of what's held — full timestamps, surface, email
/// evidence, current certainty + source, and what filled the time either
/// side. The cheap fields render straight from the queue; the expensive
/// ones (certainty build, neighbours) arrive lazily from the controller's
/// batched cache, so Expand all (⌘E) opens the whole drawer instantly.
/// Assign to any task (fuzzy-filtered), Clear (drop from the queue and
/// timesheets, teaching nothing — Martin's 2026-07-10 naming call), or
/// create a new local (non-OpenProject) task on the spot and assign to it;
/// ⌫ with a selection is Clear too. The walk bar above the list is the
/// walk-through review (Martin's respec): arrow the day's slices in
/// either direction, dig in at will — every slice landed on, clicked, or
/// opened is marked viewed (eye) — and ONE Confirm takes exactly the viewed
/// slices as your word (`ReviewWalk`/`ReviewConfirm`, Core-checked). There
/// is deliberately NO whole-day confirm.
struct ReviewView: View {
    @ObservedObject var controller: AppController
    /// The selection (`ReviewSelection`, Core-checked): a flat set of slice
    /// ids plus the span anchor — a "selected group" is just all of its
    /// slices being members.
    @State private var selection = ReviewSelection()
    @State private var expanded = Set<String>()
    /// Slices whose full-detail disclosure is open (keyed by segment id).
    @State private var sliceDetail = Set<UUID>()
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
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                header
                if !stacks.isEmpty {
                    walkBar(proxy: proxy)
                }
                List {
                    ForEach(keyedStacks, id: \.key) { entry in
                        stackRow(entry.stack)
                    }
                }
                // ⌫ with a selection = the assign bar's Clear (same action,
                // same ⌘Z, same nothing-is-learned semantics) — the List's
                // native delete command, so both backspace and forward-delete
                // route here.
                .onDeleteCommand {
                    guard !scopedSegments.isEmpty else { return }
                    assign(.doNotTrack)
                }
                // Bare ←/→ walk too while the list has focus; the ⌘[ ⌘]
                // equivalents on the walk buttons work from anywhere in the
                // window (bare arrows must stay free for the text fields).
                .onKeyPress(.leftArrow) { walk(.left, proxy: proxy); return .handled }
                .onKeyPress(.rightArrow) { walk(.right, proxy: proxy); return .handled }

                if !scopedSegments.isEmpty {
                    assignBar
                }
                grainFooter
                misfiledSection
                clearedSection

                Divider()
                aiSection
            }
            .padding(10)
        }
    }

    // MARK: - Walk-through review (Martin's respec)

    /// Arrow through the day's slices in either direction — every slice you
    /// land on opens and is marked viewed (the eye) — then ONE click
    /// confirms exactly the viewed slices as your word. There is NO
    /// whole-day confirm: anything you haven't looked at stays queued,
    /// so reviewing part of the day and coming back later just works.
    private func walkBar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 6) {
            Button { walk(.left, proxy: proxy) } label: { Image(systemName: "arrow.left") }
                .controlSize(.small)
                .keyboardShortcut("[", modifiers: .command)
                .help("Walk to the previous (earlier) slice – it opens and is marked viewed (⌘[ or ← in the list)")
            Button { walk(.right, proxy: proxy) } label: { Image(systemName: "arrow.right") }
                .controlSize(.small)
                .keyboardShortcut("]", modifiers: .command)
                .help("Walk to the next (later) slice – it opens and is marked viewed (⌘] or → in the list)")
            Text("\(controller.reviewWalk.viewedCount) of \(totalSlices) viewed")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Confirm \(controller.reviewWalk.viewedCount) viewed") {
                controller.confirmViewedSlices()
            }
            .controlSize(.small)
            .disabled(controller.reviewWalk.viewedCount == 0)
            .help("Take the current read on every slice you've viewed as your word – one ⌘Z undoes it all. Slices you haven't viewed stay exactly as they are.")
        }
    }

    /// One walk step: move the cursor, then reveal where it landed — expand
    /// its stack, open its detail (landing IS digging in: the full data is
    /// what makes "viewed" honest), and scroll it into view. The slice-id
    /// scroll runs a beat later so the just-expanded row exists to land on.
    private func walk(_ direction: ReviewWalk.Direction, proxy: ScrollViewProxy) {
        controller.walkStep(direction)
        reveal(proxy: proxy)
    }

    private func reveal(proxy: ScrollViewProxy) {
        guard let id = controller.reviewWalk.current,
              let stack = stacks.first(where: { $0.segments.contains { $0.id == id } })
        else { return }
        expanded.insert(stack.id)
        if stack.segments.count > 1 { sliceDetail.insert(id) }
        withAnimation { proxy.scrollTo(stack.id, anchor: .center) }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        }
    }

    /// The viewed mark — always laid out (opacity, not presence) so rows
    /// don't shuffle as marks appear while walking.
    private func viewedMark(_ viewed: Bool, selected: Bool) -> some View {
        Image(systemName: "eye.fill")
            .font(.system(size: 8))
            .foregroundStyle(rowSecondaryStyle(selected))
            .opacity(viewed ? 1 : 0)
            .help("Viewed – Confirm viewed covers every slice marked like this")
    }

    /// The walk cursor's outline — distinct from the solid selection fill,
    /// so where-you-are never masquerades as what's-selected.
    private func currentStroke(_ isCurrent: Bool) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .stroke(Color.accentColor, lineWidth: isCurrent ? 1.5 : 0)
    }

    /// The window header: decisions (stacks) up front, per spec §7 — the
    /// exact slice count stays here for the curious, never in the badge —
    /// plus expand/collapse-all (Martin, 2026-07-10: "Could we have an
    /// open-all option?") and the sort control (menu picker, matching
    /// Settings' compact `.menu` + `.fixedSize()` vocabulary).
    private var header: some View {
        HStack {
            Text("\(controller.pendingDecisionCount) to decide").font(.headline)
            Spacer()
            Button(fullyExpanded ? "Collapse all" : "Expand all") { toggleExpandAll() }
                .controlSize(.small)
                .keyboardShortcut("e", modifiers: .command)
                .help("Open or close every stack and every slice's detail (⌘E)")
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

    /// The drawer's rows as the eye sees them right now, flattened in
    /// display order: each stack's header (a group row), then — only while
    /// that stack is open — its slices. What a ⇧-span runs over, so a span
    /// across group headers picks up the whole groups in between.
    private var visibleRows: [ReviewRow] {
        var rows: [ReviewRow] = []
        for stack in stacks {
            rows.append(.stack(stack.id))
            if expanded.contains(stack.id), stack.segments.count > 1 {
                rows.append(contentsOf: stack.segments.map { ReviewRow.slice($0.id) })
            }
        }
        return rows
    }

    /// One dispatch for every selectable row — a stack's header, its left
    /// margin, or a slice: plain click replaces, ⌘ toggles, ⇧ spans from
    /// the last non-shift click (`ReviewSelection`, the macOS default).
    private func rowClicked(_ row: ReviewRow) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift) {
            selection.shiftClick(row, rows: visibleRows, in: stacks)
        } else if flags.contains(.command) {
            selection.commandClick(row, in: stacks)
        } else {
            selection.click(row, in: stacks)
        }
        // Walk-through attention: clicking a slice — or a single-visit
        // group, which IS its one slice — is looking at it. A multi-slice
        // group click is a bulk gesture and marks nothing (only the clicked
        // row of a ⇧-span counts, never the swept-up middle).
        switch row {
        case .slice(let id):
            controller.walkVisit(id)
        case .stack(let key):
            if let stack = stacks.first(where: { $0.id == key }),
               stack.segments.count == 1, let only = stack.segments.first {
                controller.walkVisit(only.id)
            }
        }
    }

    private func groupSelected(_ stack: ReviewStack) -> Bool {
        ReviewSelection.isStackSelected(stack, in: selection.selected)
    }

    /// Core-checked predicate (`isFullyExpanded`): subset semantics, so ids
    /// of stacks assigned away meanwhile don't wedge the control on
    /// "Collapse all". `surfaceKey` and `ReviewStack.id` are the same
    /// string, so the view's `expanded` set keys match `everyStackID`.
    private var fullyExpanded: Bool {
        stacks.isFullyExpanded(stacks: expanded, slices: sliceDetail)
    }

    private func toggleExpandAll() {
        if fullyExpanded {
            expanded.removeAll()
            sliceDetail.removeAll()
        } else {
            expanded = stacks.everyStackID
            sliceDetail = stacks.everySliceID
        }
    }

    /// Native emphasized-selection text: a selected row reads white on the
    /// solid accent fill, exactly as a native List row does — primary and
    /// secondary flavours.
    private func rowStyle(_ selected: Bool) -> AnyShapeStyle {
        selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary)
    }

    private func rowSecondaryStyle(_ selected: Bool) -> AnyShapeStyle {
        selected ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(.secondary)
    }

    /// A disclosure twisty with a generous hit target (Martin, 2026-07-10:
    /// it had become "much harder to successfully click"). It sits OUTSIDE
    /// the row's selection click surface, so opening a group or a slice's
    /// detail never changes what's selected.
    private func disclosure(open: Bool, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: open ? "chevron.down" : "chevron.right")
                .font(.caption2)
                .foregroundStyle(rowSecondaryStyle(selected))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func stackRow(_ stack: ReviewStack) -> some View {
        let key = surfaceKey(stack)
        let multi = stack.segments.count > 1
        let selected = groupSelected(stack)
        let only = multi ? nil : stack.segments.first
        // The walk cursor outlines the single-slice header itself, or the
        // collapsed header hiding the current slice (expanded multi stacks
        // outline the slice row instead).
        let current = controller.reviewWalk.current
        let cursorHere = only?.id == current
            || (multi && !expanded.contains(key)
                && stack.segments.contains { $0.id == current })
        let viewedHere = stack.segments.filter {
            controller.reviewWalk.viewed.contains($0.id)
        }.count
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                // EVERY stack expands — a single-slice entry opens straight
                // into its full detail ("clicking on an entry should reveal
                // 100% of the data you have on it", Martin 2026-07-10).
                // Opening a single-slice stack reveals everything held on
                // its one slice, so it counts as viewing it (walk-through);
                // a multi chevron only lists visits — that views nothing.
                disclosure(open: expanded.contains(key), selected: selected) {
                    if expanded.contains(key) {
                        expanded.remove(key)
                    } else {
                        expanded.insert(key)
                        if let only { controller.walkVisit(only.id) }
                    }
                }
                HStack {
                    VStack(alignment: .leading) {
                        Text(stackTitle(stack)).lineLimit(1)
                            .foregroundStyle(rowStyle(selected))
                        if let url = stack.tabURL {
                            Text(url).font(.caption2).lineLimit(1)
                                .foregroundStyle(rowSecondaryStyle(selected))
                        }
                    }
                    Spacer()
                    // Single-slice stacks look like today's rows (duration +
                    // dated start); a stack the user hasn't split into slices
                    // shouldn't read differently from the old flat list.
                    if multi {
                        if viewedHere > 0 {
                            // "2/5" beside the eye: how much of this group
                            // the walk has covered, legible while collapsed.
                            Text("\(viewedHere)/\(stack.segments.count)")
                                .font(.caption2)
                                .foregroundStyle(rowSecondaryStyle(selected))
                            viewedMark(true, selected: selected)
                        }
                        Text(stackSummaryTail(stack)).font(.caption)
                            .foregroundStyle(rowSecondaryStyle(selected))
                    } else {
                        viewedMark(viewedHere > 0, selected: selected)
                        Text(durationText(stack.total)).font(.caption)
                            .foregroundStyle(rowSecondaryStyle(selected))
                        Text(dayTimeText(stack.first)).font(.caption)
                            .foregroundStyle(rowStyle(selected))
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { rowClicked(.stack(stack.id)) }
                .help("Click to select this group; ⌘-click to add or remove it; "
                      + "⇧-click to select everything between here and the last row clicked")
            }
            .padding(2)
            .background(selected ? Color.accentColor : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(currentStroke(cursorHere))
            calendarHintChip(for: stack)
            if expanded.contains(key) {
                if multi {
                    // The group's LEFT MARGIN — the same whole-group select
                    // as the header, running the height of the slice list.
                    HStack(alignment: .top, spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(selected ? Color.accentColor
                                           : Color.secondary.opacity(0.25))
                            .frame(width: 3)
                            .frame(width: 12)   // wider hit target than the bar
                            .contentShape(Rectangle())
                            .onTapGesture { rowClicked(.stack(stack.id)) }
                            .help("Click to select this group; ⌘-click to add or remove it; "
                                  + "⇧-click to select everything between here and the last row clicked")
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(stack.segments) { segment in
                                sliceRow(segment)
                            }
                        }
                    }
                    .padding(.leading, 8)
                } else if let only = stack.segments.first {
                    sliceDetailView(only).padding(.leading, 20)
                }
            }
        }
    }

    /// One slice inside an expanded stack: dated start + duration, its own
    /// full-detail disclosure, and the same macOS selection as every other
    /// row — click selects just this visit (so one visit in a stack can go
    /// somewhere different from its siblings), ⌘-click adds or removes it,
    /// ⇧-click spans to it; the assign bar below acts on whatever is
    /// highlighted. The twisty sits outside the selectable surface.
    private func sliceRow(_ segment: ReviewSegment) -> some View {
        let selected = selection.selected.contains(segment.id)
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 2) {
                // Opening a slice's detail is looking at it — the walk
                // marks it viewed (closing never unmarks; attention
                // happened). ⌘E's bulk expand deliberately does not come
                // through here: rendering is not viewing.
                disclosure(open: sliceDetail.contains(segment.id), selected: selected) {
                    if sliceDetail.contains(segment.id) { sliceDetail.remove(segment.id) }
                    else {
                        sliceDetail.insert(segment.id)
                        controller.walkVisit(segment.id)
                    }
                }
                HStack {
                    Text(dayTimeText(segment.start))
                    Spacer()
                    viewedMark(controller.reviewWalk.viewed.contains(segment.id),
                               selected: selected)
                    Text(durationText(segment.end.timeIntervalSince(segment.start)))
                }
                .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                .contentShape(Rectangle())
                .onTapGesture { rowClicked(.slice(segment.id)) }
                .help("Click to select just this slice; ⌘-click to add or remove it; "
                      + "⇧-click to select everything between here and the last row clicked")
            }
            .font(.caption2)
            .padding(2)
            .background(selected ? Color.accentColor : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(currentStroke(controller.reviewWalk.current == segment.id))
            if sliceDetail.contains(segment.id) {
                sliceDetailView(segment).padding(.leading, 14)
            }
        }
        // The walk's scroll anchor — a UUID, so it can never collide with
        // the ForEach's String stack keys.
        .id(segment.id)
    }

    /// Everything held on one slice — full timestamps + duration, the
    /// surface, email evidence when present, the attributor's CURRENT read
    /// (certainty + where it comes from, the Evidence Card's vocabulary),
    /// and what filled the time either side with an explicit gap when it
    /// wasn't back-to-back. The before/after lines use the DISPLAY lookup
    /// (nearest of tracked session or another pending slice); the certainty
    /// line's adjacency boost uses the sessions-only lookup — a pending
    /// neighbour is evidence of nothing (Martin, 2026-07-10).
    ///
    /// The cheap lines render straight from the segment the queue already
    /// holds; the certainty + neighbour lines read the controller's LAZY
    /// batched cache — never computed during render, so Expand all opens a
    /// big backlog instantly and each visible disclosure's detail fills in
    /// a beat later (Martin, 2026-07-10: expand was "intolerably slow").
    private func sliceDetailView(_ segment: ReviewSegment) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(segment.start.formatted(date: .abbreviated, time: .standard)) – "
                 + "\(segment.end.formatted(date: .abbreviated, time: .standard)) · "
                 + durationText(segment.end.timeIntervalSince(segment.start)))
            Text(surfaceLine(segment))
            if let correspondents = segment.correspondents, !correspondents.isEmpty {
                Text("✉ \(correspondents.joined(separator: ", "))"
                     + (segment.emailSubject.map { " – \($0)" } ?? ""))
            } else if let subject = segment.emailSubject {
                Text("✉ \(subject)")
            }
            if let detail = controller.sliceDetails[segment.id] {
                Text(certaintyLine(detail.explanation, neighbours: detail.adjacency))
                // A pending neighbour renders italic — visually distinct
                // from a decided, task-named session either side.
                Text("before: \(neighbourText(detail.display.before, before: true))")
                    .italic(detail.display.before?.isPending == true)
                Text("after: \(neighbourText(detail.display.after, before: false))")
                    .italic(detail.display.after?.isPending == true)
            } else {
                Text("assessing…").foregroundStyle(.tertiary)
            }
        }
        .font(.caption2).foregroundStyle(.secondary)
        .textSelection(.enabled)
        // Fires when the disclosure appears AND again when the generation
        // bumps (an assign invalidated the cache) — idempotent and cheap
        // once the detail is cached.
        .task(id: "\(segment.id.uuidString)#\(controller.sliceDetailGeneration)") {
            controller.requestSliceDetail(for: segment)
        }
    }

    private func surfaceLine(_ segment: ReviewSegment) -> String {
        var parts = ["app \(segment.app)"]
        if let title = segment.windowTitle { parts.append("title \(title)") }
        if let url = segment.tabURL { parts.append("url \(url)") }
        return parts.joined(separator: " · ")
    }

    /// "certainty: <task> 63% (learned associations + priors 45% · follows
    /// X (+18%))" — the attributor's read of this slice as it stands NOW,
    /// scored at the slice's own moment (so the time-of-day prior matches
    /// what actually happened, like the retro pass and `explainSpan`), with
    /// the adjacency boost folded in. Display only — the journal's own
    /// certainty is untouched (see `AdjacencyBoost`).
    private func certaintyLine(_ e: AttributionExplanation,
                               neighbours: SliceNeighbours) -> String {
        guard let chosen = e.chosen else { return "certainty: nothing matched yet" }
        let boost = AdjacencyBoost.apply(base: e.chosenScore, candidate: chosen,
                                         name: controller.name(of: chosen),
                                         neighbours: neighbours)
        let pct = Int((boost.certainty * 100).rounded())
        var why = e.source.plainWord
        if let adjacency = boost.reasoning {
            why += " \(Int((boost.base * 100).rounded()))% · \(adjacency)"
        }
        return "certainty: \(controller.name(of: chosen)) \(pct)% (\(why))"
    }

    /// "<task> until Today 14:20 · …12m gap" / "<task> from Yesterday 9:02"
    /// — the neighbour on one side, with the gap named whenever it wasn't
    /// immediately adjacent; an empty side says so rather than vanishing.
    /// A neighbour that is itself still awaiting review is labelled
    /// "pending review" with its surface, never a task name — nothing is
    /// decided about it yet (Martin's retest, 2026-07-10).
    private func neighbourText(_ n: SliceNeighbours.Neighbour?, before: Bool) -> String {
        guard let n else { return "nothing tracked" }
        let who = n.task.map { controller.name(of: .task($0)) }
            ?? "pending review – \(n.pendingSurface ?? "another slice")"
        var text = before
            ? "\(who) until \(dayTimeText(n.end))"
            : "\(who) from \(dayTimeText(n.start))"
        if !n.isContiguous { text += " · …\(durationText(n.gap)) gap" }
        return text
    }

    /// The review-queue hint chip (calendar-signal spec §7): a past calendar
    /// event overlapping the stack's own span. A resolved rule assigns
    /// straight to its task (same `assignStack` path the pick buttons use —
    /// teaches the calendar ladder from the acceptance like any other
    /// correction); no rule yet just selects this one stack and prefills the
    /// assign bar's filter with the event title, so picking a task is one
    /// less step than typing it from scratch.
    @ViewBuilder
    private func calendarHintChip(for stack: ReviewStack) -> some View {
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
                    // No rule yet: select just this group (every slice of
                    // it) and prefill the filter with the event title.
                    Button("Assign") {
                        selection.click(.stack(stack.id), in: stacks)
                        filter = hint.eventTitle
                    }
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
    /// surface rather than task/day). Both ends carry their day (Today/
    /// Yesterday/date): a queue sorted Oldest is unreadable on times alone.
    private func stackSummaryTail(_ s: ReviewStack) -> String {
        let sameDay = Calendar.current.isDate(s.first, inSameDayAs: s.last)
        let span = sameDay
            ? "\(dayLabel(s.first)) \(s.first.formatted(date: .omitted, time: .shortened)) – \(s.last.formatted(date: .omitted, time: .shortened))"
            : "\(dayTimeText(s.first)) – \(dayTimeText(s.last))"
        return "\(durationText(s.total)) over \(s.segments.count) slices, \(span)"
    }

    /// "Today" / "Yesterday" / "5 Jul" — `RelativeDay`'s calendar-day
    /// classification (Core-checked), formatted for the drawer.
    private func dayLabel(_ date: Date) -> String {
        switch RelativeDay.of(date) {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .other:
            // Another year spells the year out; within this year "5 Jul" is
            // unambiguous and shorter.
            let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            return sameYear
                ? date.formatted(.dateTime.day().month(.abbreviated))
                : date.formatted(.dateTime.day().month(.abbreviated).year())
        }
    }

    /// "Today 14:32" — every time the drawer shows carries its day.
    private func dayTimeText(_ date: Date) -> String {
        "\(dayLabel(date)) \(date.formatted(date: .omitted, time: .shortened))"
    }

    private var assignBar: some View {
        // Boosted certainties for the scoped slices (memoised in the
        // controller, so the per-keystroke re-render costs a cache hit).
        // Buttons sort by descending certainty, carry their percentage, and
        // hover with the full build (Martin, 2026-07-10: "sorted by
        // decreasing certainty, the certainty should be included in the
        // button, and hovering … should give the reasoning").
        let scoped = scopedSegments
        let scores = controller.adjacencyScores(for: scoped)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Assign \(scoped.count) \(scoped.count == 1 ? "slice" : "slices"):")
                    .font(.caption)
                TextField("type to filter tasks", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 180)
                    .onSubmit { if let t = orderedTasks(by: scores).first { assign(.task(t.ref)) } }
                    .help("Filter tasks; ↵ assigns the selection to the top result")
                // "Clear" (Martin's naming call, 2026-07-10): drop from the
                // queue, nothing added to timesheets, and — unlike an
                // assignment — nothing learned (Target.teachesAttributor).
                Button("Clear") { assign(.doNotTrack) }
                    .keyboardShortcut("d", modifiers: .command)
                    .help("Drop the selection from the queue – not added to timesheets, nothing is learned (⌘D, or ⌫ with rows selected)")
                Button("Unknown") { assign(.task(WorkTask.unknown.ref)) }
                    .help("Sweep to Unknown – tracked, safe, off your plate, reclaimable")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(orderedTasks(by: scores), id: \.ref) { task in
                        Button {
                            assign(.task(task.ref))
                        } label: {
                            HStack(spacing: 3) {
                                if task.isLocalOnly {
                                    Image(systemName: "house").font(.system(size: 8))
                                }
                                Text(task.subject)
                                if let score = scores[task.ref] {
                                    Text("\(Int((score.certainty * 100).rounded()))%")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .help(scores[task.ref]?.hover
                              ?? "no signal for this selection yet – assigning teaches from it")
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

    /// The slices the assign bar is currently about: every selected slice,
    /// whether clicked singly or as part of a whole-group select — ONE
    /// per-slice list either way, so the buttons' certainty is the mean
    /// over all of it (Martin, 2026-07-10) and it is exactly the scope
    /// `assign` commits. Filtering through the CURRENT stacks also prunes
    /// ids assigned away meanwhile, so the count and the aggregates always
    /// describe what a click would actually do.
    private var scopedSegments: [ReviewSegment] {
        ReviewSelection.segments(of: selection.selected, in: stacks)
    }

    /// The assign buttons in descending boosted-certainty order; tasks the
    /// scorer has nothing on keep the familiar ranked pick-list order
    /// behind the scored ones (`buttonOrder` is a stable sort).
    private func orderedTasks(by scores: [TaskRef: (certainty: Double, hover: String)]) -> [WorkTask] {
        let tasks = filteredTasks()
        let order = AdjacencyBoost.buttonOrder(
            certainties: tasks.map { scores[$0.ref]?.certainty ?? 0 })
        return order.map { tasks[$0] }
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

    /// One path for every selection shape — a lone slice, a whole group, or
    /// a mix across stacks: the underlying segment ids go through the
    /// existing `assignReview`, which teaches the attributor from every
    /// distinct surface covered (approvals-drawer spec §1 side-bug fix),
    /// registers ONE app-wide ⌘Z entry, and reloads the queue — so the
    /// assigned slices leave their stacks immediately and the remaining
    /// groups (and their button certainties) recalculate.
    private func assign(_ target: Target) {
        let segments = scopedSegments
        guard !segments.isEmpty else { return }
        controller.assignReview(segments.map(\.id), to: target)
        selection.clear()
        justAssigned = footerContext(for: segments, target: target)
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
        if let shared = sharedRuleIdentity(of: signals) {
            return (task, signals[0], shared)
        }
        let bare = signals.map { signal -> ActivitySignal in
            var s = signal
            s.correspondents = nil
            s.emailSubject = nil
            return s
        }
        if let shared = sharedRuleIdentity(of: bare) {
            return (task, bare[0], shared)
        }
        // Disagreeing derived contexts (different repos/documents/paths in
        // one batch): degrade to the shared `site` grain when every row
        // shares one non-mail host — the same rule the email footer applies
        // when a batch only shares the mail system (site-recipes spec §6).
        let hosts = signals.map { $0.tabURL.flatMap { URL(string: $0)?.host?.lowercased() } }
        if let host = hosts.first ?? nil, hosts.allSatisfy({ $0 == host }),
           let chain = ContextIdentity.siteHostChain(of: signals[0]) {
            return (task, signals[0], chain)
        }
        return nil
    }

    /// The one identity every signal agrees on, provided it carries a
    /// rule-committable grain (an email grain, a ◆ recipe field, or the host
    /// row of a plain web page) — the footer's "single grain to offer" gate,
    /// factored so the evidence-bearing pass and the evidence-stripped retry
    /// share it.
    private func sharedRuleIdentity(of signals: [ActivitySignal]) -> ContextIdentity? {
        let identities = signals.map { controller.identity(of: $0) }
        guard let shared = identities.first, identities.allSatisfy({ $0 == shared }),
              shared.footerDefaultGrainIndex != nil else { return nil }
        return shared
    }

    /// The assign bar's post-assign grain footer — the same one-line
    /// "remember for <grain> [Remember] [x]" the popover shows after a pick
    /// (2026-07-03 spec §5.3), with the multi-correspondent checkbox
    /// expansion (spec §5.5) when the message has more than one
    /// counterparty. Never blocks assigning the next selection.
    @ViewBuilder
    private var grainFooter: some View {
        if let ja = justAssigned, let count = ja.identity.footerDefaultGrainIndex,
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

    /// Mis-filed suggestions (his design): one row, refile-all or
    /// dismiss-for-good. Only exists while there ARE suggestions.
    @ViewBuilder
    private var misfiledSection: some View {
        if !controller.refileSuggestions.isEmpty {
            HStack(spacing: 8) {
                Text("\(controller.refileSuggestions.count) slice\(controller.refileSuggestions.count == 1 ? " looks" : "s look") mis-filed under today's rules")
                    .font(.caption)
                Spacer()
                Button("Refile all") { controller.applyRefileSuggestions() }
                    .font(.caption)
                    .help("Move each onto what today's rules say")
                Button("Dismiss") { controller.dismissRefileSuggestions() }
                    .font(.caption)
                    .help("Never suggest these again")
            }
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
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
