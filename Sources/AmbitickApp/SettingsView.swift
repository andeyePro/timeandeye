import SwiftUI
import AmbitickCore
import AmbitickMac

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var newLocalName = ""
    @State private var newLocalLeisure = false

    var body: some View {
        Form {
            Section("OpenProject") {
                TextField("Instance URL", text: $controller.settings.opBaseURL,
                          prompt: Text("https://op.example.com"))
                SecureField("API key", text: $apiKey)
                HStack {
                    Button("Save key & connect") {
                        controller.saveAPIKey(apiKey)
                        apiKey = ""
                        keySaved = true
                    }
                    .disabled(apiKey.isEmpty || controller.settings.opBaseURL.isEmpty)
                    if keySaved { Text("Saved to Keychain").font(.caption).foregroundStyle(.secondary) }
                }
                if let error = controller.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else {
                    Text(controller.taskCache.isEmpty
                         ? "Not connected yet"
                         : "Connected as \(controller.connectedAs ?? "unknown user") – \(controller.taskCache.count) tasks loaded")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Default activity",
                       selection: Binding(
                        get: { controller.settings.defaultActivityID ?? -1 },
                        set: { controller.settings.defaultActivityID = $0 == -1 ? nil : $0 })) {
                    Text("–").tag(-1)
                    ForEach(controller.activities, id: \.id) { a in
                        Text(a.name).tag(a.id)
                    }
                }
            }

            Section("Auto-push") {
                let threshold = controller.settings.certaintyAutoPushThreshold
                Slider(value: $controller.settings.certaintyAutoPushThreshold, in: 0.5...1.01)
                Text(threshold > 1.0 ? "Never auto-push (review everything)"
                     : "Auto-push sessions ≥ \(Int((threshold * 100).rounded()))% certain")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Auto-comment time entries (apps/docs used)",
                       isOn: $controller.settings.autoComment)
                Text(controller.journalSummary)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                TextField("Low-certainty colour (hex)", text: $controller.settings.colourLow)
                TextField("High-certainty colour (hex)", text: $controller.settings.colourHigh)
                Text("Set both to the same colour to disable the signalling.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show certainty %", isOn: $controller.settings.showPercent)
            }

            Section("Local tasks (never sent to OpenProject)") {
                ForEach(controller.settings.localTasks) { task in
                    HStack {
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: controller.colour(for: .local(task.id))) },
                            set: { controller.setColour(NSColor($0), for: .local(task.id)) }))
                            .labelsHidden()
                            .frame(width: 28)
                        Text(task.name)
                        if task.isLeisure {
                            Text("leisure").font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .background(.quaternary, in: Capsule())
                        }
                        Spacer()
                        Button {
                            controller.removeLocalTask(task.id)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("new local task (e.g. Chess, Family admin)", text: $newLocalName)
                        .onSubmit(addLocal)
                    Toggle("leisure", isOn: $newLocalLeisure).toggleStyle(.checkbox)
                    Button { addLocal() } label: { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.plain)
                        .disabled(newLocalName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Leisure tasks catch confident non-work time when \"Track leisure\" is on; all local tasks appear in every pick list, the timeline and Time Spent.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Stepper("Switch buffer: \(Int(controller.settings.switchGraceSeconds))s",
                        value: $controller.settings.switchGraceSeconds, in: 0...120, step: 5)
                Text("A new window must hold focus this long before the task switches; briefer visits merge into the current task. (Restart to apply.)")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("System notifications (sounds still play when off)",
                       isOn: $controller.settings.systemNotifications)
                Toggle("Lock the Mac when I leave my desk (⌘⇧L)",
                       isOn: $controller.settings.lockOnLeave)
                Toggle("Track leisure to local-only tasks (instead of stopping)",
                       isOn: $controller.settings.trackLeisureLocally)
                Stepper("Recent tasks in popover: \(controller.settings.recentCount)",
                        value: $controller.settings.recentCount, in: 1...15)
                Stepper("Likely tasks in popover: \(controller.settings.likelyCount)",
                        value: $controller.settings.likelyCount, in: 1...15)
                Text("The menu-bar list shows this many recent + likely tasks; type in its filter to fuzzy-search the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .padding(8)
    }

    private func addLocal() {
        controller.addLocalTask(name: newLocalName, isLeisure: newLocalLeisure)
        newLocalName = ""
        newLocalLeisure = false
    }
}
