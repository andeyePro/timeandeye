import SwiftUI
import timeandeyeCore
import timeandeyePhone

/// The whole app on one screen (spec: two-tap tracking — open app, tap task).
/// Current task pinned on top with its live clock and a small stop control
/// (matching the Mac popover's compact feel); the ranked list below; filter
/// and quick local-task creation inline. The toolbar holds a LIVE mini-pie
/// (opens the Time page) and a hamburger menu (Settings, timesheet share).
/// Tapping a task SWITCHES (stop + start); tapping the tracked task is a
/// no-op; long-press a row to re-label the running timer instead.
struct NowView: View {
    @ObservedObject var controller: PhoneController
    @State private var filter = ""
    @State private var newTaskName = ""
    @State private var showSettings = false
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()
    @State private var miniNodes: [TimeAggregator.Node] = []
    @State private var miniReloadedAt = Date.distantPast

    var body: some View {
        NavigationStack {
            List {
                if let live = controller.tracking {
                    Section {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(controller.name(of: live.task))
                                    .font(.headline).lineLimit(2)
                                Text(elapsed(since: live.since))
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                controller.stop()
                            } label: {
                                Image(systemName: "stop.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Stop tracking")
                        }
                    } header: {
                        Text("Tracking now · today \(short(controller.todaysTotal()))")
                    }
                } else {
                    Section {
                        Text("Not tracking — tap a task to start")
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Today \(short(controller.todaysTotal()))")
                    }
                }

                Section("Tasks") {
                    ForEach(controller.pickList(filter: filter), id: \.ref.storageKey) { task in
                        Button {
                            controller.start(task.ref)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(task.subject)
                                    if let project = task.project {
                                        Text(project).font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if task.isLocalOnly {
                                    Image(systemName: "house")
                                        .foregroundStyle(.secondary)
                                }
                                if controller.tracking?.task == task.ref {
                                    Image(systemName: "record.circle.fill")
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        .tint(.primary)
                        .contextMenu {
                            if let live = controller.tracking, live.task != task.ref {
                                Button {
                                    controller.relabelCurrent(to: task.ref)
                                } label: {
                                    Label("Re-label current timer as this",
                                          systemImage: "pencil.line")
                                }
                            }
                        }
                    }
                    HStack {
                        TextField("New local task…", text: $newTaskName)
                        Button("Add") {
                            let ref = controller.addLocalTask(name: newTaskName)
                            newTaskName = ""
                            controller.start(ref)
                        }
                        .disabled(newTaskName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                if let error = controller.lastError {
                    Section { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .searchable(text: $filter, prompt: "Filter tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SpentPhoneView(controller: controller)
                    } label: {
                        MiniPieIcon(nodes: miniNodes,
                                    overrides: controller.settings.taskColours)
                    }
                    .accessibilityLabel("Time pie")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showSettings = true } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        ShareLink(item: controller.timesheetCSV(),
                                  preview: SharePreview("andeye timesheet (7 days).csv")) {
                            Label("Share timesheet (7 days)", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                PhoneSettingsView(controller: controller)
            }
            .refreshable { await controller.refreshTasks() }
            .onReceive(clock) {
                now = $0
                // The mini-pie is LIVE but its proportions move slowly — a
                // journal query per second would be waste (the Mac learnt
                // that lesson); every 30 s is imperceptible at 24 pt.
                if now.timeIntervalSince(miniReloadedAt) >= 30 { reloadMini() }
            }
            .onChange(of: controller.tracking?.task) { _, _ in reloadMini() }
            .onAppear { reloadMini() }
        }
    }

    private func reloadMini() {
        let start = Calendar.current.startOfDay(for: Date())
        miniNodes = controller.spentNodes(from: start, to: Date())
        miniReloadedAt = Date()
    }

    private func elapsed(since: Date) -> String {
        let s = Int(now.timeIntervalSince(since))
        return s < 3600 ? String(format: "%d:%02d", s / 60, s % 60)
                        : String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    private func short(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }
}

/// OP connection + the handful of knobs that matter on the phone.
struct PhoneSettingsView: View {
    @ObservedObject var controller: PhoneController
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("OpenProject") {
                    TextField("Instance URL", text: $controller.settings.opBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("API key", text: $apiKey)
                    Button("Connect") {
                        if !apiKey.isEmpty {
                            controller.saveAPIKey(apiKey)
                            apiKey = ""
                        } else {
                            Task { await controller.refreshTasks() }
                        }
                    }
                    if let who = controller.connectedAs {
                        Text("Connected as \(who)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("iCloud sync between your Mac and this phone arrives with the App Store build. Everything here is stored on-device; slices you track push straight to your backend.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
