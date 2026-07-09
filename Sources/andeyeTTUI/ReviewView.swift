import SwiftUI
import andeyeTTCore
import andeyeTTMac

/// The low-certainty review queue: multi-select rows (click-drag, shift-click,
/// ⌘-click — native List selection), grouped by day, then one-click assign.
/// Assign to any task (fuzzy-filtered), to "Do not track", or create a new
/// local (non-OpenProject) task on the spot and assign to it.
struct ReviewView: View {
    @ObservedObject var controller: AppController
    @State private var selection = Set<UUID>()
    @State private var aiResponse = ""
    @State private var aiStatus = ""
    @State private var filter = ""
    @State private var newLocalName = ""
    /// The post-assign grain footer (2026-07-03 spec §5.3, "later polish"):
    /// what was just taught, mirroring `PopoverView`'s `justPicked` tuple.
    /// Ignoring it is "once" — it never blocks assigning the next segment.
    @State private var justAssigned: (task: WorkTask, signal: ActivitySignal, identity: ContextIdentity)?
    /// Multi-correspondent checkbox selection for the footer (spec §5.5) —
    /// all checked by default.
    @State private var correspondentChecks: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selection) {
                ForEach(daySections, id: \.title) { section in
                    Section {
                        ForEach(section.items) { segment in
                            row(segment).tag(segment.id)
                        }
                    } header: {
                        if let title = section.title { Text(title) }
                    }
                }
            }

            if !selection.isEmpty {
                assignBar
            }
            grainFooter

            Divider()
            aiSection
        }
        .padding(10)
    }

    /// Group by calendar day; a single header is omitted when everything is
    /// from one day (usually today).
    private var daySections: [(title: String?, items: [ReviewSegment])] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: controller.pendingReview) {
            cal.startOfDay(for: $0.start)
        }
        let days = grouped.keys.sorted()
        if days.count <= 1 {
            return [(nil, controller.pendingReview)]
        }
        return days.map { day in
            let title = cal.isDateInToday(day) ? "Today"
                : cal.isDateInYesterday(day) ? "Yesterday"
                : day.formatted(date: .abbreviated, time: .omitted)
            return (title, grouped[day]!.sorted { $0.start < $1.start })
        }
    }

    private func row(_ segment: ReviewSegment) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text("\(segment.app)\(segment.windowTitle.map { " – \($0)" } ?? "")")
                    .lineLimit(1)
                if let url = segment.tabURL {
                    Text(url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(duration(segment)).font(.caption).foregroundStyle(.secondary)
            Text(segment.start.formatted(date: .omitted, time: .shortened)).font(.caption)
        }
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

    private func assign(_ target: Target) {
        let ids = Array(selection)
        // Snapshot the rows being assigned BEFORE the assign, which removes
        // them from `pendingReview` — the footer's identity is built from
        // what was just taught, not what's left in the queue.
        let assigned = controller.pendingReview.filter { ids.contains($0.id) }
        controller.assignReview(ids, to: target)
        selection.removeAll()
        justAssigned = footerContext(for: assigned, target: target)
        correspondentChecks = justAssigned.map { Set(ContextIdentity.correspondentChoices($0.signal)) } ?? []
    }

    /// The post-assign footer's context, or nil unless EVERY just-assigned
    /// segment shares one email context (spec §5.3) — otherwise there's no
    /// single grain to offer. Mirrors `PopoverView.pick`'s
    /// `justPicked`-building gate (`isEmailGrain`), extended to require
    /// agreement across a multi-row assign.
    private func footerContext(for segments: [ReviewSegment], target: Target)
        -> (task: WorkTask, signal: ActivitySignal, identity: ContextIdentity)? {
        guard case .task(let ref) = target,
              let task = controller.taskCache.first(where: { $0.ref == ref }),
              let first = segments.first else { return nil }
        let identities = segments.map { controller.identity(of: controller.signal(for: $0)) }
        guard let shared = identities.first, identities.allSatisfy({ $0 == shared }),
              shared.segments.contains(where: { $0.kind.isEmailGrain }) else { return nil }
        return (task, controller.signal(for: first), shared)
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

    private func duration(_ s: ReviewSegment) -> String {
        let minutes = Int(s.end.timeIntervalSince(s.start) / 60)
        return minutes >= 1 ? "\(minutes)m" : "<1m"
    }
}
