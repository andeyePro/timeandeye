import SwiftUI
import AmbitickCore
import AmbitickMac

/// The low-certainty review queue: multi-select rows (click-drag, shift-click,
/// ⌘-click – native List selection), then one-click assign.
struct ReviewView: View {
    @ObservedObject var controller: AppController
    @State private var selection = Set<UUID>()
    @State private var aiResponse = ""
    @State private var aiStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(controller.pendingReview, selection: $selection) { segment in
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(segment.app)\(segment.windowTitle.map { " – \($0)" } ?? "")")
                            .lineLimit(1)
                        if let url = segment.tabURL {
                            Text(url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text(duration(segment))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(segment.start.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                }
                .tag(segment.id)
            }

            if !selection.isEmpty {
                assignBar
            }

            Divider()
            aiSection
        }
        .padding(10)
    }

    private var assignBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                Text("Assign \(selection.count):").font(.caption)
                Button("Do not track") { assign(.doNotTrack) }
                ForEach(controller.pickList(), id: \.ref) { task in
                    Button(task.subject) { assign(.task(task.ref)) }
                }
            }
        }
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
