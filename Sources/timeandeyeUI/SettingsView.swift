import SwiftUI
import UniformTypeIdentifiers
import timeandeyeCore
import timeandeyeMac

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow
    @State private var apiKey = ""
    @State private var keySaved = false
    @State private var buildCopied = false

    /// One verbatim-copyable line for bug reports: marketing version + the
    /// build-time stamp make-app.sh writes into CFBundleVersion. The app name
    /// comes from the bundle (CFBundleName, "Time&I" — make-app.sh owns it),
    /// so it can never drift from what the bundle actually says.
    static var buildDetails: String {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleName"] as? String ?? "Time&I"
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(name) \(version) · build \(build)"
    }
    @State private var newLocalName = ""
    @State private var newLocalProject = ""
    @State private var dupActions: [ReconcileAction] = []
    @State private var scanning = false
    @State private var scanned = false
    @State private var expandedDup: Set<String> = []
    @State private var expandAllDup = false
    @State private var senderProbe = ""
    @State private var recipeProbe = ""
    @State private var exportPeriod: TimePeriod = .thisWeek
    @State private var exportCopied = false
    @State private var licenseKeyField = ""
    // iCloud quota stewardship (b/c) — see the Maintenance section below.
    @State private var consolidationPlan: JournalPrune.Plan?
    @State private var hardCapCandidatePlan: JournalPrune.Plan?
    @State private var hardCapConfirmedOnce = false
    /// The chosen ceiling persists in settings (default 50 MB, well above any
    /// realistic footprint) so a considered choice survives a relaunch.
    private var hardCapMB: Binding<Double> {
        Binding(get: { controller.settings.journalHardCapMB ?? 50 },
                set: { controller.settings.journalHardCapMB = $0 })
    }

    /// Which category the sidebar shows; nil only transiently (a sidebar List
    /// selection is Optional) — the detail falls back to .backend.
    @State private var selectedCategory: SettingsIA.Category? = .tracking
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            Form {
                switch selectedCategory ?? .tracking {
                case .backend:       backendSections
                case .tracking:      trackingSections
                case .behaviour:     behaviourSections
                case .menuBar:       menuBarSections
                case .colours:       coloursSections
                case .localTasks:    localTasksSections
                case .billing:       billingSections
                case .emailCalendar: emailCalendarSections
                case .maintenance:   maintenanceSections
                case .diagnostics:   diagnosticsSections
                case .about:         aboutSections
                }
            }
            .formStyle(.grouped)
            .textSelection(.enabled)   // every label copyable, to share text not screenshots
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 500, idealHeight: 620)
        // Hidden ⌘F target — focuses the sidebar search from anywhere in the
        // window (the standard Settings idiom).
        .background {
            // 1×1, not 0×0 — a zero-sized view can be dropped from the key-
            // equivalent chain, which showed as ⌘F missing its first press.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        }
    }

    /// Sidebar: search on top, then the category list — or, while a query is
    /// live, the matching settings. Picking a result jumps to its category.
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Search settings", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { searchText = ""; searchFocused = false }
            }
            .padding(6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .padding([.horizontal, .top], 8)
            let query = searchText.trimmingCharacters(in: .whitespaces)
            if query.isEmpty {
                List(SettingsIA.Category.allCases, selection: $selectedCategory) { cat in
                    Label(cat.title, systemImage: cat.systemImage).tag(cat)
                }
                .listStyle(.sidebar)
            } else {
                let hits = SettingsIA.search(query)
                List {
                    if hits.isEmpty {
                        Text("No settings match")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(hits) { hit in
                        Button {
                            selectedCategory = hit.category
                            searchText = ""
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.title)
                                Text(hit.category.title)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationSplitViewColumnWidth(min: 185, ideal: 205, max: 280)
    }

    // MARK: - Category forms (section bodies unchanged from the single-page
    // Settings; the categories + search are the 2026-07-10 IA rework)

    @ViewBuilder private var backendSections: some View {
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

            // Posting health (A5): only appears when something needs a human —
            // quarantined rows (retryable in one click) or posted entries the
            // journal has since moved away from (re-sync is the coming
            // amendment feature; for now the drift is at least VISIBLE).
            let unhealthy = controller.postingHealthReport()
            if !unhealthy.isEmpty {
                Section("Posting health") {
                    ForEach(unhealthy) { item in
                        HStack {
                            Text(item.name).font(.caption)
                            Spacer()
                            if item.diverged > 0 {
                                Text("\(item.diverged) drifted from the journal")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            if item.stuck > 0 {
                                Text("\(item.stuck) stuck")
                                    .font(.caption).foregroundStyle(.red)
                                Button("Retry") {
                                    controller.retryStuck(backendID: item.id)
                                }
                                .font(.caption)
                            }
                        }
                        // Invoice locks: billed time held safe from edits.
                        // Unlock is per invoice and deliberate — the same
                        // invoice never re-locks itself.
                        ForEach(item.lockedInvoices, id: \.ref) { lock in
                            HStack {
                                Image(systemName: "lock.fill")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text("Invoice \(lock.ref) — \(lock.count) entr\(lock.count == 1 ? "y" : "ies") locked")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("Unlock") {
                                    controller.unlockInvoice(ref: lock.ref, backendID: item.id)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
            }
    }

    @ViewBuilder private var trackingSections: some View {
            Section("Auto-push") {
                let threshold = controller.settings.certaintyAutoPushThreshold
                Slider(value: $controller.settings.certaintyAutoPushThreshold, in: 0.5...1.01) {
                    Text("Auto-push threshold")
                }
                Text(threshold > 1.0 ? "Never auto-push (review everything)"
                     : "Auto-push sessions ≥ \(Int((threshold * 100).rounded()))% certain")
                    .font(.caption).foregroundStyle(.secondary)
                let reviewThreshold = controller.settings.reviewThreshold
                Slider(value: $controller.settings.reviewThreshold, in: 0.0...1.0) {
                    Text("Review threshold")
                }
                Text("Queue for review below \(Int((reviewThreshold * 100).rounded()))% certain "
                     + "· auto-push at \(Int((threshold * 100).rounded()))% and above "
                     + "· in between, Time&I journals but neither asks nor posts")
                    .font(.caption).foregroundStyle(.secondary)
                // The floor's meaningful range starts AT the Switch Buffer:
                // anything briefer never journals, so a sub-buffer floor is
                // inert — the stepper now says so instead of offering dead
                // values (Martin, 2026-07-11).
                let buffer = controller.settings.switchGraceSeconds
                let reviewFloor = max(controller.settings.reviewFloorSeconds, buffer)
                Stepper("Review queue floor: \(Int(reviewFloor.rounded()))s",
                        value: Binding(
                            get: { max(controller.settings.reviewFloorSeconds, buffer) },
                            set: { controller.settings.reviewFloorSeconds = max($0, buffer) }),
                        in: buffer...600, step: 15)
                Text(reviewFloor <= buffer
                     ? "Every uncertain slice asks for review (visits briefer than the \(Int(buffer))s Switch Buffer never journal at all)"
                     : "Only visits of \(Int(reviewFloor.rounded()))s or longer ask for review "
                       + "– briefer glances stay tracked, just never queue")
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
    }

    @ViewBuilder private var menuBarSections: some View {
            Section("Menu bar") {
                // Stock pickers, not raw hex (Martin, 2026-07-11): the value
                // still persists as hex in settings.
                ColorPicker("Low-certainty colour",
                            selection: hexColourBinding(\.colourLow, fallback: .systemRed))
                ColorPicker("High-certainty colour",
                            selection: hexColourBinding(\.colourHigh, fallback: .systemGreen))
                Text("Set both to the same colour to disable the signalling.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show certainty %", isOn: $controller.settings.showPercent)
                Stepper(controller.settings.menuTaskChars == 0
                        ? "Task name in menu bar: off"
                        : "Task name in menu bar: \(controller.settings.menuTaskChars) chars",
                        value: $controller.settings.menuTaskChars, in: 0...20)
                Text("The first few letters of what's being tracked appear after the time — \"21m andey\". Set to 0 to hide it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
    }

    @State private var colourSetNote: String?

    @ViewBuilder private var coloursSections: some View {
            Section("Automatic colours") {
                Button("Re-derive all automatic colours") {
                    controller.rederiveAutomaticColours()
                    colourSetNote = nil
                }
                Text("Rebuilds the whole automatic palette cohesively: every project gets a distinct anchor colour and its tasks shade around it. Colours you picked yourself are untouched.")
                    .font(.caption).foregroundStyle(.secondary)
                // Graphical links, not prose directions: the two
                // places a single colour can be edited, one click away.
                HStack(spacing: 10) {
                    Button {
                        controller.timeWindowView = .spent
                        openWindow(id: "time")
                        AndeyeWindows.activateOnceVisible(opened: "time")
                    } label: {
                        Label("Time Spent legend", systemImage: "chart.pie")
                    }
                    Button {
                        controller.timeWindowView = .timeline
                        openWindow(id: "time")
                        AndeyeWindows.activateOnceVisible(opened: "time")
                    } label: {
                        Label("Timeline editor", systemImage: "calendar.day.timeline.left")
                    }
                    Text("edit any single colour from either")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Colour sets") {
                HStack {
                    Button("Save colour set…") { saveColourSet() }
                    Button("Load colour set…") { loadColourSet() }
                    if let note = colourSetNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("A set is a JSON file capturing every colour — your own picks and the automatic assignments — so you can keep looks and swap between them. Loading replaces everything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Manually picked colours") {
                let projectPicks = controller.settings.projectColours.keys.sorted()
                let taskPicks = controller.settings.taskColours.keys.sorted()
                DisclosureGroup(isExpanded: $manualPicksExpanded) {
                    if projectPicks.isEmpty && taskPicks.isEmpty {
                        Text("No manual picks — every colour is automatic.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(projectPicks, id: \.self) { key in
                        manualProjectPickRow(key)
                    }
                    ForEach(taskPicks, id: \.self) { key in
                        manualTaskPickRow(key)
                    }
                } label: {
                    Text("\(projectPicks.count + taskPicks.count) pick\(projectPicks.count + taskPicks.count == 1 ? "" : "s")")
                        .font(.callout)
                }
                HStack {
                    Text("Every colour you've set by hand, in one place — edit any, or revert it to automatic.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Revert all to automatic") {
                        controller.revertAllColourOverrides()
                    }
                    .font(.caption)
                    .disabled(projectPicks.isEmpty && taskPicks.isEmpty)
                }
            }
    }

    @State private var manualPicksExpanded = false

    private func manualTaskPickRow(_ key: String) -> some View {
        let task = controller.taskCache.first { $0.ref.storageKey == key }
        return HStack(spacing: 8) {
            if let task {
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: controller.colour(for: task.ref)) },
                    set: { controller.setColour(NSColor($0), for: task.ref) }))
                    .labelsHidden().frame(width: 22)
                Text(task.subject).font(.caption)
            } else {
                // The task is no longer resolvable (renamed backend, old
                // key) — show the raw key so the pick is still removable.
                Text(key).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("auto") {
                if let task { controller.resetColour(for: task.ref) }
                else { controller.removeColourOverride(taskKey: key) }
            }
            .font(.caption)
            .help("Revert to the automatic colour")
        }
    }

    private func manualProjectPickRow(_ key: String) -> some View {
        let member = controller.taskCache.first { controller.projectKey(for: $0) == key }
        return HStack(spacing: 8) {
            if let member {
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: controller.projectColour(containing: member.ref) ?? .systemGray) },
                    set: { controller.setProjectColour(NSColor($0), containing: member.ref) }))
                    .labelsHidden().frame(width: 22)
                Text("\(member.project ?? "Personal") (project)").font(.caption)
            } else {
                Text("\(key) (project)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("auto") {
                if let member { controller.resetProjectColour(containing: member.ref) }
                else { controller.removeProjectColourOverride(projectKey: key) }
            }
            .font(.caption)
            .help("Revert to the automatic colour")
        }
    }

    private func saveColourSet() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "timeandeye-colours.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(controller.currentColourSet()).write(to: url)
            colourSetNote = "Saved"
        } catch {
            colourSetNote = "Save failed: \(error.localizedDescription)"
        }
    }

    private func loadColourSet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let set = try JSONDecoder().decode(ColourSet.self,
                                               from: Data(contentsOf: url))
            controller.applyColourSet(set)
            colourSetNote = "Loaded"
        } catch {
            colourSetNote = "Couldn't read that file as a colour set"
        }
    }

    @ViewBuilder private var localTasksSections: some View {
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
    }

    @ViewBuilder private var behaviourSections: some View {
            Section("Behaviour") {
                Stepper("Switch buffer: \(Int(controller.settings.switchGraceSeconds))s",
                        value: $controller.settings.switchGraceSeconds, in: 0...120, step: 5)
                Text("A new window must hold focus this long before the task switches; briefer visits merge into the current task. (Restart to apply.)")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Sleep grace: \(Int(controller.settings.sleepGraceSeconds))s",
                        value: $controller.settings.sleepGraceSeconds, in: 0...300, step: 15)
                Text("If the Mac sleeps and wakes within this window, tracking just continues — no stop. A longer sleep stops as of when you stepped away. (Restart to apply.)")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Offer to log time you were away",
                       isOn: $controller.settings.offerIdleBackfill)
                Stepper("Offer to backfill an idle gap for: \(Int(controller.settings.idleBackfillWindowSeconds / 3600))h",
                        value: $controller.settings.idleBackfillWindowSeconds, in: 3600...86_400, step: 3600)
                    .disabled(!controller.settings.offerIdleBackfill)
                Text("After an idle stop the gap defaults to a break. When on, for this long afterwards the popover offers a one-tap \"count it as <task>\" — no need to open the timeline.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Popover defaults to \"Reassign\" (relabel the running session); off = \"Switch to\" (start fresh). Clicking the task title flips it.",
                       isOn: $controller.settings.popoverDefaultsToChangeMode)
                Picker("Time button opens", selection: $controller.settings.timeViewOpenMode) {
                    Text("Timeline").tag(TimeViewOpenMode.timeline)
                    Text("Last viewed").tag(TimeViewOpenMode.lastViewed)
                    Text("Pie chart").tag(TimeViewOpenMode.spent)
                }
                .pickerStyle(.menu).fixedSize()
                Toggle("System notifications (sounds still play when off)",
                       isOn: $controller.settings.systemNotifications)
                Toggle("Quiet while presenting",
                       isOn: $controller.settings.quietWhilePresenting)
                    .help("While your mic is live or a display is mirrored, banners that would name a task or contact stay hidden – nothing about your work shows on a shared screen.")
                Toggle("Lock the Mac when I leave my desk (⌘⇧L)",
                       isOn: $controller.settings.lockOnLeave)
                Toggle("Track leisure to local-only tasks (instead of stopping)",
                       isOn: $controller.settings.trackLeisureLocally)
            }
    }

    @ViewBuilder private var billingSections: some View {
            Section("Billing") {
                TextField("Currency symbol", text: Binding(
                    get: { controller.settings.currencySymbolOverride ?? "" },
                    set: { controller.settings.currencySymbolOverride = $0.isEmpty ? nil : $0 }),
                    prompt: Text(CurrencyDefault.symbol()))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Text("Shown wherever billable totals appear; leave blank for your locale's symbol (\(CurrencyDefault.symbol())). Projects default to non-billable — right-click a project or task in the Time Spent legend to opt it in, or set a per-task override.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Billing mappings (D6): only with a finance backend registered.
            // Each BILLABLE project picks the finance-backend task its time
            // bills to; unmapped billable time is held (skipped with a "map
            // me" reason in Posting health) and posts on the next pass the
            // moment its mapping lands (criterion 10).
            if controller.hasFinanceBackend {
                Section("Billing mappings") {
                    let sources = controller.billableSourceProjects()
                    if sources.isEmpty {
                        Text("Flag a project billable and its mapping row appears here.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(controller.financeTaskOptions, id: \.backendID) { option in
                        ForEach(sources, id: \.key) { source in
                            HStack {
                                Text(source.name).font(.caption)
                                Spacer()
                                Picker("", selection: Binding<String?>(
                                    get: { controller.financeMapping(forProjectKey: source.key)?.backendTaskID },
                                    set: { controller.setFinanceMapping(projectKey: source.key,
                                                                        backendTaskID: $0) }
                                )) {
                                    Text("Not mapped").tag(String?.none)
                                    ForEach(option.tasks, id: \.ref) { task in
                                        Text("\(task.project ?? option.name) — \(task.subject)")
                                            .tag(task.ref.backendTaskID)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 320)
                            }
                        }
                    }
                }
                .onAppear { Task { await controller.refreshFinanceTaskOptions() } }
            }
    }

    @ViewBuilder private var aboutSections: some View {
            Section("Licence") {
                if let l = controller.license {
                    // v2 keys always carry an expiry; a lifetime key's is
                    // ~200 years out — call that what it is, not a renewal.
                    let farFuture = l.issued.addingTimeInterval(100 * 365.25 * 86_400)
                    Text("\(l.tier.rawValue.capitalized) — licensed to \(l.licensee)"
                         + (l.expires > farFuture ? " · lifetime"
                            : " · renews \(l.expires.formatted(date: .abbreviated, time: .omitted))"))
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

            Section("About") {
                // .textSelection alone is unreliable inside a grouped macOS
                // Form (rows swallow the drag), so the copy button is the
                // guaranteed verbatim path for bug reports.
                HStack(spacing: 6) {
                    Text(Self.buildDetails)
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.buildDetails, forType: .string)
                        buildCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { buildCopied = false }
                    } label: {
                        Image(systemName: buildCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the build details")
                }
            }
    }

    @ViewBuilder private var maintenanceSections: some View {
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

                Divider()
                Text("iCloud footprint").font(.callout).bold()
                Text(controller.journalFootprintSummary.isEmpty ? "Calculating…" : controller.journalFootprintSummary)
                    .font(.caption).foregroundStyle(.secondary)
                Text("Reality check: a slice is a few hundred bytes – heavy tracking runs to 15–25 MB a year in your private CloudKit database. Nobody gets pushed into a paid iCloud tier by Time&I.")
                    .font(.caption2).foregroundStyle(.secondary)

                Divider()
                Text("Consolidate old history").font(.callout).bold()
                HStack {
                    Text("Collapse slices older than")
                    TextField("years", value: $controller.settings.journalConsolidateAfterYears,
                              format: .number)
                        .frame(width: 44).textFieldStyle(.roundedBorder)
                    Text("years into daily totals")
                    Spacer()
                    Button("Preview") { consolidationPlan = controller.consolidationPreview() }
                }
                if let plan = consolidationPlan {
                    if plan.isEmpty {
                        Text("Nothing old enough to consolidate yet").font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("\(plan.deleteIDs.count) old slices → \(plan.create.count) daily rollups")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Consolidate now") {
                                controller.applyConsolidation(plan)
                                consolidationPlan = nil
                            }
                        }
                    }
                }
                Text("Totals and invoicing history survive exactly – only the minute-by-minute detail goes.")
                    .font(.caption2).foregroundStyle(.secondary)

                Divider()
                Text("Hard cap – strongly discouraged").font(.callout).bold().foregroundStyle(.red)
                Text("Deletes your OLDEST raw slices until the synced journal is back under a size you choose. Old totals can be lost for good. The synced journal is normally tiny (see above) – this is for a genuine emergency only.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Cap at")
                    TextField("MB", value: hardCapMB, format: .number)
                        .frame(width: 50).textFieldStyle(.roundedBorder)
                    Text("MB")
                    Spacer()
                    Button("Prune to cap…") {
                        let plan = controller.hardCapPreview(capMB: hardCapMB.wrappedValue)
                        hardCapCandidatePlan = plan.isEmpty ? nil : plan
                    }
                    .disabled(hardCapMB.wrappedValue <= 0)
                }
                .confirmationDialog("This permanently deletes old raw history", isPresented: Binding(
                    get: { hardCapCandidatePlan != nil && !hardCapConfirmedOnce },
                    // Continue ALSO dismisses this dialog, writing false here
                    // — only treat that as cancel when the user hasn't just
                    // confirmed, or the second dialog could never present.
                    set: { if !$0 && !hardCapConfirmedOnce { hardCapCandidatePlan = nil } }
                )) {
                    Button("Continue", role: .destructive) { hardCapConfirmedOnce = true }
                    Button("Cancel", role: .cancel) { hardCapCandidatePlan = nil }
                } message: {
                    Text("Strongly discouraged. Deletes your oldest raw slices to shrink the synced journal – rollups and recent history are never touched, but very old totals can be lost for good.")
                }
                .confirmationDialog("Delete \(hardCapCandidatePlan?.deleteIDs.count ?? 0) slices permanently?",
                                    isPresented: Binding(
                    get: { hardCapCandidatePlan != nil && hardCapConfirmedOnce },
                    set: { if !$0 { hardCapCandidatePlan = nil; hardCapConfirmedOnce = false } }
                )) {
                    Button("Delete permanently", role: .destructive) {
                        if let plan = hardCapCandidatePlan { controller.applyHardCapPrune(plan) }
                        hardCapCandidatePlan = nil
                        hardCapConfirmedOnce = false
                    }
                    Button("Cancel", role: .cancel) { hardCapCandidatePlan = nil; hardCapConfirmedOnce = false }
                } message: {
                    Text("There is no undo.")
                }
            }
    }

    @ViewBuilder private var emailCalendarSections: some View {
            Section("Email → task matching") {
                TextField("My addresses/domains", text: Binding(
                    get: { controller.settings.ownEmailEntries },
                    set: { controller.settings.ownEmailEntries = $0 }))
                    .help("Comma-separated addresses or domains that are YOU – never treated as a correspondent (e.g. martin@example.com, andeye.com)")
                Text("When a message matches several rules, the most specific wins. Order is general (top) → specific (bottom); the bottom-most matching level takes precedence.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Context rules…") {
                    openWindow(id: "rules")
                    AndeyeWindows.activateOnceVisible(opened: "rules")
                }
                .help("Every learned + pinned email rule, with provenance (origin, created, fired, last fired) — forget any of them.")
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

            Section("Calendar") {
                Toggle("Use my calendar", isOn: Binding(
                    get: { controller.settings.calendarSignalEnabled },
                    set: { on in
                        if on { controller.enableCalendarSignal() } else { controller.disableCalendarSignal() }
                    }))
                    .help("Read-only — Time&I never writes to your calendar. The first time you turn this on, macOS asks you to grant Calendar access.")
                // The rest of the section only EXISTS while the signal is on
                // (Martin, 2026-07-09: "skip those settings if no calendar")
                // — a column of disabled knobs for a feature you haven't
                // enabled is noise, not affordance.
                if controller.settings.calendarSignalEnabled {
                    Toggle("Alert before meetings",
                           isOn: $controller.settings.calendarPreMeetingAlertEnabled)
                        .help("The menu-bar mark pulses gently through the lead-up to each meeting.")
                    Picker("Alert lead time",
                           selection: $controller.settings.calendarPreMeetingLeadMinutes) {
                        ForEach(CalendarAlerts.leadMinuteChoices, id: \.self) { minutes in
                            Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                        }
                    }
                    .disabled(!controller.settings.calendarPreMeetingAlertEnabled)
                    Toggle("Flash at meeting start",
                           isOn: $controller.settings.calendarStartAlertEnabled)
                        .help("A strong, unmissable menu-bar flash the moment a meeting begins.")
                    TextField("Excluded calendars", text: Binding(
                        get: { controller.settings.calendarExcludedNames.joined(separator: ", ") },
                        set: { controller.settings.calendarExcludedNames = $0
                            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty } }))
                        .help("Comma-separated calendar names to ignore (e.g. Holidays, Birthdays) — birthday and subscription calendars are already excluded automatically.")
                    Text("When on, Time&I reads your Mac's calendars (read-only) to guess what you're supposed to be doing right now, nudge the pick list towards it, alert you around meetings, and hint at old review-queue rows that overlap a past event. Nothing calendar-derived ever leaves this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
    }

    @ViewBuilder private var diagnosticsSections: some View {
            Section("Diagnostics (dev)") {
                Button("Probe email sender (front browser)") {
                    Task { senderProbe = await controller.probeEmailSender() }
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
                Button("What recipes see here") {
                    recipeProbe = controller.siteRecipeProbeText()
                }
                .help("Shows exactly what the site recipes derive from the last-focused page's URL and title — the matched recipe, every field's value or 'not captured', or why nothing applies. Use it on real GitHub/Docs/Xero pages to verify a recipe's extractors.")
                Text("Focus the page you want to inspect (its window, not this one), then click. Recipes read only the URL and window title Time&I already captures.")
                    .font(.caption).foregroundStyle(.secondary)
                if !recipeProbe.isEmpty {
                    ScrollView {
                        Text(recipeProbe)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 120)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
            }
    }

    /// A hex-backed settings colour as a stock-picker binding (
    /// every colour entry uses the standard macOS picker, never raw hex).
    private func hexColourBinding(_ keyPath: WritableKeyPath<AndeyeSettings, String>,
                                  fallback: NSColor) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: controller.settings[keyPath: keyPath]) ?? fallback) },
            set: { picked in
                let rgb = NSColor(picked).usingColorSpace(.sRGB) ?? fallback
                controller.settings[keyPath: keyPath] = String(
                    format: "#%02X%02X%02X",
                    Int(rgb.redComponent * 255),
                    Int(rgb.greenComponent * 255),
                    Int(rgb.blueComponent * 255))
            })
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
        // Reconcile is about ENTRIES: land on the task's logged-time page
        // (OP: the cost report filtered to the WP), not the bare task page.
        if let url = controller.taskTimeEntriesWebURL(id: taskID) { openURL(url) }
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
