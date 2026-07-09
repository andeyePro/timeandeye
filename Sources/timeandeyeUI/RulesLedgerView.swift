import SwiftUI
import timeandeyeCore
import timeandeyeMac

/// The audit surface for every learned + pinned rule (2026-07-03
/// context-rules spec §5.3 + §6 later polish — list + provenance + delete,
/// a row-click disclosure in the Evidence Card's anatomy, per-group bulk
/// forget (one undo for the whole act), and a plain-text "Copy rules"
/// export). Two segments since the 2026-07-09 site-recipes spec §6: Email
/// (EmailRule) and Sites (SiteRule + the per-recipe capture toggles strip —
/// the recipes' privacy-legibility surface).
struct RulesLedgerView: View {
    enum Segment: String, CaseIterable { case email = "Email", sites = "Sites" }

    @ObservedObject var controller: AppController
    @State private var segment: Segment = .email
    @State private var search = ""
    // Row delete is a two-step affordance: confirm before removing (it's easy
    // to misclick in a dense list), then an on-screen Undo right after — ⌘Z
    // alone wasn't discoverable enough (Martin's hardware-test feedback,
    // 2026-07-06: the delete control existed but he "could not find it"). A
    // pending/just-deleted BATCH (one row, or a whole group) shares this same
    // confirm→undo shape so bulk forget gets it for free.
    @State private var pendingDelete: [EmailRule]?
    @State private var justDeleted: [EmailRule]?
    // The Sites segment's parallel confirm→undo states (parallel rule type,
    // parallel states — the shared-protocol refactor is a later pass).
    @State private var pendingSiteDelete: [SiteRule]?
    @State private var justDeletedSites: [SiteRule]?
    // Undo-stack depth captured at delete time. controller.undo() is a
    // global LIFO pop, so the banner's Undo is only safe while our delete
    // is still the top entry - any later undoable action elsewhere in the
    // app retires the banner instead of letting it undo the wrong thing.
    @State private var undoCountAtDelete = 0
    // Which rows are expanded into their compact detail disclosure (keyed by
    // `ruleKey` — EmailRule isn't Identifiable, and metadata like fireCount
    // must not change a row's identity while it's expanded).
    @State private var expanded: Set<String> = []
    @State private var rulesCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("search rules…", text: $search)
                    .textFieldStyle(.roundedBorder)
                Button("Copy rules") {
                    controller.copyToClipboard(segment == .email
                        ? controller.rulesExportText() : controller.siteRulesExportText())
                    rulesCopied = true
                }
                if rulesCopied {
                    Text("Copied").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            switch segment {
            case .email: emailSegment
            case .sites: sitesSegment
            }
            if let deleted = justDeleted {
                HStack(spacing: 6) {
                    Text(deletedBannerText(deleted))
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("Undo") {
                        controller.undo()
                        justDeleted = nil
                    }
                    .font(.caption2).buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .onChange(of: controller.undoCount) { _, new in
                    // Another action registered (or undo ran) elsewhere:
                    // our delete is no longer top of the stack, so Undo
                    // here would pop the wrong action. Retire the banner.
                    if new != undoCountAtDelete { justDeleted = nil }
                }
            }
            if let deleted = justDeletedSites {
                HStack(spacing: 6) {
                    Text(deletedSiteBannerText(deleted))
                        .font(.caption2).foregroundStyle(.secondary)
                    Button("Undo") {
                        controller.undo()
                        justDeletedSites = nil
                    }
                    .font(.caption2).buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
                .onChange(of: controller.undoCount) { _, new in
                    if new != undoCountAtDelete { justDeletedSites = nil }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .textSelection(.enabled)
        .confirmationDialog(pendingDelete.map { $0.count > 1 ? "Forget \($0.count) rules?" : "Forget this rule?" }
            ?? "Forget this rule?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ), presenting: pendingDelete) { rules in
            Button("Forget", role: .destructive) {
                controller.deleteRules(rules)
                justDeleted = rules
                undoCountAtDelete = controller.undoCount
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { rules in
            Text(confirmMessage(rules))
        }
        .confirmationDialog(pendingSiteDelete.map { $0.count > 1 ? "Forget \($0.count) rules?" : "Forget this rule?" }
            ?? "Forget this rule?",
            isPresented: Binding(
                get: { pendingSiteDelete != nil },
                set: { if !$0 { pendingSiteDelete = nil } }
            ), presenting: pendingSiteDelete) { rules in
            Button("Forget", role: .destructive) {
                controller.deleteSiteRules(rules)
                justDeletedSites = rules
                undoCountAtDelete = controller.undoCount
                pendingSiteDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingSiteDelete = nil }
        } message: { rules in
            Text(confirmSiteMessage(rules))
        }
    }

    // MARK: - Email segment (unchanged behaviour)

    @ViewBuilder
    private var emailSegment: some View {
        let groups = controller.rulesLedger(search: search)
        if groups.isEmpty {
            Text(search.isEmpty ? "No email rules learned or pinned yet."
                                 : "No rules match “\(search)”.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            Spacer()
        } else {
            List {
                ForEach(groups, id: \.target) { group in
                    Section(header: groupHeader(group)) {
                        ForEach(Array(group.rows.enumerated()), id: \.offset) { _, rule in
                            ruleRow(rule)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sites segment (site-recipes spec §6)

    @ViewBuilder
    private var sitesSegment: some View {
        recipeStrip
        let groups = controller.siteRulesLedger(search: search)
        if groups.isEmpty {
            Text(search.isEmpty ? "No site rules learned or pinned yet."
                                 : "No rules match “\(search)”.")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10)
            Spacer()
        } else {
            List {
                ForEach(groups, id: \.target) { group in
                    Section(header: siteGroupHeader(group)) {
                        ForEach(Array(group.rows.enumerated()), id: \.offset) { _, rule in
                            siteRuleRow(rule)
                        }
                    }
                }
            }
        }
    }

    /// The per-recipe capture toggles — the recipes' privacy-legibility
    /// surface (spec §8). Turning one off stops extraction immediately; its
    /// rules stay listed (greyed, dormant) — deleting a user's rules because
    /// a toggle flipped would be data loss.
    private var recipeStrip: some View {
        HStack(spacing: 14) {
            Text("Recipes").font(.caption).foregroundStyle(.secondary)
            ForEach(SiteRecipes.builtIn, id: \.id) { recipe in
                Toggle(recipe.label, isOn: Binding(
                    get: { !controller.settings.siteRecipesDisabled.contains(recipe.id) },
                    set: { on in
                        var disabled = controller.settings.siteRecipesDisabled
                        disabled.removeAll { $0 == recipe.id }
                        if !on { disabled.append(recipe.id) }
                        controller.settings.siteRecipesDisabled = disabled
                    }))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .help("Read URL + window title on \(recipe.hosts.joined(separator: ", ")) into named fields. Off = the recipe extracts nothing and its rules go dormant (kept, not deleted).")
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    private func confirmMessage(_ rules: [EmailRule]) -> String {
        guard rules.count > 1 else {
            let rule = rules[0]
            return "“\(rule.value.isEmpty ? "any mail" : rule.value)” → \(controller.name(of: .task(rule.target))). Undoable right after (⌘Z)."
        }
        return "All \(rules.count) rules for \(controller.name(of: .task(rules[0].target))). Undoable right after (⌘Z), as one step."
    }

    private func deletedBannerText(_ deleted: [EmailRule]) -> String {
        guard deleted.count > 1 else {
            let rule = deleted[0]
            return "Deleted “\(rule.value.isEmpty ? "any mail" : rule.value)”."
        }
        return "Deleted \(deleted.count) rules."
    }

    @ViewBuilder
    private func groupHeader(_ group: RulesLedgerGroup) -> some View {
        HStack {
            Text(controller.name(of: .task(group.target)))
            Spacer()
            // Only worth its own button once there's more than one row —
            // a single-rule group already has the per-row trash icon.
            if group.rows.count > 1 {
                Button("Forget all") { pendingDelete = group.rows }
                    .font(.caption2).buttonStyle(.borderless)
                    .help("Forget all \(group.rows.count) rules for this task (undoable, ⌘Z)")
            }
        }
    }

    private func ruleRow(_ rule: EmailRule) -> some View {
        let key = ruleKey(rule)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: rule.pinned ? "pin.fill" : "envelope")
                    .foregroundStyle(rule.pinned ? AndeyeColors.highlight : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(rule.level.label): \(rule.value.isEmpty ? "any mail" : rule.value)")
                        .font(.callout)
                    Text(provenance(rule)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                // Always visible (never hover-gated) — a dense list makes a
                // hover-only control easy to miss entirely.
                Button { pendingDelete = [rule] } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .help("Forget this rule — confirms first, then undoable (⌘Z)")
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
            }
            if expanded.contains(key) {
                ruleDetail(rule)
            }
        }
    }

    /// The row's click-to-expand disclosure — a live, signal-anchored
    /// `EvidenceCardView` doesn't fit here (a ledger rule has no live signal
    /// to explain), so this is a compact echo of the same anatomy: the
    /// provenance sentence, fire stats and grain/target, spelled out in full
    /// rather than the row's compressed caption (2026-07-03 spec §6, "row
    /// opens the Evidence Card").
    private func ruleDetail(_ rule: EmailRule) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(originSentence(rule)).fixedSize(horizontal: false, vertical: true)
            Text(fireSentence(rule))
            Text("Grain: \(rule.level.label) · target: \(controller.name(of: .task(rule.target)))")
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.leading, 24)
    }

    private func originSentence(_ rule: EmailRule) -> String {
        let when = rule.createdAt != .distantPast
            ? rule.createdAt.formatted(date: .abbreviated, time: .omitted) : nil
        switch rule.origin {
        case .correction:
            return when.map { "learned \($0) from your correction" } ?? "learned from your correction"
        case .card:
            return when.map { "learned \($0) from the Evidence Card" } ?? "learned from the Evidence Card"
        case .ledger:
            return when.map { "added \($0) from this ledger" } ?? "added from this ledger"
        case .migrated:
            return "migrated from an earlier version"
        }
    }

    private func fireSentence(_ rule: EmailRule) -> String {
        var text = "fired \(rule.fireCount)×"
        if let last = rule.lastFired {
            text += " · last \(last.formatted(date: .abbreviated, time: .omitted))"
        }
        return text
    }

    /// A stable-enough identity for the disclosure's expanded-set — matches
    /// `EmailRule.sameRule(as:)`'s notion of "the same rule" so a fireCount
    /// bump elsewhere never collapses an open row.
    private func ruleKey(_ rule: EmailRule) -> String {
        "\(rule.level.rawValue)|\(rule.value.lowercased())|\(rule.target)|\(rule.pinned)"
    }

    // MARK: - Site rows (parallel to the email rows above)

    @ViewBuilder
    private func siteGroupHeader(_ group: SiteRulesLedgerGroup) -> some View {
        HStack {
            Text(controller.name(of: .task(group.target)))
            Spacer()
            if group.rows.count > 1 {
                Button("Forget all") { pendingSiteDelete = group.rows }
                    .font(.caption2).buttonStyle(.borderless)
                    .help("Forget all \(group.rows.count) rules for this task (undoable, ⌘Z)")
            }
        }
    }

    /// True when the rule's recipe is toggled off: the rule is kept and
    /// listed but fires on nothing — greyed, not hidden (spec §8).
    private func isDormant(_ rule: SiteRule) -> Bool {
        guard let recipeID = rule.recipeID else { return false }   // host rules never sleep
        return controller.settings.siteRecipesDisabled.contains(recipeID)
    }

    private func siteRuleRow(_ rule: SiteRule) -> some View {
        let key = siteRuleKey(rule)
        let dormant = isDormant(rule)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: rule.pinned ? "pin.fill" : "globe")
                    .foregroundStyle(rule.pinned ? AndeyeColors.highlight : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(rule.grainLabel): \(rule.value)")
                        .font(.callout)
                    Text(siteProvenance(rule) + (dormant ? " · recipe off — dormant" : ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button { pendingSiteDelete = [rule] } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .help("Forget this rule — confirms first, then undoable (⌘Z)")
            }
            .opacity(dormant ? 0.5 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
            }
            if expanded.contains(key) {
                siteRuleDetail(rule)
            }
        }
    }

    private func siteRuleDetail(_ rule: SiteRule) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(siteOriginSentence(rule)).fixedSize(horizontal: false, vertical: true)
            Text(fireSentenceText(fireCount: rule.fireCount, lastFired: rule.lastFired))
            Text("Grain: \(rule.grainLabel) · target: \(controller.name(of: .task(rule.target)))")
        }
        .font(.caption2).foregroundStyle(.secondary)
        .padding(.leading, 24)
    }

    private func siteOriginSentence(_ rule: SiteRule) -> String {
        let when = rule.createdAt != .distantPast
            ? rule.createdAt.formatted(date: .abbreviated, time: .omitted) : nil
        switch rule.origin {
        case .correction:
            return when.map { "learned \($0) from your correction" } ?? "learned from your correction"
        case .card:
            return when.map { "learned \($0) from the Evidence Card" } ?? "learned from the Evidence Card"
        case .ledger:
            return when.map { "added \($0) from this ledger" } ?? "added from this ledger"
        case .migrated:
            return "migrated from an earlier version"
        }
    }

    private func fireSentenceText(fireCount: Int, lastFired: Date?) -> String {
        var text = "fired \(fireCount)×"
        if let lastFired {
            text += " · last \(lastFired.formatted(date: .abbreviated, time: .omitted))"
        }
        return text
    }

    private func siteRuleKey(_ rule: SiteRule) -> String {
        "site|\(rule.recipeID ?? "")|\(rule.field)|\(rule.value.lowercased())|\(rule.target)|\(rule.pinned)"
    }

    private func siteProvenance(_ rule: SiteRule) -> String {
        var parts = [rule.pinned ? "pinned" : "learned"]
        if rule.createdAt != .distantPast {
            parts.append(rule.createdAt.formatted(date: .abbreviated, time: .omitted))
        }
        parts.append("fired \(rule.fireCount)×")
        if let last = rule.lastFired {
            parts.append("last \(last.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }

    private func confirmSiteMessage(_ rules: [SiteRule]) -> String {
        guard rules.count > 1 else {
            let rule = rules[0]
            return "“\(rule.value)” → \(controller.name(of: .task(rule.target))). Undoable right after (⌘Z)."
        }
        return "All \(rules.count) rules for \(controller.name(of: .task(rules[0].target))). Undoable right after (⌘Z), as one step."
    }

    private func deletedSiteBannerText(_ deleted: [SiteRule]) -> String {
        guard deleted.count > 1 else {
            return "Deleted “\(deleted[0].value)”."
        }
        return "Deleted \(deleted.count) rules."
    }

    private func provenance(_ rule: EmailRule) -> String {
        var parts = [rule.pinned ? "pinned" : "learned"]
        if rule.createdAt != .distantPast {
            parts.append(rule.createdAt.formatted(date: .abbreviated, time: .omitted))
        }
        parts.append("fired \(rule.fireCount)×")
        if let last = rule.lastFired {
            parts.append("last \(last.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }
}
