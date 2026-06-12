import SwiftUI
import AmbitickCore
import AmbitickMac

struct PopoverView: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow
    @State private var filter = ""

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
                    Button {
                        controller.userStopped()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Stop tracking")
                }
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("what are you doing? (becomes the OP comment)",
                              text: $controller.manualNote)
                        .textFieldStyle(.plain)
                        .font(.caption)
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
            HStack {
                Text("Switch to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 120)
            }
            let top = controller.pickList()
            let all = controller.fullPickList().filter {
                filter.isEmpty
                    || $0.subject.localizedCaseInsensitiveContains(filter)
                    || ($0.project?.localizedCaseInsensitiveContains(filter) ?? false)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(all.enumerated()), id: \.element.ref) { index, task in
                        if filter.isEmpty, index == top.count, index > 0 {
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
        HStack(spacing: 14) {
            Button {
                openWindow(id: "timeline")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "calendar.day.timeline.left")
            }
            .help("Timeline – today's tracked time")
            Button {
                openWindow(id: "review")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("\(controller.pendingReview.count)", systemImage: "tray.full")
            }
            .help("Review queue")
            Spacer()
            Button {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "xmark.circle")
            }
            .help("Quit Ambitick")
        }
        .buttonStyle(.plain)
        .font(.body)
        .foregroundStyle(.secondary)
    }
}
