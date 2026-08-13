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
        /// The window chip's own span end (timeline host), so the card can
        /// show how long this window actually ran. Nil on the popover's
        /// live card and on pre-span rows — the duration line is omitted then.
        var end: Date? = nil
        /// What decided it, as journalled at flush (the window's own span
        /// when it has one, else the slice's dominant decider) — nil on
        /// pre-provenance rows. With it, BECAUSE tells the original story
        /// verbatim; without it, the card falls back to anchoring only
        /// when today's re-derivation contradicts the record.
        var provenance: SessionProvenance? = nil
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
    /// A quiet "start – end · duration" caption for the window chip (timeline
    /// host), so the reader can see how long this window ran. Nil when the
    /// record carries no span end (popover live card / pre-span rows).
    private var recordedRanText: String? {
        guard let r = recorded, let end = r.end else { return nil }
        let secs = end.timeIntervalSince(r.at)
        let dur = MenuTitle.text(elapsed: secs, certainty: nil, showPercent: false)
        return "\(r.at.formatted(date: .omitted, time: .shortened)) – "
            + "\(end.formatted(date: .omitted, time: .shortened)) · \(dur)"
    }
    private var identity: ContextIdentity { controller.identity(of: signal) }
    private var hasEmailGrain: Bool { identity.segments.contains { $0.kind.isEmailGrain } }
    private var unlearn: Attributor.Unlearn? {
        // A card anchored on a recorded slice aims the ✕ at the store that
        // DECIDED that record (fix 3); the live popover card (recorded nil)
        // keeps today's ladder.
        controller.forgettable(for: signal,
                               recorded: recorded?.provenance,
                               recordedTarget: recorded?.target)
    }
    /// Every distinct counterparty on this message — more than one triggers
    /// the checkbox expansion instead of a plain correspondent row.
    private var correspondentChoices: [String] { ContextIdentity.correspondentChoices(signal) }
    private var isCorrespondentGrainSelected: Bool {
        grainCount >= 1 && grainCount <= identity.segments.count
            && identity.segments[grainCount - 1].kind == .correspondent
    }

    /// Timeline host only: "+ all" in the card's top-right (where Martin
    /// expects it) extends the strip selection to every window recorded
    /// with the same data. `count` = how many it would ADD; the button
    /// shows disabled at 0 so the affordance is always discoverable.
    var selectTwins: (count: Int, select: () -> Void)? = nil

    @State private var dataExpanded = false
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // His card: the window name wears a twisty (all the data
            // beneath), the standing line wears its own (details + the
            // forget/suppress controls). Everything default-closed; the
            // Move bar below the cards is the refile path — no button here.
            if host == .timeline {
                DisclosureGroup(isExpanded: $dataExpanded) {
                    dataSection.padding(.top, 2)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(signal.app)\(cleanTitle.map { " – \($0)" } ?? "")")
                            .font(.caption).bold().lineLimit(1)
                        if let ran = recordedRanText {
                            Text(ran)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.trailing, 40)
                }
            }
            DisclosureGroup(isExpanded: $detailsExpanded) {
                VStack(alignment: .leading, spacing: 2) {
                    if host == .popover { dataSection }
                    detailsSection
                }
                .padding(.top, 2)
            } label: {
                Text(standingLine).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if host == .popover, onPick != nil {
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
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                // Developer affordance only: visible in diagnostics mode
                // (Settings ▸ Diagnostics) — everyday UI stays uncluttered.
                if controller.settings.diagnosticsMode { copyCardButton }
                plusAllButton
            }
            .padding(2)
        }
    }

    @State private var cardCopied = false
    private var copyCardButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cardFactsAttributed.string, forType: .string)
            cardCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { cardCopied = false }
        } label: {
            Image(systemName: cardCopied ? "checkmark" : "doc.on.doc").font(.caption2)
        }
        .buttonStyle(.borderless)
        .help("Copy the whole card as text (diagnostics mode)")
    }


    @ViewBuilder private var plusAllButton: some View {
        if let selectTwins {
            Button(action: selectTwins.select) {
                Text("+ all").font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .disabled(selectTwins.count == 0)
            .padding(6)
            .help(selectTwins.count == 0
                  ? "No other windows in this slice carry the same app + title"
                  : "Also select the \(selectTwins.count) other window\(selectTwins.count == 1 ? "" : "s") recorded with the same app + title")
        }
    }

    /// One-click cure when the card KNOWS a better answer than the record
    /// (Martin, 2026-07-11: "no obvious single click that recategorises it
    /// correctly"): refile this window's time onto what today's rules say —
    /// the same path as picking it in the Wrong? strip, one click sooner.
    /// "= Time&I (95%) – you assigned it": what the time stands as and who
    /// decided it, in one line (his wording).
    private var standingLine: String {
        if let recorded {
            let decider = recorded.provenance.flatMap { provenanceLabel($0) }
                ?? (recordContradicted ? "decided earlier"
                    : shortSource(explanation.source))
            return "= \(controller.name(of: recorded.target)) \(pct(recorded.certainty)) – \(decider)"
        }
        let chosen = explanation.chosen.map { controller.name(of: $0) } ?? "—"
        return "= \(chosen) \(pct(explanation.chosenScore)) – \(shortSource(explanation.source))"
    }

    private func shortSource(_ source: AttributionExplanation.Source) -> String {
        switch source {
        case .pin: return "you pinned it"
        case .sessionSticky: return "you categorised this today"
        case .opTaskURL: return "the task's page is open"
        case .opTaskTitle: return "the task's id is in the title"
        case .emailRule: return "a learned rule"
        case .siteRule: return "a learned site rule"
        case .pendingPrime: return "a just-opened task"
        case .primedSurface: return "remembered from a past correction"
        case .ranked: return "learned associations + priors"
        case .none: return "nothing matched"
        }
    }

    /// Under the window-name twisty: everything the app captured.
    @ViewBuilder private var dataSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("sees: " + seesLine).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let items = candidateItems
            if !items.isEmpty {
                Text("candidates: " + items.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Under the standing line's twisty: the decision's full story and the
    /// forget/suppress controls.
    @ViewBuilder private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if recordContradicted {
                Text("today's rules would say: \(becauseLabel) – not what decided this slice")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
            if let surface = explanation.matchedSurface {
                Text(surfaceProvenance(surface))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            unlearnSection
        }
    }

    /// Everything the card STATES, as one attributed string rendered by a
    /// single native selectable label — one click-drag selects and copies
    /// the whole card (SwiftUI Text concatenation still selected in pieces
    /// — Martin, 2026-07-11). The forget preview line lives HERE so it
    /// copies too; the buttons beneath stay actions-only.
    private var cardFactsAttributed: NSAttributedString {
        let caption = NSFont.systemFont(ofSize: 11)
        let caption2 = NSFont.systemFont(ofSize: 10)
        let bold = NSFont.boldSystemFont(ofSize: 11)
        let out = NSMutableAttributedString()
        func add(_ text: String, _ font: NSFont, _ colour: NSColor) {
            out.append(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: colour]))
        }
        if host == .timeline {
            add("\(signal.app)\(cleanTitle.map { " – \($0)" } ?? "")\n", bold, .labelColor)
        }
        add(standingLine, caption, .labelColor)
        if recordContradicted {
            add("\ntoday's rules would say: \(becauseLabel) – not what decided this slice",
                caption2, .secondaryLabelColor)
        }
        if let prior = explanation.priorToCorrection {
            add("\nbefore your correction: \(priorLabel(prior))", caption2, .secondaryLabelColor)
        }
        if let rule = explanation.matchedEmailRule {
            add("\n" + ruleProvenance(rule), caption2, .secondaryLabelColor)
        }
        if let rule = explanation.matchedSiteRule {
            add("\n" + siteRuleProvenance(rule), caption2, .secondaryLabelColor)
        }
        if let pin = explanation.matchedPin {
            add("\n📌 \(pin.rule.shortLabel)", caption2, .secondaryLabelColor)
        }
        if let surface = explanation.matchedSurface {
            add("\n" + surfaceProvenance(surface), caption2, .secondaryLabelColor)
        }
        if let u = unlearn {
            add("\nforgetting would fall back to: \(fallbackText(u))",
                caption2, .tertiaryLabelColor)
        }
        add("\nsees: " + seesLine, caption2, .secondaryLabelColor)
        let items = candidateItems
        if !items.isEmpty {
            add("\ncandidates: " + items.joined(separator: " · "), caption2, .tertiaryLabelColor)
        }
        return out
    }

    /// The best identity the card HOLDS for its header: the window title,
    /// else the site host from the tab URL. "Google Chrome" alone told
    /// Martin nothing about how to recategorise a slice whose URL the app
    /// knew perfectly well (2026-07-11, the 15:57 10-Jul companies-house
    /// window) — never show less than what the sees line already knows.
    private var cleanTitle: String? {
        if let title = signal.windowTitle, !title.isEmpty { return title }
        if let raw = signal.tabURL, let url = URL(string: raw), let host = url.host {
            return host
        }
        return nil
    }

    // MARK: - Unlearn controls (the card's facts live in `cardFacts`)

    @ViewBuilder
    private var unlearnSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let u = unlearn {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top, spacing: 6) {
                        Button { controller.forget(u, signal: signal) } label: {
                            Text(forgetLabel(u)).font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove exactly what fired here")
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
                        // Same grey as its sibling forget control — the
                        // orange accent read as an alert amid an otherwise
                        // grey card (Martin, twice, + 2026-07-11).
                        .foregroundStyle(.secondary)
                        .help("Also remove the fallback itself, so it's never offered again")
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


    /// The journalled decider, in the card's voice. Unknown raw values (a
    /// future source this build doesn't know) return nil → "decided earlier".
    private func provenanceLabel(_ p: SessionProvenance) -> String? {
        switch p.sourceRaw {
        case "pin": return "you pinned it"
        case "sessionSticky": return "you categorised this context that day"
        case "opTaskURL": return "the task's page was open"
        case "opTaskTitle": return "the task's id was in the title"
        case "emailRule":
            return p.detail.map { "a learned rule fired (✉ \($0))" } ?? "a learned rule fired"
        case "siteRule":
            return p.detail.map { "a learned site rule fired (\($0))" } ?? "a learned site rule fired"
        case "pendingPrime": return "a just-opened task primed it"
        case "primedSurface": return "remembered from a past correction"
        case "ranked":
            return p.detail.map { "learned associations + priors (\($0))" }
                ?? "learned associations + priors"
        case "userAssigned": return "you assigned it"
        case "aiApplied": return "an AI suggestion you applied"
        case "resumed": return "resumed after an idle stop"
        case "retro": return "confidence reached your bar (retro pass)"
        default: return nil
        }
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
