import SwiftUI
import AmbitickCore
import AmbitickMac

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @Environment(\.openURL) private var openURL
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var newLocalName = ""
    @State private var newLocalProject = ""
    @State private var dupActions: [ReconcileAction] = []
    @State private var scanning = false
    @State private var scanned = false
    @State private var expandedDup: Set<String> = []
    @State private var expandAllDup = false
    @State private var senderProbe = ""
    @State private var exportPeriod: TimePeriod = .thisWeek
    @State private var exportCopied = false
    @State private var licenseKeyField = ""

    var body: some View {
        Form {
            Section("OpenProject") {
                TextField("Instance URL", text: $controller.settings.opBaseURL,
                          prompt: Text("https://op.example.com"))
                    .textFieldStyle(.roundedBorder)
                SecureField(controller.hasStoredAPIKey() ? "API key (saved — leave blank to keep)" : "API key",
                            text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    // With a key already on disk you can reconnect on the URL
                    // alone; only require a key entry when none is stored.
                    let canConnect = !controller.settings.opBaseURL.isEmpty
                        && (!apiKey.isEmpty || controller.hasStoredAPIKey())
                    Button(apiKey.isEmpty ? "Connect" : "Save key & connect") {
                        if apiKey.isEmpty {
                            controller.reconnect()
                        } else {
                            controller.saveAPIKey(apiKey)
                            apiKey = ""
                        }
                        keySaved = true
                    }
                    .disabled(!canConnect)
                    .help("Connect to OpenProject and load your tasks")
                    if keySaved { Text("Connected").font(.caption).foregroundStyle(.secondary) }
                }
                if let error = controller.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                } else {
                    Text(controller.taskCache.isEmpty
                         ? "Not connected yet"
                         : "Connected as \(controller.connectedAs ?? "unknown user") – \(controller.taskCache.count) tasks loaded")
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Activity types are a backend concept (OP has them, others may
                // not); hide the picker when there are none to choose.
                if !controller.activities.isEmpty {
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
                Toggle("Popover defaults to \"Change to\" (relabel the running session); off = \"Switch to\" (start fresh). Clicking the task title flips it.",
                       isOn: $controller.settings.popoverDefaultsToChangeMode)
                Picker("Time button opens", selection: $controller.settings.timeViewOpenMode) {
                    Text("Timeline").tag(TimeViewOpenMode.timeline)
                    Text("Last viewed").tag(TimeViewOpenMode.lastViewed)
                    Text("Pie chart").tag(TimeViewOpenMode.spent)
                }
                .pickerStyle(.menu).fixedSize()
                Toggle("System notifications (sounds still play when off)",
                       isOn: $controller.settings.systemNotifications)
                Toggle("Lock the Mac when I leave my desk (⌘⇧L)",
                       isOn: $controller.settings.lockOnLeave)
                Toggle("Track leisure to local-only tasks (instead of stopping)",
                       isOn: $controller.settings.trackLeisureLocally)
            }

            Section("Licence") {
                if let l = controller.license {
                    Text("\(l.tier.rawValue.capitalized) — licensed to \(l.licensee)"
                         + (l.expires.map { " · renews \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""))
                        .font(.caption)
                } else {
                    Text("Community (free) — everything you see is fully functional. A licence adds paid backends (Xero…).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Paste licence key", text: $licenseKeyField)
                        .textFieldStyle(.roundedBorder)
                    Button("Apply") {
                        controller.settings.licenseKey =
                            licenseKeyField.isEmpty ? nil : licenseKeyField
                        licenseKeyField = ""
                    }
                    .disabled(licenseKeyField.isEmpty && controller.settings.licenseKey == nil)
                }
                if let problem = controller.licenseProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Maintenance") {
                HStack {
                    Button(scanning ? "Scanning…" : "Scan for duplicate OpenProject entries") {
                        scanning = true; scanned = false; expandedDup = []; expandAllDup = false
                        Task {
                            let found = await controller.findDuplicateActions()
                            dupActions = found; scanning = false; scanned = true
                        }
                    }
                    .disabled(scanning || controller.settings.opBaseURL.isEmpty)
                    if scanned, dupActions.isEmpty {
                        Text("No duplicates found").font(.caption).foregroundStyle(.secondary)
                    }
                    if !dupActions.isEmpty {
                        Spacer()
                        Button(expandAllDup ? "Collapse all" : "Expand all") { expandAllDup.toggle() }
                            .font(.caption)
                    }
                }
                Text("Finds OP entries duplicated at the same task + minute. Click a group to see every difference between its entries; the survivor is the richest, the rest are deleted (their comments folded into the survivor) and your journal re-points to the survivor. Open any entry in OpenProject to check anything not shown here (e.g. custom fields) before deleting. Confirm each.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(dupActions) { act in dupRow(act) }
                HStack {
                    Picker("Export timesheet", selection: $exportPeriod) {
                        ForEach(TimePeriod.allCases) { p in Text(p.rawValue).tag(p) }
                    }
                    .frame(maxWidth: 260)
                    Button("Copy CSV") {
                        controller.copyToClipboard(
                            controller.timesheetExport(period: exportPeriod, format: .csv))
                        exportCopied = true
                    }
                    Button("Copy Markdown") {
                        controller.copyToClipboard(
                            controller.timesheetExport(period: exportPeriod, format: .markdown))
                        exportCopied = true
                    }
                    if exportCopied {
                        Text("Copied").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Copies the period's tracked time (all tasks, local included) to the clipboard — paste into a spreadsheet (CSV) or an email/invoice note (Markdown). Works with or without a connected backend.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Email → task matching") {
                Text("When a message matches several rules, the most specific wins. Order is general (top) → specific (bottom); the bottom-most matching level takes precedence.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(controller.settings.emailMatchOrder.enumerated()), id: \.element) { i, level in
                    HStack {
                        Text("\(i + 1). \(level.label)")
                        Spacer()
                        Button { moveEmailLevel(i, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(i == 0)
                            .help("More general")
                        Button { moveEmailLevel(i, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless)
                            .disabled(i == controller.settings.emailMatchOrder.count - 1)
                            .help("More specific")
                    }
                    .font(.callout)
                }
            }

            Section("Diagnostics (dev)") {
                Button("Probe email sender (front browser)") {
                    senderProbe = controller.probeEmailSender()
                }
                .help("Walks the focused browser window's Accessibility tree and lists the email addresses it can see, with each node's role. Result is also copied to the clipboard.")
                Text("Open the email you'd want to pin in your browser, then click. Paste the result back so we can design a robust sender extractor. (Whole-tree crawl — diagnostic only, not how the shipped feature will work.)")
                    .font(.caption).foregroundStyle(.secondary)
                if !senderProbe.isEmpty {
                    ScrollView {
                        Text(senderProbe)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
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

    /// Reorder the email-matching specificity ladder (persists via settings didSet).
    private func moveEmailLevel(_ i: Int, by delta: Int) {
        var order = controller.settings.emailMatchOrder
        let j = i + delta
        guard order.indices.contains(i), order.indices.contains(j) else { return }
        order.swapAt(i, j)
        controller.settings.emailMatchOrder = order
    }

    // MARK: - Duplicate reconcile rows

    @ViewBuilder
    private func dupRow(_ act: ReconcileAction) -> some View {
        let expanded = expandAllDup || expandedDup.contains(act.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    if expandedDup.contains(act.id) { expandedDup.remove(act.id) }
                    else { expandedDup.insert(act.id) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(act.label).font(.caption)
                            Text(act.start.formatted(date: .abbreviated,
                                time: act.entries.contains { $0.hasStart } ? .shortened : .omitted))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Apply") {
                    Task {
                        await controller.applyReconcile(act)
                        dupActions.removeAll { $0.id == act.id }
                    }
                }
            }
            if expanded {
                ForEach(act.entries) { e in dupEntryRow(e, survivor: e.id == act.survivorID) }
            }
        }
    }

    private func dupEntryRow(_ e: RemoteTimeEntry, survivor: Bool) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(survivor ? "KEEP" : "delete")
                .font(.caption2).bold()
                .foregroundStyle(survivor ? Color.green : Color.red)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text("#\(e.id) · \(durText(e.durationSeconds))\(e.activity.map { " · \($0)" } ?? "")")
                    .font(.caption2)
                Text("created \(e.createdAt.map { $0.formatted(date: .abbreviated, time: .standard) } ?? "unknown")  ·  \(e.hasStart ? "start " + e.start.formatted(date: .omitted, time: .shortened) : "no start time")")
                    .font(.caption2).foregroundStyle(.secondary)
                if let c = e.comment, !c.isEmpty {
                    Text("“\(c)”").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { openInBackend(e.taskID) } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.plain)
                .help("Open task \(e.taskID) in the backend to check anything not shown here")
        }
        .padding(.leading, 18)
    }

    private func durText(_ secs: TimeInterval) -> String {
        MenuTitle.text(elapsed: secs, certainty: nil, showPercent: false)
    }

    private func openInBackend(_ taskID: String) {
        if let url = controller.taskWebURL(id: taskID) { openURL(url) }
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
                                project: project.isEmpty ? nil : project,
                                primeToCurrentSurface: true)
        newLocalName = ""
        newLocalProject = ""
    }
}
