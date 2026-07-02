import SwiftUI
import AmbitickCore

/// The whole app on one screen (spec: two-tap tracking — open app, tap task).
/// Current task pinned on top with its live clock; the ranked list below;
/// filter, quick local-task creation, settings and export in the toolbar.
struct NowView: View {
    @ObservedObject var controller: PhoneController
    @State private var filter = ""
    @State private var newTaskName = ""
    @State private var showSettings = false
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        NavigationStack {
            List {
                if let live = controller.tracking {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(controller.name(of: live.task))
                                .font(.title2).bold()
                            Text(elapsed(since: live.since))
                                .font(.system(.largeTitle, design: .rounded).monospacedDigit())
                            Button(role: .destructive) {
                                controller.stop()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
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
            .navigationTitle("andeye")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: controller.timesheetCSV(),
                              preview: SharePreview("andeye timesheet (7 days).csv")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                PhoneSettingsView(controller: controller)
            }
            .refreshable { await controller.refreshTasks() }
            .onReceive(clock) { now = $0 }
        }
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
