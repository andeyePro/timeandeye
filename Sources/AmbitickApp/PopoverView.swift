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
            ForEach(controller.pickList(), id: \.ref) { task in
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
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
            if controller.taskCache.isEmpty {
                Text("No tasks yet – set OP URL + API key in Settings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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
