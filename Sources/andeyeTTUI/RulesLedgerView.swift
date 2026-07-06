import SwiftUI
import andeyeTTCore
import andeyeTTMac

/// The audit surface for every learned + pinned email rule (2026-07-03
/// context-rules spec §5.3 — this phase covers list + provenance + delete;
/// search-by-last-5-matches, bulk actions, export and "row opens the Evidence
/// Card" are later polish, §6).
struct RulesLedgerView: View {
    @ObservedObject var controller: AppController
    @State private var search = ""
    // Row delete is a two-step affordance: confirm before removing (it's easy
    // to misclick in a dense list), then an on-screen Undo right after — ⌘Z
    // alone wasn't discoverable enough (Martin's hardware-test feedback,
    // 2026-07-06: the delete control existed but he "could not find it").
    @State private var pendingDelete: EmailRule?
    @State private var justDeleted: EmailRule?
    // Undo-stack depth captured at delete time. controller.undo() is a
    // global LIFO pop, so the banner's Undo is only safe while our delete
    // is still the top entry - any later undoable action elsewhere in the
    // app retires the banner instead of letting it undo the wrong thing.
    @State private var undoCountAtDelete = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("search rules…", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
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
                        Section(header: Text(controller.name(of: .task(group.target)))) {
                            ForEach(Array(group.rows.enumerated()), id: \.offset) { _, rule in
                                ruleRow(rule)
                            }
                        }
                    }
                }
            }
            if let deleted = justDeleted {
                HStack(spacing: 6) {
                    Text("Deleted “\(deleted.value.isEmpty ? "any mail" : deleted.value)”.")
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
        }
        .frame(minWidth: 420, minHeight: 320)
        .textSelection(.enabled)
        .confirmationDialog("Forget this rule?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { rule in
            Button("Forget", role: .destructive) {
                controller.deleteRule(rule)
                justDeleted = rule
                undoCountAtDelete = controller.undoCount
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { rule in
            Text("“\(rule.value.isEmpty ? "any mail" : rule.value)” → \(controller.name(of: .task(rule.target))). Undoable right after (⌘Z).")
        }
    }

    private func ruleRow(_ rule: EmailRule) -> some View {
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
            Button { pendingDelete = rule } label: { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help("Forget this rule — confirms first, then undoable (⌘Z)")
        }
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
