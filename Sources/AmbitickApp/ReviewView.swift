import SwiftUI
import AmbitickCore
import AmbitickMac

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
                Button("Do not track") { assign(.doNotTrack) }
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
        let ref = controller.addLocalTask(name: name, isLeisure: false)
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
                Button("Apply pasted response") {
                    aiStatus = controller.ingestAIResponse(aiResponse)
                    aiResponse = ""
                }
                .disabled(aiResponse.isEmpty)
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
        controller.assignReview(Array(selection), to: target)
        selection.removeAll()
    }

    private func duration(_ s: ReviewSegment) -> String {
        let minutes = Int(s.end.timeIntervalSince(s.start) / 60)
        return minutes >= 1 ? "\(minutes)m" : "<1m"
    }
}
