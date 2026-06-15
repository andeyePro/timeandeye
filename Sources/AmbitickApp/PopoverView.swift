import SwiftUI
import AmbitickCore
import AmbitickMac

struct PopoverView: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow
    @State private var filter = ""
    @State private var note = ""
    @State private var changeMode = false

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
        // Edit a LOCAL copy and push to the controller without republishing
        // (a @Published binding would rebuild the popover each keystroke and
        // steal focus). Re-sync when tracking state changes (the controller
        // clears the note on task-switch/stop).
        .onChange(of: note) { _, new in controller.manualNote = new }
        .onChange(of: controller.trackerState) { _, _ in note = controller.manualNote }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .tracking = controller.trackerState {
                // Clicking the running task name drops down a list to CHANGE
                // it — relabels the current session (keeps its time) rather
                // than switching to a fresh one.
                Menu {
                    ForEach(controller.pickList(), id: \.ref) { task in
                        Button(task.subject) { controller.changeCurrentTask(to: task.ref) }
                    }
                    Divider()
                    Button("Search all tasks…") { changeMode = true }
                } label: {
                    HStack(spacing: 4) {
                        Text(controller.currentTaskName()).font(.headline).lineLimit(2)
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Text(controller.currentTaskName()).font(.headline).lineLimit(2)
            }
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
                    TextField("note…", text: $note)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .help("A note for this task's time — becomes the OpenProject comment")
                }
            } else {
                HStack {
                    Text("Not tracking")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let last = controller.lastTrackedTask() {
                        Button {
                            controller.userPicked(last)
                        } label: {
                            Label("Resume \(last.subject)", systemImage: "play.circle.fill")
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.green)
                        .font(.caption)
                        .help("Restart the clock on the last tracked task")
                    }
                }
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
                Text(changeMode ? "Change to (relabels current)" : "Switch to")
                    .font(.caption)
                    .foregroundStyle(changeMode ? Color.accentColor : .secondary)
                if changeMode {
                    Button { changeMode = false } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.plain).font(.caption2)
                }
                Spacer()
                TextField("filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .frame(width: 120)
            }
            // Default view: just the recent + likely picks (bounded by the
            // Settings counts). Typing the filter fuzzy-searches every task.
            let shown = filter.isEmpty ? controller.pickList() : controller.searchTasks(filter)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown, id: \.ref) { task in
                        taskRow(task)
                    }
                }
            }
            // Explicit height: an unconstrained ScrollView collapses to one
            // row inside the MenuBarExtra popover.
            .frame(height: min(CGFloat(max(shown.count, 1)) * 26, 240))
            if filter.isEmpty, !controller.taskCache.isEmpty {
                Text("type to search all \(controller.taskCache.count) tasks")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
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
            if changeMode {
                controller.changeCurrentTask(to: task.ref)
                changeMode = false
                filter = ""
            } else {
                controller.userPicked(task)
            }
        } label: {
            HStack {
                Text(task.subject).lineLimit(1)
                Spacer()
                Text(task.project.map { "\($0) · " } ?? "" )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                + Text(task.status)
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
                openWindow(id: "spent")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Image(systemName: "chart.pie")
            }
            .help("Time Spent – period breakdown")
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
