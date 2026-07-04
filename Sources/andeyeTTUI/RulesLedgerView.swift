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
        }
        .frame(minWidth: 420, minHeight: 320)
        .textSelection(.enabled)
    }

    private func ruleRow(_ rule: EmailRule) -> some View {
        HStack {
            Image(systemName: rule.pinned ? "pin.fill" : "envelope")
                .foregroundStyle(rule.pinned ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(rule.level.label): \(rule.value.isEmpty ? "any mail" : rule.value)")
                    .font(.callout)
                Text(provenance(rule)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { controller.deleteRule(rule) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.plain)
                .help("Forget this rule (undoable, ⌘Z)")
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
