import Foundation

/// A user-defined non-OpenProject task (leisure, life admin, ...): tracked,
/// timelined and charted like any other task, never pushed to OP.
public struct LocalTaskDef: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var isLeisure: Bool
    /// Local "project" this task groups under in Time Spent (parity with OP's
    /// project → task hierarchy). Optional so older saved settings still decode;
    /// nil/empty is treated as "Personal".
    public var project: String?

    public init(id: UUID = UUID(), name: String, isLeisure: Bool = false,
                project: String? = nil) {
        self.id = id
        self.name = name
        self.isLeisure = isLeisure
        self.project = project
    }

    /// The project name to display/group under (never empty).
    public var projectName: String {
        let p = (project ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return p.isEmpty ? "Personal" : p
    }
}

public extension TaskRef {
    /// Stable string key for settings maps (colours etc.).
    var storageKey: String {
        switch self {
        case .op(let id): return "op:\(id)"
        case .remote(let id): return "remote:\(id)"
        case .local(let uuid): return "local:\(uuid.uuidString)"
        }
    }
}

/// The two time views (one combined entry point opens one of them).
public enum TimeView: String, Codable, Sendable, CaseIterable { case timeline, spent }

/// What the combined Time entry point opens: always the timeline, always the
/// pie, or whichever was viewed last.
public enum TimeViewOpenMode: String, Codable, Sendable, CaseIterable {
    case timeline, lastViewed, spent
}

/// All user-tunable knobs. The OP API key is NOT here – it lives in a 0600 file
/// (see APIKeyStore). Persist via JSONFileStore.
public struct AndeyeSettings: Codable, Equatable, Sendable {
    public var opBaseURL: String
    /// Sessions at/above this certainty auto-push to OP. > 1.0 means never.
    public var certaintyAutoPushThreshold: Double
    /// Spans below this certainty queue for review (`SessionTracker.Config
    /// .uncertainBelow`) — the drawer's OTHER threshold, visible next to the
    /// push threshold (approvals-drawer spec, open question (a)).
    public var reviewThreshold: Double
    public var colourLow: String      // hex; certainty 0 end of the gradient
    public var colourHigh: String     // hex; certainty 1 end
    public var showPercent: Bool
    public var defaultActivityID: Int?
    public var activityOverrides: [TaskRef: Int]
    public var autoComment: Bool
    /// Attach the manual note to the tracked-time entry (the time-entry comment).
    public var commentToTrackedTime: Bool
    /// Also post the manual note to the task's activity feed, where it is far
    /// easier to find than buried on a single time entry.
    public var commentToTask: Bool
    public var trackLeisureLocally: Bool
    public var statusOrder: [String]
    public var primeDwellSeconds: Double
    public var minSegmentSeconds: Double
    /// A visit only enters the Review queue once its slice is at least this
    /// many seconds long. Below it the time is still tracked and journalled —
    /// it just never asks for a decision: a sub-grace visit never becomes a
    /// tracked switch, so its identity is never worth one, however often it
    /// repeats (see `[ReviewSegment].meetingReviewFloor`). 0 = show all.
    public var reviewFloorSeconds: Double
    /// How the Review queue's stacks are ordered (newest/oldest by last
    /// activity, longest/shortest by total time) — persisted so a
    /// backlog-clearing sort survives reopening the drawer.
    public var reviewSortOrder: ReviewSortOrder
    public var switchGraceSeconds: Double
    public var sleepGraceSeconds: Double
    /// How long after an idle stop the one-tap "count the gap as <task>" offer
    /// stays available (the gap defaults to a break if untouched).
    public var idleBackfillWindowSeconds: Double
    /// Show the prominent "worked on X while away?" popover button at all.
    /// Off by default — the offer is opt-in, not a surprise prompt.
    public var offerIdleBackfill: Bool
    /// First N characters of the tracked task name shown in the menu bar; 0 = off.
    public var menuTaskChars: Int
    /// Menu-bar draw-in: the mark's stroke proportion mirrors
    /// the live attribution certainty, revealed eye-first — just the eye
    /// when unsure, the whole &I when certain. Off = the full mark always.
    public var menuDrawInCertainty: Bool
    /// Calm menu bar: the status item renders template-mono,
    /// tinted by macOS like its own items; colour signalling is suppressed
    /// while on.
    public var menuMonochrome: Bool
    public var systemNotifications: Bool
    /// While presenting (mic live or a display mirrored), floating banners
    /// that would name a task or contact are suppressed — a toast naming a
    /// client on a shared screen is a privacy leak. Content-free banners
    /// still show.
    public var quietWhilePresenting: Bool
    /// The popover's default mode when tracking: true = "Change to" (relabel the
    /// running session), false = "Switch to" (start a fresh session). Clicking
    /// the running task title flips to the other mode for that open.
    public var popoverDefaultsToChangeMode: Bool
    /// Which time view the combined entry point opens (timeline / last / pie).
    public var timeViewOpenMode: TimeViewOpenMode
    /// The last time view opened — persisted so "last viewed" survives a restart.
    public var lastViewedTimeView: TimeView
    /// Lock the Mac when "I'm leaving my desk" is activated.
    public var lockOnLeave: Bool
    /// Diagnostics mode (Settings ▸ Diagnostics): shows developer
    /// affordances the everyday UI hides — e.g. the evidence card's copy
    /// button. Off by default: the less clutter the pleasanter the app
    /// (Martin, 2026-07-11).
    public var diagnosticsMode: Bool
    /// Dismissed mis-filed-slice suggestions (ContradictionRefile
    /// dismissal keys) — "dismiss for good" survives relaunch.
    public var refileDismissals: [String]
    /// What happens when later evidence contradicts past entries
    /// (Martin's, 2026-07-11): update them, leave them, or queue
    /// everything for his review.
    public var refileMode: RefileMode
    /// Non-OP tasks (leisure etc.), fully tracked locally.
    public var localTasks: [LocalTaskDef]
    /// User colour overrides per task (TaskRef.storageKey -> hex).
    public var taskColours: [String: String]
    /// User colour overrides per project (stable project key -> hex) — the
    /// pie's ring/legend swatch editor. Like `taskColours`, overrides live
    /// HERE, never in the colour-engine's records: the engine's anchor stays
    /// untouched underneath, so "reset to automatic" always has the exact
    /// pre-override colour to fall back to and the repair pass can never
    /// move a user's pick.
    public var projectColours: [String: String]
    /// The email→task specificity ladder (general → specific); the most specific
    /// matching rule wins. User-reorderable.
    public var emailMatchOrder: [EmailMatchLevel]
    /// The pasted licence key (a signed token, not a secret — safe in the
    /// settings file). nil/invalid = Community tier, fully functional.
    public var licenseKey: String?
    /// Multi-device journal sync (CloudKit). Default OFF: until enabled the
    /// store behaves exactly pre-sync. Flipping on stamps the backlog and
    /// starts the replica cycle (needs the CloudKit-entitled build).
    public var journalSyncEnabled: Bool
    /// Currency symbol shown wherever billable totals render. nil/empty =
    /// the locale's own symbol (CurrencyDefault.symbol()); ONE override
    /// field, no settings sprawl.
    public var currencySymbolOverride: String?
    /// The user's OWN email addresses and domains, comma/space separated
    /// ("martin@example.com, andeye.com") — capture never reports these as
    /// counterparties. Webmail's "me" heuristic only covers the logged-in
    /// account; alternate own addresses showed up as correspondents without
    /// this (seen live 2026-07-09). ONE raw text field, parsed by
    /// `EmailSignal.ownEntrySets`.
    public var ownEmailEntries: String
    /// Finance backends auto-post only sessions younger than this many days
    /// (F15): after a long-idle reconnect (lapsed licence, dead Xero grant,
    /// a long holiday) months of billable backlog must NOT flood the books
    /// unasked — older sessions stay visibly pending until deliberately
    /// released. 0 = no gate.
    public var financeAutoPostWindowDays: Double
    /// iCloud quota stewardship (b): Settings ▸ Maintenance's age-consolidation
    /// prune collapses slices older than this many years into per-day
    /// per-task rollups, on request — never automatic.
    public var journalConsolidateAfterYears: Double
    /// iCloud quota stewardship (c): the hard-cap prune's ceiling in MB —
    /// STRONGLY DISCOURAGED, deletes oldest raw slices until the synced
    /// journal is back under it. nil = no ceiling configured (the default).
    public var journalHardCapMB: Double?
    /// Calendar signal (2026-07-09 spec): read-only EventKit capture, off
    /// until the user explicitly turns it on (that flip is what triggers the
    /// one-time permission prompt — see `AppController.enableCalendarSignal`).
    public var calendarSignalEnabled: Bool
    /// Pre-meeting alert: the menu-bar mark pulses quietly through the
    /// lead-up to each calendar event (Martin's 2026-07-09 alert design).
    /// On by default — inert until `calendarSignalEnabled` is.
    public var calendarPreMeetingAlertEnabled: Bool
    /// How many minutes before an event's start the pre-meeting pulse
    /// begins (`CalendarAlerts.leadMinuteChoices`; default 5).
    public var calendarPreMeetingLeadMinutes: Int
    /// Meeting-start alert: one strong, unmissable menu-bar flash the
    /// moment an event begins. On by default — inert until
    /// `calendarSignalEnabled` is.
    public var calendarStartAlertEnabled: Bool
    /// Calendar names to ignore entirely (birthday/subscription calendars
    /// are already excluded by type, unconditionally — this is the user's
    /// own opt-out on top of that).
    public var calendarExcludedNames: [String]
    /// How many days back the Review queue's calendar hint (spec §7) looks
    /// for an overlapping past event.
    /// The calendar→task specificity ladder (general → specific), the
    /// calendar-side mirror of `emailMatchOrder`.
    public var calendarMatchOrder: [CalendarMatchLevel]
    /// Site-recipe ids the user has turned OFF in the rules ledger's recipe
    /// strip (2026-07-09 site-recipes spec §0 Q4: recipes ship enabled — a
    /// URL/title recipe reads nothing the sensors don't already capture, so
    /// the toggle is legibility, not new collection). A disabled recipe
    /// extracts nothing; its rules go dormant (kept, listed greyed).
    public var siteRecipesDisabled: [String]

    public init(opBaseURL: String,
                certaintyAutoPushThreshold: Double = 0.8,
                reviewThreshold: Double = 0.6,
                colourLow: String = "#FF3B30",
                colourHigh: String = "#34C759",
                showPercent: Bool = false,
                defaultActivityID: Int? = nil,
                activityOverrides: [TaskRef: Int] = [:],
                autoComment: Bool = false,
                commentToTrackedTime: Bool = true,
                commentToTask: Bool = true,
                trackLeisureLocally: Bool = false,
                statusOrder: [String] = ["Now", "Next", "Open", "Closed"],
                primeDwellSeconds: Double = 30,
                minSegmentSeconds: Double = 20,
                reviewFloorSeconds: Double = 60,
                reviewSortOrder: ReviewSortOrder = .newestFirst,
                switchGraceSeconds: Double = 30,
                sleepGraceSeconds: Double = 60,
                idleBackfillWindowSeconds: Double = 18 * 3600,
                offerIdleBackfill: Bool = false,
                menuTaskChars: Int = 5,
                menuDrawInCertainty: Bool = false,
                menuMonochrome: Bool = false,
                systemNotifications: Bool = true,
                quietWhilePresenting: Bool = true,
                popoverDefaultsToChangeMode: Bool = true,
                timeViewOpenMode: TimeViewOpenMode = .lastViewed,
                lastViewedTimeView: TimeView = .timeline,
                lockOnLeave: Bool = false,
                diagnosticsMode: Bool = false,
                refileDismissals: [String] = [],
                refileMode: RefileMode = .auto,
                localTasks: [LocalTaskDef] = [],
                taskColours: [String: String] = [:],
                projectColours: [String: String] = [:],
                emailMatchOrder: [EmailMatchLevel] = EmailMatchLevel.defaultOrder,
                licenseKey: String? = nil,
                journalSyncEnabled: Bool = false,
                financeAutoPostWindowDays: Double = 14,
                currencySymbolOverride: String? = nil,
                ownEmailEntries: String = "",
                journalConsolidateAfterYears: Double = 2,
                journalHardCapMB: Double? = nil,
                calendarSignalEnabled: Bool = false,
                calendarPreMeetingAlertEnabled: Bool = true,
                calendarPreMeetingLeadMinutes: Int = 5,
                calendarStartAlertEnabled: Bool = true,
                calendarExcludedNames: [String] = [],
                calendarMatchOrder: [CalendarMatchLevel] = CalendarMatchLevel.defaultOrder,
                siteRecipesDisabled: [String] = []) {
        self.opBaseURL = opBaseURL
        self.certaintyAutoPushThreshold = certaintyAutoPushThreshold
        self.reviewThreshold = reviewThreshold
        self.colourLow = colourLow
        self.colourHigh = colourHigh
        self.showPercent = showPercent
        self.defaultActivityID = defaultActivityID
        self.activityOverrides = activityOverrides
        self.autoComment = autoComment
        self.commentToTrackedTime = commentToTrackedTime
        self.commentToTask = commentToTask
        self.trackLeisureLocally = trackLeisureLocally
        self.statusOrder = statusOrder
        self.primeDwellSeconds = primeDwellSeconds
        self.minSegmentSeconds = minSegmentSeconds
        self.reviewFloorSeconds = reviewFloorSeconds
        self.reviewSortOrder = reviewSortOrder
        self.switchGraceSeconds = switchGraceSeconds
        self.sleepGraceSeconds = sleepGraceSeconds
        self.idleBackfillWindowSeconds = idleBackfillWindowSeconds
        self.offerIdleBackfill = offerIdleBackfill
        self.menuTaskChars = menuTaskChars
        self.menuDrawInCertainty = menuDrawInCertainty
        self.menuMonochrome = menuMonochrome
        self.systemNotifications = systemNotifications
        self.quietWhilePresenting = quietWhilePresenting
        self.popoverDefaultsToChangeMode = popoverDefaultsToChangeMode
        self.timeViewOpenMode = timeViewOpenMode
        self.lastViewedTimeView = lastViewedTimeView
        self.lockOnLeave = lockOnLeave
        self.diagnosticsMode = diagnosticsMode
        self.refileDismissals = refileDismissals
        self.refileMode = refileMode
        self.localTasks = localTasks
        self.taskColours = taskColours
        self.projectColours = projectColours
        self.emailMatchOrder = emailMatchOrder
        self.licenseKey = licenseKey
        self.journalSyncEnabled = journalSyncEnabled
        self.currencySymbolOverride = currencySymbolOverride
        self.financeAutoPostWindowDays = financeAutoPostWindowDays
        self.ownEmailEntries = ownEmailEntries
        self.journalConsolidateAfterYears = journalConsolidateAfterYears
        self.journalHardCapMB = journalHardCapMB
        self.calendarSignalEnabled = calendarSignalEnabled
        self.calendarPreMeetingAlertEnabled = calendarPreMeetingAlertEnabled
        self.calendarPreMeetingLeadMinutes = calendarPreMeetingLeadMinutes
        self.calendarStartAlertEnabled = calendarStartAlertEnabled
        self.calendarExcludedNames = calendarExcludedNames
        self.calendarMatchOrder = calendarMatchOrder
        self.siteRecipesDisabled = siteRecipesDisabled
    }

    /// Tolerant decoding: EVERY field falls back to its default for an absent OR
    /// malformed/renamed value, so no single corrupt field can throw and take the
    /// whole settings file (and with it the OP URL) down. This has bitten twice
    /// (a renamed enum rawValue both times) — `try ... ?? default` only catches a
    /// nil, NOT a thrown decode, so each field must swallow its own throw.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AndeyeSettings(opBaseURL: "")
        opBaseURL = c.lenient(.opBaseURL, or: defaults.opBaseURL)
        certaintyAutoPushThreshold = c.lenient(.certaintyAutoPushThreshold, or: defaults.certaintyAutoPushThreshold)
        reviewThreshold = c.lenient(.reviewThreshold, or: defaults.reviewThreshold)
        colourLow = c.lenient(.colourLow, or: defaults.colourLow)
        colourHigh = c.lenient(.colourHigh, or: defaults.colourHigh)
        showPercent = c.lenient(.showPercent, or: defaults.showPercent)
        defaultActivityID = ((try? c.decodeIfPresent(Int.self, forKey: .defaultActivityID)) ?? nil) ?? defaults.defaultActivityID
        activityOverrides = c.lenient(.activityOverrides, or: defaults.activityOverrides)
        autoComment = c.lenient(.autoComment, or: defaults.autoComment)
        commentToTrackedTime = c.lenient(.commentToTrackedTime, or: defaults.commentToTrackedTime)
        commentToTask = c.lenient(.commentToTask, or: defaults.commentToTask)
        trackLeisureLocally = c.lenient(.trackLeisureLocally, or: defaults.trackLeisureLocally)
        statusOrder = c.lenient(.statusOrder, or: defaults.statusOrder)
        primeDwellSeconds = c.lenient(.primeDwellSeconds, or: defaults.primeDwellSeconds)
        minSegmentSeconds = c.lenient(.minSegmentSeconds, or: defaults.minSegmentSeconds)
        reviewFloorSeconds = c.lenient(.reviewFloorSeconds, or: defaults.reviewFloorSeconds)
        reviewSortOrder = c.lenient(.reviewSortOrder, or: defaults.reviewSortOrder)
        switchGraceSeconds = c.lenient(.switchGraceSeconds, or: defaults.switchGraceSeconds)
        sleepGraceSeconds = c.lenient(.sleepGraceSeconds, or: defaults.sleepGraceSeconds)
        idleBackfillWindowSeconds = c.lenient(.idleBackfillWindowSeconds, or: defaults.idleBackfillWindowSeconds)
        offerIdleBackfill = c.lenient(.offerIdleBackfill, or: defaults.offerIdleBackfill)
        menuTaskChars = c.lenient(.menuTaskChars, or: defaults.menuTaskChars)
        menuDrawInCertainty = c.lenient(.menuDrawInCertainty, or: defaults.menuDrawInCertainty)
        menuMonochrome = c.lenient(.menuMonochrome, or: defaults.menuMonochrome)
        systemNotifications = c.lenient(.systemNotifications, or: defaults.systemNotifications)
        quietWhilePresenting = c.lenient(.quietWhilePresenting, or: defaults.quietWhilePresenting)
        popoverDefaultsToChangeMode = c.lenient(.popoverDefaultsToChangeMode, or: defaults.popoverDefaultsToChangeMode)
        timeViewOpenMode = c.lenient(.timeViewOpenMode, or: defaults.timeViewOpenMode)
        lastViewedTimeView = c.lenient(.lastViewedTimeView, or: defaults.lastViewedTimeView)
        lockOnLeave = c.lenient(.lockOnLeave, or: defaults.lockOnLeave)
        diagnosticsMode = c.lenient(.diagnosticsMode, or: defaults.diagnosticsMode)
        refileDismissals = c.lenient(.refileDismissals, or: defaults.refileDismissals)
        refileMode = c.lenient(.refileMode, or: defaults.refileMode)
        localTasks = c.lenient(.localTasks, or: defaults.localTasks)
        taskColours = c.lenient(.taskColours, or: defaults.taskColours)
        projectColours = c.lenient(.projectColours, or: defaults.projectColours)
        // Decode the ladder as raw strings and map known levels, so a renamed /
        // unknown level can never throw (which would wipe the whole file). Only a
        // COMPLETE, valid order is honoured; anything else → the default order.
        let rawOrder = ((try? c.decodeIfPresent([String].self, forKey: .emailMatchOrder)) ?? nil) ?? []
        let mapped = rawOrder.compactMap { EmailMatchLevel(rawValue: $0) }
        emailMatchOrder = Set(mapped) == Set(EmailMatchLevel.allCases) ? mapped : defaults.emailMatchOrder
        licenseKey = ((try? c.decodeIfPresent(String.self, forKey: .licenseKey)) ?? nil) ?? defaults.licenseKey
        journalSyncEnabled = c.lenient(.journalSyncEnabled, or: defaults.journalSyncEnabled)
        currencySymbolOverride = ((try? c.decodeIfPresent(String.self, forKey: .currencySymbolOverride)) ?? nil)
            ?? defaults.currencySymbolOverride
        financeAutoPostWindowDays = c.lenient(.financeAutoPostWindowDays,
                                              or: defaults.financeAutoPostWindowDays)
        ownEmailEntries = c.lenient(.ownEmailEntries, or: defaults.ownEmailEntries)
        journalConsolidateAfterYears = c.lenient(.journalConsolidateAfterYears,
                                                 or: defaults.journalConsolidateAfterYears)
        journalHardCapMB = ((try? c.decodeIfPresent(Double.self, forKey: .journalHardCapMB)) ?? nil)
            ?? defaults.journalHardCapMB
        calendarSignalEnabled = c.lenient(.calendarSignalEnabled, or: defaults.calendarSignalEnabled)
        calendarPreMeetingAlertEnabled = c.lenient(.calendarPreMeetingAlertEnabled,
                                                   or: defaults.calendarPreMeetingAlertEnabled)
        // Snap to a known picker choice, so a hand-edited/odd value can't
        // leave the Settings lead-time picker showing no selection.
        let rawLead = c.lenient(.calendarPreMeetingLeadMinutes, or: defaults.calendarPreMeetingLeadMinutes)
        calendarPreMeetingLeadMinutes = CalendarAlerts.leadMinuteChoices.contains(rawLead)
            ? rawLead : defaults.calendarPreMeetingLeadMinutes
        calendarStartAlertEnabled = c.lenient(.calendarStartAlertEnabled,
                                              or: defaults.calendarStartAlertEnabled)
        calendarExcludedNames = c.lenient(.calendarExcludedNames, or: defaults.calendarExcludedNames)
        // Same renamed/unknown-level-safe decode as emailMatchOrder above.
        let rawCalendarOrder = ((try? c.decodeIfPresent([String].self, forKey: .calendarMatchOrder)) ?? nil) ?? []
        let mappedCalendarOrder = rawCalendarOrder.compactMap { CalendarMatchLevel(rawValue: $0) }
        calendarMatchOrder = Set(mappedCalendarOrder) == Set(CalendarMatchLevel.allCases)
            ? mappedCalendarOrder : defaults.calendarMatchOrder
        siteRecipesDisabled = c.lenient(.siteRecipesDisabled, or: defaults.siteRecipesDisabled)
    }
}

public extension AndeyeSettings {
    /// The symbol billable totals render with: the one override field when
    /// set, else the locale default.
    var effectiveCurrencySymbol: String {
        if let symbol = currencySymbolOverride?.trimmingCharacters(in: .whitespaces),
           !symbol.isEmpty {
            return symbol
        }
        return CurrencyDefault.symbol()
    }
}

private extension KeyedDecodingContainer {
    /// Decode `key`, returning `fallback` for an absent OR malformed/renamed value.
    /// Swallows the throw so one corrupt field can't fail the whole container.
    func lenient<T: Decodable>(_ key: Key, or fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}

/// Tiny atomic JSON persistence for any Codable (settings, LearningStore, ...).
public final class JSONFileStore<Value: Codable> {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    private var backupURL: URL { url.appendingPathExtension("bak") }

    /// Decode the main file; if it is present but UNREADABLE, preserve it as
    /// `.corrupt` (so nothing is silently lost) and fall back to the last-good
    /// `.bak`. A genuinely-absent file returns nil (first run). This stops a
    /// single bad read from leading the caller to default-then-overwrite.
    public func load() throws -> Value? {
        do {
            if let value = try decodeFile(url) { return value }
        } catch {
            let corrupt = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: corrupt)
            try? FileManager.default.copyItem(at: url, to: corrupt)
            if let recovered = try? decodeFile(backupURL) { return recovered }
            throw error
        }
        // Main absent — a backup may still hold the last-good copy.
        return try? decodeFile(backupURL) ?? nil
    }

    private func decodeFile(_ u: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: u))
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        // Mirror the just-written (known-good) file as the backup, so load() can
        // recover the LATEST value if the main is later corrupted — and so a
        // corrupt main can never become the backup.
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.copyItem(at: url, to: backupURL)
    }
}
