import SwiftUI
import AmbitickCore
import AmbitickMac

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var newLocalName = ""
    @State private var newLocalProject = ""

    var body: some View {
        Form {
            Section("OpenProject") {
                TextField("Instance URL", text: $controller.settings.opBaseURL,
                          prompt: Text("https://op.example.com"))
                    .textFieldStyle(.roundedBorder)
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save key & connect") {
                        controller.saveAPIKey(apiKey)
                        apiKey = ""
                        keySaved = true
                    }
                    .disabled(apiKey.isEmpty || controller.settings.opBaseURL.isEmpty)
                    if keySaved { Text("Saved").font(.caption).foregroundStyle(.secondary) }
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
            Section("Comments") {
                Toggle("Comment to tracked time (on the time entry)",
                       isOn: $controller.settings.commentToTrackedTime)
                Toggle("Comment to task (on the task's activity feed)",
                       isOn: $controller.settings.commentToTask)
                Text(CommentRouting.noteInputVisible(
                        toTrackedTime: controller.settings.commentToTrackedTime,
                        toTask: controller.settings.commentToTask)
                     ? "The note field shows on the tracker."
                     : "Both off — the note field is hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Menu bar") {
                TextField("Low-certainty colour (hex)", text: $controller.settings.colourLow)
                    .textFieldStyle(.roundedBorder)
                TextField("High-certainty colour (hex)", text: $controller.settings.colourHigh)
                    .textFieldStyle(.roundedBorder)
                Text("Set both to the same colour to disable the signalling.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show certainty %", isOn: $controller.settings.showPercent)
                Stepper(controller.settings.menuTaskChars == 0
                        ? "Task name in menu bar: off"
                        : "Task name in menu bar: \(controller.settings.menuTaskChars) chars",
                        value: $controller.settings.menuTaskChars, in: 0...20)
                Text("The first few letters of what's being tracked appear after the time — \"21m Ambit\". Set to 0 to hide it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Local tasks (never sent to OpenProject)") {
                // Fixed column widths shared by header + every row → the columns
                // line up deterministically (a Grid inside a grouped Form didn't).
                HStack(spacing: 8) {
                    Color.clear.frame(width: 22, height: 1)
                    Text("Task").font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Project").font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)
                    Color.clear.frame(width: 18, height: 1)
                }
                ForEach($controller.settings.localTasks) { $task in
                    HStack(spacing: 8) {
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: controller.colour(for: .local(task.id))) },
                            set: { controller.setColour(NSColor($0), for: .local(task.id)) }))
                            .labelsHidden().frame(width: 22)
                        TextField("name", text: $task.name)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
                        // nil project shows its effective value ("Personal") as
                        // real text in the box, not a grey placeholder.
                        TextField("Personal", text: Binding(
                            get: { task.projectName },
                            set: { $task.project.wrappedValue =
                                ($0.isEmpty || $0 == "Personal") ? nil : $0 }))
                            .textFieldStyle(.roundedBorder).frame(width: 130)
                        Button { controller.removeLocalTask(task.id) } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.plain).frame(width: 18)
                    }
                }
                HStack(spacing: 8) {
                    Color.clear.frame(width: 22, height: 1)
                    TextField("New task", text: $newLocalName)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity).onSubmit(addLocal)
                    TextField("Personal", text: $newLocalProject)
                        .textFieldStyle(.roundedBorder).frame(width: 130).onSubmit(addLocal)
                    Button { addLocal() } label: { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.plain).frame(width: 18)
                        .disabled(newLocalName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Picker("Non-work catch-all task", selection: catchAllBinding) {
                    Text("None — just stop").tag(UUID?.none)
                    ForEach(controller.settings.localTasks) { t in
                        Text(t.name).tag(UUID?.some(t.id))
                    }
                }
                Text("Editing a task's name or project keeps its id, history and colour. The catch-all is the one task that confident non-work time lands on when \"Track leisure locally\" is on (instead of stopping the clock) — that's all \"leisure\" ever meant. Projects just group tasks in Time Spent. (Restart to apply the catch-all.)")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Stepper("Switch buffer: \(Int(controller.settings.switchGraceSeconds))s",
                        value: $controller.settings.switchGraceSeconds, in: 0...120, step: 5)
                Text("A new window must hold focus this long before the task switches; briefer visits merge into the current task. (Restart to apply.)")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Sleep grace: \(Int(controller.settings.sleepGraceSeconds))s",
                        value: $controller.settings.sleepGraceSeconds, in: 0...300, step: 15)
                Text("If the Mac sleeps and wakes within this window, tracking just continues — no stop. A longer sleep stops as of when you stepped away. (Restart to apply.)")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Offer to backfill an idle gap for: \(Int(controller.settings.idleBackfillWindowSeconds / 3600))h",
                        value: $controller.settings.idleBackfillWindowSeconds, in: 3600...86_400, step: 3600)
                Text("After an idle stop the gap defaults to a break. For this long afterwards the popover offers a one-tap \"count it as <task>\" — no need to open the timeline.")
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

            Section("About") {
                Text("Build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)   // every label copyable, to share text not screenshots
        .padding(8)
    }

    /// The single non-work catch-all, expressed as a one-of selection over the
    /// local tasks' isLeisure flag — so there's no confusing per-row checkbox.
    private var catchAllBinding: Binding<UUID?> {
        Binding(
            get: { controller.settings.localTasks.first(where: { $0.isLeisure })?.id },
            set: { id in
                for i in controller.settings.localTasks.indices {
                    controller.settings.localTasks[i].isLeisure =
                        (controller.settings.localTasks[i].id == id)
                }
            })
    }

    private func addLocal() {
        let project = newLocalProject.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.addLocalTask(name: newLocalName, isLeisure: false,
                                project: project.isEmpty ? nil : project)
        newLocalName = ""
        newLocalProject = ""
    }
}
