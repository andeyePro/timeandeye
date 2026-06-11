import SwiftUI
import AmbitickCore
import AmbitickMac

struct PopoverView: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            promptSection
            switchList
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 300)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(controller.currentTaskName())
                .font(.headline)
                .lineLimit(2)
            if case .tracking(_, let certainty) = controller.trackerState {
                HStack {
                    Text("\(controller.menuText)  ·  \(Int((certainty * 100).rounded()))% certain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { controller.userStopped() }
                }
            } else {
                Text("Not tracking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var promptSection: some View {
        if case .resumeAfterIdle(let stoppedAt)? = controller.lastPrompt {
            VStack(alignment: .leading, spacing: 6) {
                Text("Stopped at \(stoppedAt.formatted(date: .omitted, time: .shortened)) (idle). Work continued?")
                    .font(.caption)
                HStack {
                    Button("Stop time was correct") { controller.userPostponed() }
                    Button("Pick task below to resume") { }
                        .disabled(true)
                        .buttonStyle(.plain)
                        .font(.caption2)
                }
            }
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var switchList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Switch to")
                .font(.caption)
                .foregroundStyle(.secondary)
            let top = controller.pickList()
            let all = controller.fullPickList()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(all.enumerated()), id: \.element.ref) { index, task in
                        if index == top.count, index > 0 {
                            Divider()   // recent+likely above, the long tail below
                        }
                        taskRow(task)
                    }
                }
            }
            // Explicit height: an unconstrained ScrollView collapses to one
            // row inside the MenuBarExtra popover.
            .frame(height: min(CGFloat(max(all.count, 1)) * 26, 240))
            if controller.taskCache.isEmpty {
                Text("No tasks yet – set OP URL + API key in Settings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let error = controller.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
        }
    }

    private func taskRow(_ task: WorkTask) -> some View {
        Button {
            controller.userPicked(task)
        } label: {
            HStack {
                Text(task.subject).lineLimit(1)
                Spacer()
                Text(task.status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack {
            Button("Review (\(controller.pendingReview.count))") {
                openWindow(id: "review")
                NSApp.activate(ignoringOtherApps: true)
            }
            Spacer()
            Button("Settings") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .font(.caption)
    }
}
