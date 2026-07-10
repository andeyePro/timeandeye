import SwiftUI
import timeandeyeCore
import timeandeyeMac
import timeandeyeTheme

/// The Evidence Card (2026-07-03 context-rules spec, Option A + grafts): one
/// view, shared by the timeline's why-pane and the popover's inline
/// expansion. Shows WHY an attribution happened (BECAUSE + sees:), offers
/// un-learn in one click ([✕ forget] / [✕ suppress], with a live "would then
/// fall back to…" preview), and folds the fix + grain choice into one flow
/// (R1 / R2 / R3). The Rules Ledger (list + delete) is a separate, simpler
/// view — spec §5.3 keeps "row opens the card" as later-phase polish.
struct EvidenceCardView: View {
    enum Host: Equatable { case timeline, popover }

    /// The decision that actually STANDS for this window in the journal —
    /// the slice's task and certainty, plus the window's own start so the
    /// re-derived scores use the slice's moment (like the review drawer and
    /// the retro pass). The timeline passes it; the popover leaves it nil
    /// (its card explains the LIVE decision, which IS the current stores).
    struct Recorded: Equatable {
        var target: Target
        var certainty: Double
        var at: Date
    }

    @ObservedObject var controller: AppController
    let signal: ActivitySignal
    let host: Host
    /// The host's own idea of "wrong task, fix it": the timeline reassigns a
    /// window range, the popover switches/relabels the running session. nil
    /// disables the WRONG?/fix section entirely (evidence-only display).
    var onPick: ((WorkTask) -> Void)? = nil
    /// See `Recorded`. When the re-derived explanation contradicts it,
    /// BECAUSE anchors on the record and the re-derivation is shown as
    /// "today's rules would say" — a reason that never fired must not read
    /// as the reason (Martin's 2026-07-10 report: a window in a Time&I
    /// slice claimed "remembered from a past correction → andeye Ltd…").
    var recorded: Recorded? = nil

    @State private var filter = ""
    @State private var grainCount = 1
    @State private var pickedTask: WorkTask?
    @FocusState private var ladderFocused: Bool
    /// Multi-correspondent checkbox selection (spec §5.5, "later polish") —
    /// all checked by default; only meaningful when the selected grain is
    /// the correspondent row AND `correspondentChoices` has more than one.
    @State private var correspondentChecks: Set<String> = []

    private var explanation: AttributionExplanation {
        controller.explain(signal, now: recorded?.at ?? Date())
    }
    /// The record disagrees with today's re-derivation — the card must not
    /// present a reason that never decided this slice as if it had.
    private var recordContradicted: Bool {
        recorded.map { explanation.contradicts(recorded: $0.target) } ?? false
    }
    private var identity: ContextIdentity { controller.identity(of: signal) }
    private var hasEmailGrain: Bool { identity.segments.contains { $0.kind.isEmailGrain } }
    private var unlearn: Attributor.Unlearn? { controller.forgettable(for: signal) }
    /// Every distinct counterparty on this message — more than one triggers
    /// the checkbox expansion instead of a plain correspondent row.
    private var correspondentChoices: [String] { ContextIdentity.correspondentChoices(signal) }
    private var isCorrespondentGrainSelected: Bool {
        grainCount >= 1 && grainCount <= identity.segments.count
            && identity.segments[grainCount - 1].kind == .correspondent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if host == .timeline {
                Text("\(signal.app)\(signal.windowTitle.map { " – \($0)" } ?? "")")
                    .font(.caption).bold().lineLimit(1)
            }
            becauseSection
            seesSection
            candidatesSection
            if onPick != nil {
                Divider()
                wrongTaskSection
            }
        }
        .onAppear {
            grainCount = max(1, identity.cardDefaultGrainIndex
                                ?? identity.siteDefaultGrainIndex
                                ?? identity.defaultGrainCount)
            correspondentChecks = Set(correspondentChoices)   // all checked by default
        }
        .padding(host == .popover ? 6 : 8)
        .frame(maxWidth: host == .popover ? 268 : 340, alignment: .leading)
        .background(.quaternary.opacity(host == .popover ? 0.5 : 1),
                    in: RoundedRectangle(cornerRadius: 6))
        .textSelection(.enabled)
    }

    // MARK: - BECAUSE

    @ViewBuilder
    private var becauseSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 4) {
                Text("BECAUSE").font(.caption2).bold().foregroundStyle(.secondary)
                // Wrap rather than truncate — a long task name or email
                // subject was clipping instead of reading in full.
                Text(anchoredBecauseLabel).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // The stores moved on since this slice was decided (a later
            // correction primed its surface elsewhere, a rule was learned,
            // the slice was reassigned): the re-derivation is shown, but
            // demoted to hypothesis — it is NOT why this time is where it is.
            if recordContradicted {
                Text("today's rules would say: \(becauseLabel) – not what decided this slice")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Keep the story straight after a correction (2026-07-05 report):
            // the engine DID believe something else before the user corrected
            // it — say so, instead of pretending Y was its only idea ever.
            if let prior = explanation.priorToCorrection {
                Text("before your correction: \(priorLabel(prior))")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let rule = explanation.matchedEmailRule {
                Text(ruleProvenance(rule)).font(.caption2).foregroundStyle(.secondary)
            }
            if let rule = explanation.matchedSiteRule {
                Text(siteRuleProvenance(rule)).font(.caption2).foregroundStyle(.secondary)
            }
            if let pin = explanation.matchedPin {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(AndeyeColors.highlight)
                    Text(pin.rule.shortLabel).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The remembered key a prime matched on — over-broad learning
            // (a whole window title, an app with no title) is invisible and
            // effectively unforgettable unless the key is on the card.
            if let surface = explanation.matchedSurface {
                Text(surfaceProvenance(surface))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let u = unlearn {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 6) {
                        Button { controller.forget(u, signal: signal) } label: {
                            Text(forgetLabel(u)).font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove exactly what fired here (undoable, ⌘Z)")
                        Text("→ would then fall back to: \(fallbackText(u))")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // The fallback isn't hypothetical to Martin — a wrong old
                    // rule sitting there as a POSSIBILITY is itself unwelcome
                    // (2026-07 feedback). Offer to remove it directly, without
                    // first forgetting what's currently (correctly) firing.
                    if let fu = controller.forgettableWithout(u, signal) {
                        Button { controller.forget(fu, signal: signal) } label: {
                            Text(forgetFallbackLabel(fu)).font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.orange)
                        .help("Also remove the fallback itself, so it's never offered again (undoable, ⌘Z)")
                    }
                }
                // Disable the implicit animation SwiftUI would otherwise apply
                // to this whole block on click — with wrapping text, a height
                // change here was bleeding into an unwanted reflow/animation
                // of the row(s) below it ("mangled" on click).
                .animation(nil, value: unlearn)
            }
        }
    }

    /// The BECAUSE line's text: the record when one exists and today's
    /// re-derivation contradicts it (the recorded outcome is the only
    /// truthful "because" the card holds — the original source wasn't
    /// journalled, so it claims no source); otherwise the explanation.
    private var anchoredBecauseLabel: String {
        guard let recorded, recordContradicted else { return becauseLabel }
        return "this time stands as → \(controller.name(of: recorded.target)) "
            + pct(recorded.certainty)
    }

    /// "matched remembered surface: Mail · …" — the exact key that fired.
    private func surfaceProvenance(_ surface: Surface) -> String {
        var text = "↺ remembered surface: \(surface.app)"
        if !surface.detail.isEmpty { text += " · \(surface.detail)" }
        return text
    }

    private var becauseLabel: String {
        let chosen = explanation.chosen.map { controller.name(of: $0) } ?? "—"
        switch explanation.source {
        case .pin: return "pinned → \(chosen)"
        case .sessionSticky: return "you categorised this today → \(chosen)"
        case .opTaskURL: return "OpenProject task URL in the tab → \(chosen)"
        case .opTaskTitle: return "OpenProject id in the title → \(chosen)"
        case .emailRule: return "a learned rule fired → \(chosen)"
        case .siteRule: return "a learned site rule fired → \(chosen)"
        case .pendingPrime: return "a just-opened OP task primed it → \(chosen)"
        case .primedSurface: return "remembered from a past correction → \(chosen)"
        case .ranked: return "learned associations + priors → \(chosen)"
        case .none: return "nothing matched"
        }
    }

    private func ruleProvenance(_ rule: EmailRule) -> String {
        var parts = ["✉ \(rule.value.isEmpty ? "any mail" : rule.value)"]
        if rule.createdAt != .distantPast {
            parts.append("learned \(rule.createdAt.formatted(date: .abbreviated, time: .omitted))")
        }
        parts.append("fired \(rule.fireCount)×")
        return parts.joined(separator: " · ")
    }

    private func siteRuleProvenance(_ rule: SiteRule) -> String {
        var parts = ["◆ \(rule.grainLabel.lowercased()) \(rule.value)"]
        if rule.createdAt != .distantPast {
            parts.append("learned \(rule.createdAt.formatted(date: .abbreviated, time: .omitted))")
        }
        parts.append("fired \(rule.fireCount)×")
        return parts.joined(separator: " · ")
    }

    private func forgetLabel(_ u: Attributor.Unlearn) -> String {
        if case .rankedAssociation = u { return "✕ suppress" }
        return "✕ forget"
    }

    private func forgetFallbackLabel(_ u: Attributor.Unlearn) -> String {
        if case .rankedAssociation = u { return "✕ suppress that fallback too" }
        return "✕ forget that fallback too"
    }

    private func fallbackText(_ u: Attributor.Unlearn) -> String {
        let preview = controller.explainWithout(u, signal)
        let name = preview.chosen.map { controller.name(of: $0) } ?? "nothing"
        var text = "\(name) \(pct(preview.chosenScore))"
        // Forgetting the correction lands back on the displaced belief: name
        // that continuity, so the preview reads as history, not coincidence.
        if let prior = explanation.priorToCorrection, preview.chosen == prior.chosen {
            text += " – what it thought before your correction"
        }
        return text
    }

    /// "Apple 71% (learned)" — the displaced belief, with a plain word for
    /// where it came from (mirrors `becauseLabel`'s vocabulary, compressed).
    private func priorLabel(_ prior: AttributionExplanation.Prior) -> String {
        "\(controller.name(of: prior.chosen)) \(pct(prior.score)) (\(priorSourceWord(prior.source)))"
    }

    private func priorSourceWord(_ source: AttributionExplanation.Source) -> String {
        switch source {
        case .pin: return "pinned"
        case .sessionSticky: return "categorised earlier today"
        case .opTaskURL, .opTaskTitle: return "OP page"
        case .emailRule: return "learned rule"
        case .siteRule: return "learned site rule"
        case .pendingPrime: return "just-opened OP task"
        case .primedSurface: return "past correction"
        case .ranked: return "learned"
        case .none: return "nothing"
        }
    }

    // MARK: - sees: / candidates:

    private var seesSection: some View {
        Text("sees: " + seesLine).font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var seesLine: String {
        var parts = ["app \(signal.app)"]
        if let raw = signal.tabURL, let url = URL(string: raw), let urlHost = url.host {
            let sys = EmailSystem.detect(urlHost: urlHost)
            parts.append(sys == .unknown ? "site \(urlHost)" : "site \(urlHost) (\(sys.label))")
        } else if let title = signal.windowTitle {
            parts.append("title \(title)")
        }
        if hasEmailGrain {
            if let from = identity.segments.first(where: { $0.kind == .correspondent }) {
                parts.append("from " + (from.available ? from.display : "not captured"))
            }
            if let subj = identity.segments.first(where: { $0.kind == .subject }) {
                parts.append("subj " + (subj.available ? subj.display : "not captured"))
            }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var candidatesSection: some View {
        let items = candidateItems
        if !items.isEmpty {
            Text("candidates: " + items.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The top-ranked candidates — honestly labelled after a correction: the
    /// correction-born winner says so ("90% – your correction", the 90% is
    /// learned FROM the pick, not independent evidence), and the displaced
    /// belief is RETAINED at its pre-correction score instead of silently
    /// vanishing from the list (2026-07-05 report: Apple went from "71%
    /// certain" to gone entirely).
    private var candidateItems: [String] {
        let prior = explanation.priorToCorrection
        var items: [String] = explanation.lines
            .filter { line in prior.map { line.target != $0.chosen } ?? true }
            .prefix(3)
            .map { line in
                let entry = "\(controller.name(of: line.target)) \(pct(line.score))"
                return (prior != nil && line.target == explanation.chosen)
                    ? entry + " – your correction" : entry
            }
        if let prior {
            items.append("\(controller.name(of: prior.chosen)) \(pct(prior.score)) before your correction")
        }
        return items
    }

    // MARK: - WRONG? / grain ladder / fix

    private var wrongTaskSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Wrong? file as").font(.caption2).foregroundStyle(.secondary)
                TextField("filter tasks…", text: $filter)
                    .textFieldStyle(.roundedBorder).font(.caption2)
                    .onSubmit { pickFirstFiltered() }
            }
            if !filter.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(controller.searchTasks(filter).prefix(6), id: \.ref) { t in
                            Button { pickedTask = t; filter = "" } label: {
                                Text(t.subject).font(.caption2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 90)
                // No implicit animation on picking a row — the filtered list
                // swaps for the picked-task/grain-ladder block in the SAME
                // click, and an implicit height animation there was
                // "mangling" (glitching) whatever sits below it.
                .animation(nil, value: pickedTask)
            }
            if let picked = pickedTask {
                Text("→ \(picked.subject)").font(.caption).bold()
                    .fixedSize(horizontal: false, vertical: true)
                grainLadder(for: picked)
                HStack(spacing: 10) {
                    Button("Once") { commit(picked, pinned: nil) }
                        .font(.caption2).buttonStyle(.bordered)
                        .keyboardShortcut(.escape, modifiers: [])
                        .help("Just this once — today, this thread (⎋)")
                    Button("Remember") { commit(picked, pinned: false) }
                        .font(.caption2).buttonStyle(.bordered)
                        .keyboardShortcut(.return, modifiers: [])
                        .help("Remember at the selected grain — revisable, 95% (↵)")
                    Button("Always 📌") { commit(picked, pinned: true) }
                        .font(.caption2).buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .shift)
                        .help("Pin at the selected grain — standing law, 100% (⇧↵)")
                }
            }
        }
    }

    private func pickFirstFiltered() {
        if let first = controller.searchTasks(filter).first { pickedTask = first; filter = "" }
    }

    @ViewBuilder
    private func grainLadder(for task: WorkTask) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(identity.segments.enumerated()), id: \.offset) { i, seg in
                let count = i + 1
                Button {
                    guard seg.available else { return }
                    grainCount = count
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: grainCount == count ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 9))
                        // Wrap rather than truncate — long correspondents/
                        // subjects were clipping instead of reading in full.
                        Text(seg.display + correspondentCountSuffix(for: seg)).font(.caption2)
                            .fixedSize(horizontal: false, vertical: true)
                        if seg.shared {
                            Text("shared").font(.caption2).foregroundStyle(.orange)
                        }
                        if let conflict = conflictTarget(for: seg), conflict != task.ref {
                            Text("replaces \(controller.name(of: .task(conflict)))")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .foregroundColor(!seg.available ? Color.secondary.opacity(0.4) : .primary)
                }
                .buttonStyle(.plain)
                .disabled(!seg.available)
                .help(seg.available ? "Grain: \(seg.display)" : "not captured on this window")
                if seg.kind == .correspondent, grainCount == count, correspondentChoices.count > 1 {
                    correspondentCheckboxes
                }
            }
        }
        // No implicit animation on selecting a grain — clicking a row was
        // visibly disturbing the NEXT row (a height/reflow glitch) once rows
        // could wrap to more than one line.
        .animation(nil, value: grainCount)
        // ↑ / ↓ move the grain selection, skipping ghost rows — the same
        // stepping the pin editor uses for ←/→ (2026-07-03 spec §5.2).
        .focusable()
        .focused($ladderFocused)
        .onKeyPress(.upArrow) {
            grainCount = identity.steppedGrainCount(from: grainCount, narrower: false)
            return .handled
        }
        .onKeyPress(.downArrow) {
            grainCount = identity.steppedGrainCount(from: grainCount, narrower: true)
            return .handled
        }
        .onAppear { ladderFocused = true }
    }

    /// "+2" beside the correspondent row when the message has other
    /// counterparties (spec §5.5's "r.naismith@… +2" example) — the visible
    /// cue that checking the row expands to per-address checkboxes.
    private func correspondentCountSuffix(for seg: ContextIdentity.Segment) -> String {
        guard seg.kind == .correspondent, correspondentChoices.count > 1 else { return "" }
        return " +\(correspondentChoices.count - 1)"
    }

    /// The multi-correspondent expansion (spec §5.5, "later polish"): all
    /// counterparties as checkboxes, checked by default; Remember/Always
    /// then write one rule per checked address instead of `commitGrain`'s
    /// single rule for the primary correspondent.
    private var correspondentCheckboxes: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(correspondentChoices, id: \.self) { address in
                Toggle(isOn: Binding(
                    get: { correspondentChecks.contains(address) },
                    set: { on in
                        if on { correspondentChecks.insert(address) }
                        else { correspondentChecks.remove(address) }
                    }
                )) {
                    Text(address).font(.caption2).fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
            }
        }
        .padding(.leading, 14)
    }

    /// The task an existing UNPINNED rule at this grain already points to —
    /// the "replaces X" warning, for email AND site grains alike.
    private func conflictTarget(for segment: ContextIdentity.Segment) -> TaskRef? {
        if let level = segment.kind.emailMatchLevel {
            return controller.conflictingRule(level: level, value: segment.emailMatchValue)?.target
        }
        let host = signal.tabURL.flatMap { URL(string: $0)?.host?.lowercased() }
        if case .recipeField(let field) = segment.kind, let host,
           let recipe = SiteRecipes.recipe(forHost: host) {
            return controller.conflictingSiteRule(recipeID: recipe.id, field: field,
                                                  value: segment.value)?.target
        }
        if segment.kind == .urlHost, let host {
            return controller.conflictingSiteRule(recipeID: nil, field: SiteRule.siteField,
                                                  value: host)?.target
        }
        return nil
    }

    private func commit(_ task: WorkTask, pinned: Bool?) {
        onPick?(task)
        if let pinned {
            if isCorrespondentGrainSelected, correspondentChoices.count > 1 {
                controller.commitCorrespondentGrain(signal, chosen: correspondentChecks,
                                                    to: task.ref, pinned: pinned)
            } else {
                controller.commitGrain(identity, grainCount: grainCount, signal: signal,
                                       to: task.ref, pinned: pinned)
            }
        }
        pickedTask = nil
        filter = ""
    }

    private func pct(_ d: Double) -> String { String(format: "%.0f%%", d * 100) }
}
