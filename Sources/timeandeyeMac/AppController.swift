import Foundation
import AppKit
import Carbon.HIToolbox   // kVK_ANSI_L / cmdKey / shiftKey for the global Away hotkey
import timeandeyeCore

/// Pure title/cadence logic, kept out of the controller so it is checkable.
public enum MenuTitle {
    /// 1 Hz for the first minute after a task change, then once per minute.
    public static func refreshInterval(sinceTaskChange: TimeInterval) -> TimeInterval {
        sinceTaskChange < 60 ? 1 : 60
    }

    /// Seconds only under a minute, whole minutes under an hour, then h+m —
    /// per-second precision is noise once the first minute has passed.
    /// Single-digit seconds get a leading FIGURE SPACE (U+2007, exactly one
    /// tabular-digit wide) so 9s→10s doesn't reflow the label: paired with
    /// .monospacedDigit() on the menu Text, every first-minute string is the
    /// same width and the logo beside it stays still. Minutes/hours don't pad —
    /// their width changes are once-a-minute, not a 1 Hz jiggle, and reserving
    /// for "1h 59m" would waste menu-bar space all day.
    public static func text(elapsed: TimeInterval, certainty: Double?,
                            showPercent: Bool) -> String {
        let total = Int(elapsed.rounded())
        let body: String
        if total < 60 {
            body = total < 10 ? "\u{2007}\(total)s" : "\(total)s"
        } else if total < 3600 {
            body = "\(total / 60)m"
        } else {
            body = String(format: "%dh %02dm", total / 3600, (total % 3600) / 60)
        }
        if showPercent, let certainty {
            return "\(body) \(Int((certainty * 100).rounded()))%"
        }
        return body
    }

    /// Upper-bound width templates for `text(elapsed:certainty:showPercent:)`,
    /// covering every digit-count `text` can emit while `elapsed` stays in the
    /// SAME bracket (seconds under a minute / minutes under an hour / hours) —
    /// the bracket that ticks at 1 Hz and is where a width change is a visible
    /// jiggle, not a once-a-minute-or-rarer nudge. The figure-space pad on
    /// text() assumes U+2007 renders exactly as wide as a tabular digit under
    /// .monospacedDigit() — that assumption doesn't always hold (fonts define
    /// the figure space's advance at design time; the tnum OpenType feature
    /// can retarget digit widths without touching it), which is why the pad
    /// alone didn't fully kill the jiggle. RootScenes overlays these templates,
    /// hidden, behind the real text in a ZStack: the container is sized to
    /// whichever candidate lays out widest, so the logo's position depends on
    /// actual rendered width, not on an assumption about glyph metrics.
    /// Crossing INTO the next bracket (59s -> 1m, 59m -> 1h 00m) is a real,
    /// infrequent width change and is deliberately left unreserved — the same
    /// call already made against padding minutes to a "1h 59m" worst case.
    public static func sizingTemplates(elapsed: TimeInterval, certainty: Double?,
                                       showPercent: Bool) -> [String] {
        let total = Int(elapsed.rounded())
        let bodies: [String]
        if total < 60 {
            bodies = ["\u{2007}0s", "00s"]
        } else if total < 3600 {
            bodies = ["0m", "00m"]
        } else {
            bodies = ["0h 00m", "00h 00m"]
        }
        guard showPercent, certainty != nil else { return bodies }
        return bodies.map { "\($0) 100%" }   // widest percent suffix is 3 digits
    }

    /// Optional task tag after the time in the menu bar: the first `chars` of
    /// the task name, so a glance reads "21m andey" rather than just "21m".
    /// No ellipsis — the truncation is implicit and it saves a character.
    /// Empty name or chars <= 0 leaves the body alone.
    public static func withTaskName(_ name: String?, chars: Int, body: String) -> String {
        guard let name, chars > 0 else { return body }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return body }
        return "\(body) \(String(trimmed.prefix(chars)))"
    }

    /// Elapsed for the live clock. `liveSliceStart` (the tracker's contiguous
    /// slice start) is authoritative: it spans excursion windows that reverted
    /// back to the base task, which the per-visit banked+running figure misses —
    /// so without it the menu bar under-counts heavy flitting versus what flushes
    /// to OP. The banked+running fallback wins when there is no live slice (slice
    /// just committed: the tracker reset to `now` while the controller re-banked
    /// the committed time to keep the clock continuous), so take the larger.
    public static func displayedElapsed(liveSliceStart: Date?, bankedFallback: TimeInterval,
                                        running: TimeInterval, now: Date) -> TimeInterval {
        let fallback = bankedFallback + running
        guard let start = liveSliceStart else { return fallback }
        return max(now.timeIntervalSince(start), fallback)
    }

    /// Linear blend between the user's two gradient colours; grey when stopped.
    public static func colour(certainty: Double?, lowHex: String, highHex: String) -> NSColor {
        guard let certainty else { return .systemGray }
        let low = NSColor(hex: lowHex) ?? .systemRed
        let high = NSColor(hex: highHex) ?? .systemGreen
        let f = CGFloat(min(max(certainty, 0), 1))
        return NSColor(
            red: low.redComponent + (high.redComponent - low.redComponent) * f,
            green: low.greenComponent + (high.greenComponent - low.greenComponent) * f,
            blue: low.blueComponent + (high.blueComponent - low.blueComponent) * f,
            alpha: 1)
    }
}

public extension NSColor {
    /// Black on light backgrounds, white on dark — by perceived luminance.
    var readableTextColour: NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        let luminance = 0.299 * c.redComponent + 0.587 * c.greenComponent
            + 0.114 * c.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}


/// An idle/away stretch that defaulted to untracked, offered for one-tap claim.
public struct IdleGap: Equatable, Sendable {
    public var task: TaskRef
    public var from: Date
    public var to: Date
}

/// Owns the whole pipeline: sensors -> tracker -> journal -> sync, plus the
/// published state the SwiftUI layer renders.
@MainActor
public final class AppController: ObservableObject {
    @Published public private(set) var trackerState: TrackerState = .stopped
    @Published public private(set) var menuText = "–"
    /// Hidden-text sizing candidates for menuText — see MenuTitle.sizingTemplates
    /// and RootScenes' ZStack. Empty while stopped: "–" never changes width, so
    /// there's nothing to reserve against.
    @Published public private(set) var menuSizingTemplates: [String] = []
    /// AppKit-measured reserved width for the menu-bar text (points, 0 = none):
    /// the widest of the sizing templates AND the current text, measured with
    /// the same monospaced-digit system font SwiftUI's .monospacedDigit()
    /// resolves to. Martin observed (2026-07-08) the icon still shifts exactly
    /// when the time text changes width — the hidden-template ZStack was not
    /// holding the MenuBarExtra label's width — so RootScenes now applies this
    /// as an explicit minWidth: measured reservation the label can't undercut,
    /// while content sizing remains the fallback if measurement ever runs low
    /// (minWidth can't clip, unlike a fixed frame).
    @Published public private(set) var menuReservedWidth: CGFloat = 0
    /// Elapsed time only (no task name) for the popover, which shows the task as
    /// its headline — see refreshTitle.
    @Published public private(set) var elapsedText = "–"
    @Published public private(set) var menuColour = NSColor.systemGray
    /// The menu-bar mark: the andeye ampersand-eye tinted with menuColour.
    /// Starts blank; startUp plays the draw-on which ends at the full mark.
    @Published public private(set) var logoImage = NSImage()
    @Published public private(set) var taskCache: [WorkTask] = [] {
        didSet {
            invalidatePickList()
            // Keep the finance-mapping store's source-task→project-key
            // snapshot in step with the cache (the connector reads it from
            // the sync context; a live closure into main-actor state would
            // race — see FinanceMappingStore's thread-shape note).
            financeMappings.setProjectKeys(Dictionary(
                taskCache.compactMap { task -> (String, String)? in
                    guard task.ref.isRemote, let id = task.ref.backendTaskID,
                          let key = projectKey(for: task) else { return nil }
                    return (id, key)
                },
                uniquingKeysWith: { first, _ in first }))
        }
    }
    @Published public private(set) var pendingReview: [ReviewSegment] = []
    /// Retro-acceptance receipts, newest first — the drawer's "Recently
    /// cleared" section (approvals-drawer spec §3). Loaded at startup,
    /// refreshed after every pass and after undo.
    @Published public private(set) var retroDigest: [RetroDigest] = []
    @Published public private(set) var activities: [TimeActivity] = []
    @Published public private(set) var lastPrompt: TrackerPrompt?
    /// An idle stretch that defaulted to "break" (untracked). A single tap in
    /// the popover claims it as the task you were on — no timeline needed. It
    /// survives auto-resume and stays offered for `idleBackfillWindowSeconds`.
    @Published public private(set) var pendingGap: IdleGap?
    @Published public private(set) var lastError: String?
    /// backendID → count of posted entries whose journal side has since
    /// moved (D4 detection; empty = books match the journal).
    @Published public private(set) var postingDivergences: [String: Int] = [:]
    @Published public private(set) var journalSummary = ""
    /// (a) iCloud quota stewardship: Settings ▸ Maintenance's honest footprint
    /// line — updated alongside `journalSummary` on every journal mutation.
    @Published public private(set) var journalFootprintSummary = ""
    @Published public private(set) var connectedAs: String? {
        didSet { invalidatePickList() }   // RankingConfig.currentUser input
    }
    /// The live calendar match (calendar-signal spec §5): whichever task the
    /// current calendar event resolves to via `calendarRules`, and whether
    /// that event is only tentative. nil when the signal is off, nothing is
    /// live right now, or nothing matched. Drives the pick-list clock badge,
    /// the ranker boost, and the mismatch banner below.
    @Published public private(set) var currentCalendarMatch: (task: TaskRef, eventTitle: String, tentative: Bool)? {
        didSet { invalidatePickList() }   // TaskRanker.recentThenRanked's calendarMatch input
    }
    /// True once a live calendar match has disagreed with the tracked task
    /// for the settle window (§6) — drives the popover's one-line
    /// "Calendar: <event> – Switch" banner.
    @Published public private(set) var calendarMismatchActive = false
    /// The validated licence, or nil for Community (no key / bad key / expired
    /// — `licenseProblem` says which). Pro builds gate paid backends on this.
    @Published public private(set) var license: License?
    @Published public private(set) var licenseProblem: String?
    /// The speech-bubble note: replaces the auto comment on sessions closing
    /// while it is set; cleared when tracking stops.
    /// The speech-bubble note. NOT @Published: binding a TextField to a
    /// published var rebuilds the whole popover on every keystroke and steals
    /// focus ("can't type"). The popover edits a local copy and pushes here.
    /// Committed comments awaiting their slice, PER TASK (Martin's three
    /// rapid test comments once all rode one global note onto one slice).
    /// Each task's note is consumed by ITS slice at flush.
    /// TIMESTAMPED per task (Martin's 14:39 test: a comment typed after
    /// returning from an excursion accumulated onto the PRE-excursion part of
    /// the base slice — the carve splits one task's time into several slices,
    /// so each slice must consume only the comments typed within ITS span).
    public var manualNotes: [TaskRef: [(text: String, at: Date)]] = [:]
    /// Display-target shim over `manualNotes` — the live-slice comment the
    /// timeline editor and legacy paths read/write. Keyed by the task the
    /// popover currently shows; empty/ignored when not tracking a task.
    public var manualNote: String {
        get {
            guard case .task(let ref) = currentTarget else { return "" }
            return Self.joinedNote(manualNotes[ref])
        }
        set {
            guard case .task(let ref) = currentTarget else { return }
            if newValue.isEmpty { manualNotes[ref] = nil }
            else { manualNotes[ref] = [(text: newValue, at: Date())] }
        }
    }

    /// The pending comments' display/flush form — accumulateComment's exact
    /// joining (separator + adjacent-repeat suppression), applied over the
    /// timestamped entries.
    static func joinedNote(_ entries: [(text: String, at: Date)]?) -> String {
        (entries ?? []).reduce("") { CommentRouting.accumulateComment(existing: $0, adding: $1.text) }
    }
    @Published public var settings: AndeyeSettings {
        didSet {
            invalidatePickList()   // statusOrder / localTasks feed the ranker
            try? settingsStore.save(settings)
            Notifier.enabled = settings.systemNotifications
            attributor.emailMatchOrder = settings.emailMatchOrder
            attributor.disabledSiteRecipes = Set(settings.siteRecipesDisabled)
            // A toggled recipe changes what extracts (and which rules are
            // dormant) RIGHT NOW — re-evaluate the live session at once.
            if oldValue.siteRecipesDisabled != settings.siteRecipesDisabled {
                tracker.reevaluate()
            }
            if oldValue.ownEmailEntries != settings.ownEmailEntries { pushOwnEmail() }
            // The review floor gates queue ADMISSION at reload time, so a
            // changed floor re-filters the live queue immediately — no
            // restart, no waiting for the next segment to arrive.
            if oldValue.reviewFloorSeconds != settings.reviewFloorSeconds { reloadReview() }
            if oldValue.opBaseURL != settings.opBaseURL { rebuildClient() }
            if oldValue.licenseKey != settings.licenseKey { revalidateLicense() }
            // Local-task edits (rename / project / leisure / add / remove) flow
            // straight into the live cache so every list, the timeline and the
            // pie reflect them at once.
            if oldValue.localTasks != settings.localTasks { mergeLocalTasksIntoCache() }
            // Calendar signal: the setting is the ONE source of truth for
            // whether the bridge runs — `enableCalendarSignal`/
            // `disableCalendarSignal` just flip it (after the permission
            // round-trip for the former), so every path that changes it
            // (Settings toggle, a refused permission prompt) starts/stops
            // the bridge and clears state uniformly, right here.
            if oldValue.calendarSignalEnabled != settings.calendarSignalEnabled {
                if settings.calendarSignalEnabled {
                    calendarBridge.onEvent = { [weak self] events in self?.handleCalendarEvents(events) }
                    calendarBridge.start(excludedCalendarNames: settings.calendarExcludedNames)
                } else {
                    calendarBridge.stop()
                    calendarBoundaryTimer?.invalidate(); calendarBoundaryTimer = nil
                    calendarEventWindow = []
                    calendarLookbackCache = nil
                    currentCalendarMatch = nil
                    attributor.currentCalendarMatch = nil
                    invalidatePickList()
                    calendarMismatchSince = nil
                    calendarMismatchActive = false
                    calendarAlertsFired = []
                    stopCalendarAlertAnimations()
                }
            }
            if oldValue.calendarExcludedNames != settings.calendarExcludedNames {
                calendarBridge.setExcludedCalendarNames(settings.calendarExcludedNames)
            }
            // A changed lead time / alert toggle moves the alert boundaries —
            // reschedule and re-evaluate at once, so e.g. turning the
            // pre-meeting alert off stops a pulse that is running right now.
            if oldValue.calendarPreMeetingAlertEnabled != settings.calendarPreMeetingAlertEnabled
                || oldValue.calendarPreMeetingLeadMinutes != settings.calendarPreMeetingLeadMinutes
                || oldValue.calendarStartAlertEnabled != settings.calendarStartAlertEnabled {
                scheduleCalendarBoundaryCheck()
                updateCalendarAlerts(now: Date())
            }
        }
    }

    public let journal: any JournalStore
    private let attributor: Attributor
    private var tracker: SessionTracker!
    private let sensors = SensorHub()
    /// Calendar-signal spec (2026-07-09): read-only EventKit capture, owned
    /// here exactly like `sensors` — its own store, its own lazy permission
    /// request, wired into the same main-actor state this controller owns.
    private let calendarBridge = CalendarBridge()
    private let settingsStore: JSONFileStore<AndeyeSettings>
    private let learningStore: JSONFileStore<LearningStore>
    private let primedStore: JSONFileStore<[Surface: TaskRef]>
    private let pinsStore: JSONFileStore<[Pin]>
    private let emailRulesStore: JSONFileStore<[EmailRule]>
    /// Site rules (2026-07-09 site-recipes spec §5): siterules.json beside
    /// emailrules.json — a new file, no migration.
    private let siteRulesStore: JSONFileStore<[SiteRule]>
    /// The calendar→task ladder (mirrors `emailRules` exactly): learned from
    /// corrections, editable rule ladder — see `teachCalendarRule`. Kept on
    /// the Mac side rather than on `Attributor` (unlike `emailRules`)
    /// because `CalendarRule`/`CalendarMatcher` are plain, storage-free Core
    /// types with no Attributor-owned ladder of their own (v1 scope — no
    /// Rules Ledger UI yet, spec §10 "later").
    private let calendarRulesStore: JSONFileStore<[CalendarRule]>
    private var calendarRules: [CalendarRule] = []
    private let billingStore: JSONFileStore<BillableRules>
    /// Colour assignments (colour-strategy spec): first-sight colour records,
    /// a user-ownable colours.json beside pins.json. NOT @Published — records
    /// are appended lazily inside `colour(for:)` DURING view rendering, and
    /// publishing mid-render is a SwiftUI violation; the returned colour is
    /// used directly, so no invalidation is needed.
    private let coloursStore: JSONFileStore<ColourAssignments>
    private var colourAssignments: ColourAssignments
    /// True when colours.json was loaded WITHOUT a version stamp — i.e. last
    /// saved by the broken 2026-07-09 engine or the 2026-07-10 interim
    /// repair. In such a store an "auto" project anchor may itself be one of
    /// those builds' wrong fresh picks, so the repair may replace it (see
    /// ColourEngine.repairProjectAnchor). Captured at load, BEFORE this
    /// build stamps the in-memory store to the current version.
    private let colourStoreLoadedPreV2: Bool
    /// The one-time "anchor repairs are finished" marker. Lives OUTSIDE
    /// colours.json because a round-trip through a pre-provenance binary
    /// silently strips the store's provenance/version fields (decode drops
    /// unknown keys, re-encode loses them), which would re-arm the nil
    /// sentinel forever — a separate file no old binary touches survives
    /// that. While the marker is absent, `colourRepairArmed` keeps the
    /// legacy-anchor repair live; once written it is never repaired again.
    private let colourRepairMarkerURL: URL
    private var colourRepairArmed: Bool
    /// Projects already put through the repair gate this run — the engine's
    /// provenance rules make re-checks no-ops anyway; this just skips the
    /// O(taskCache) member scan on hot render paths.
    private var colourProjectsRepairChecked: Set<String> = []
    private let financeMappingsStore: JSONFileStore<[String: FinanceMapping]>
    /// D6: sourceProjectKey → the finance backend's task. Core-owned;
    /// Settings edits it; the Pro flavour hands it to its finance connector
    /// at registration (the connector translates internally). The
    /// source-task→project-key snapshot refreshes with the task cache.
    public let financeMappings = FinanceMappingStore()
    /// All registered backends (the community build registers at most the
    /// one pm OpenProject entry; andeyePro adds its connectors through
    /// `register(backend:id:class:)`). Empty = standalone — nothing syncs,
    /// everything tracks locally.
    private let registry = BackendRegistry()
    /// The primary pm backend — what the single-backend surfaces (task list,
    /// timeline PATCH/DELETE, "Open in <backend>") talk to. nil = standalone.
    private var backend: (any TaskBackend)? { registry.primaryPM?.backend }
    private var titleTimer: Timer?
    private var taskRefreshTimer: Timer?
    /// System-wide ⌘⇧L "Away" toggle (Carbon RegisterEventHotKey). The
    /// SwiftUI .keyboardShortcut in the popover only fires when andeye is
    /// key; this fires from any app. Installed in startUp, torn down on
    /// terminate/deinit (which unregisters the Carbon hotkey + handler).
    private var awayHotKey: GlobalHotKey?
    /// Dedicated, tight (~12 s) crash-safety checkpoint timer, gated to
    /// .tracking. Generous tolerance lets the OS coalesce the wakeup, so the
    /// extra cadence costs no measurable energy over the 60 s refresh timer.
    private var checkpointTimer: Timer?
    private var taskChangedAt = Date()
    private var currentTarget: Target?
    /// The task we were tracking immediately before the current one, held in
    /// memory so "revert" offers the task you actually just left — not the
    /// journal's most-recent-by-start closed slice, which could be a stray
    /// earlier minute (Martin saw it offer a 1-min "a university course" instead of
    /// the andeye he'd just switched away from, because that slice hadn't
    /// flushed yet during the switch grace).
    private var previousTask: TaskRef?
    /// Per-task session accumulators: each task banks its own visited time.
    /// Returning to a task resumes its clock; a task that holds focus past the
    /// grace ("takes over") ends every other task's session. Cleared on stop.
    private var bankedElapsed: [Target: TimeInterval] = [:]
    private var targetSince: Date?
    private var visitSolid = false

    // MARK: - Calendar signal (2026-07-09 spec)

    /// The bridge's last-emitted rolling window (today ± a day or two, see
    /// `CalendarBridge.refresh`) — replaced on every bridge emission and
    /// re-consulted on every event-boundary crossing.
    private var calendarEventWindow: [CalendarEvent] = []
    /// Fires the next time a fetched event's start/end is crossed, so the
    /// live match / mismatch state updates the moment a meeting begins or
    /// ends, not just on the next bridge emission.
    private var calendarBoundaryTimer: Timer?
    /// When the current mismatch (if any) started holding — nil once it
    /// clears. Compared against the settle window before the banner goes
    /// live (§6 — a brief walk-in shouldn't banner before you've sat down).
    private var calendarMismatchSince: Date?
    /// Occurrence keys (`CalendarEvent.occurrenceKey`) whose meeting-start
    /// flash has already fired — no event alerts twice. Pruned to the
    /// bridge's rolling window on every emission, so it can't grow without
    /// bound; deliberately NOT persisted (a relaunch inside the 60 s start
    /// grace re-flashing once is harmless, and past-grace events never
    /// flash retroactively anyway — see `CalendarAlerts.startGraceSeconds`).
    private var calendarAlertsFired: Set<String> = []
    /// The pre-meeting quiet pulse — a standing loop while the phase is
    /// `.preMeeting`, cancelled the moment it isn't.
    private var calendarPulseAnimation: Task<Void, Never>?
    /// The meeting-start violent flash — a one-shot burst, self-clearing.
    private var calendarStartFlashAnimation: Task<Void, Never>?
    /// A cheap render-time cache for the review-queue hint (§7) — one
    /// EventKit query per drawer refresh, not one per stack row (mirrors
    /// `pickListCache`'s own 60 s-scale TTL shape).
    private var calendarLookbackCache: (at: Date, events: [CalendarEvent])?
    /// How long a mismatch must hold before the banner goes live.
    private static let calendarMismatchSettleSeconds: TimeInterval = 60

    public static func supportDirectory() -> URL {
        AppSupport.directory()
    }

    /// Forwarder kept for the checks' temp-dir exercises; the logic (and the
    /// rename migration) lives in timeandeyeStore.AppSupport so EVERY on-disk
    /// consumer shares it (see the post-rename API-key bug).
    public nonisolated static func supportDirectory(under base: URL) -> URL {
        AppSupport.directory(under: base)
    }

    public init() {
        let dir = Self.supportDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settingsStore = JSONFileStore<AndeyeSettings>(url: dir.appendingPathComponent("settings.json"))
        learningStore = JSONFileStore<LearningStore>(url: dir.appendingPathComponent("learning.json"))
        primedStore = JSONFileStore<[Surface: TaskRef]>(url: dir.appendingPathComponent("primed.json"))
        pinsStore = JSONFileStore<[Pin]>(url: dir.appendingPathComponent("pins.json"))
        emailRulesStore = JSONFileStore<[EmailRule]>(url: dir.appendingPathComponent("emailrules.json"))
        siteRulesStore = JSONFileStore<[SiteRule]>(url: dir.appendingPathComponent("siterules.json"))
        calendarRulesStore = JSONFileStore<[CalendarRule]>(url: dir.appendingPathComponent("calendarrules.json"))
        billingStore = JSONFileStore<BillableRules>(url: dir.appendingPathComponent("billing.json"))
        billing = (try? billingStore.load().flatMap { $0 }) ?? BillableRules()
        financeMappingsStore = JSONFileStore<[String: FinanceMapping]>(
            url: dir.appendingPathComponent("finance-mappings.json"))
        let loadedMappings = ((try? financeMappingsStore.load().flatMap { $0 }) ?? [:])
        for key in loadedMappings.keys {
            financeMappings.set(loadedMappings[key], forProjectKey: key)   // onChange unwired: pure load
        }
        let loadedSettings = (try? settingsStore.load().flatMap { $0 })
            ?? AndeyeSettings(opBaseURL: "")
        settings = loadedSettings
        journal = (try? SQLiteJournalStore(path: dir.appendingPathComponent("journal.sqlite").path))
            ?? InMemoryJournalStore()
        // One-time single-slot → posting-ledger upgrade: every historical
        // pushedToOP row becomes a posted ledger row against the built-in OP
        // id, so the ledger-driven sync can never re-post (double-post) what
        // the old code already pushed. Idempotent per row; the live-checkpoint
        // sentinel is excluded (its pushed flag is a sentinel, not a post).
        _ = try? journal.migrateSingleSlotPostings(to: OPBackend.stableID,
                                                   excluding: [Self.liveCheckpointID])

        // Colour records (colour-strategy spec §6). First launch of the new
        // store (no decodable colours.json yet): every task with ANY journal
        // time gets its pre-engine hash colour snapshotted as its permanent
        // assignment — "has time" ≈ "has been seen in the pie", and a colour,
        // once seen, never changes underneath the user. Tasks never tracked
        // go through the allocator on first sight instead. User overrides
        // stay in settings.taskColours untouched (they already win).
        coloursStore = JSONFileStore<ColourAssignments>(url: dir.appendingPathComponent("colours.json"))
        colourRepairMarkerURL = dir.appendingPathComponent("colours.repaired")
        colourRepairArmed = !FileManager.default.fileExists(atPath: colourRepairMarkerURL.path)
        if let existing = (try? coloursStore.load()).flatMap({ $0 }) {
            colourStoreLoadedPreV2 = existing.version == nil
            colourAssignments = existing
        } else {
            colourStoreLoadedPreV2 = false   // fresh store: no old picks to distrust
            var snapshot = ColourAssignments()
            let seen = (try? journal.latestEndByTask(excluding: [Self.liveCheckpointID])) ?? [:]
            for ref in seen.keys where ref != WorkTask.unknown.ref {
                ColourEngine.snapshotLegacy(taskKey: ref.storageKey,
                                            hex: Self.legacyHashColourHex(for: ref),
                                            in: &snapshot)
            }
            snapshot.version = ColourAssignments.currentVersion
            colourAssignments = snapshot
            try? coloursStore.save(snapshot)
        }
        // Every save from here on carries the current schema version; the
        // pre-v2 verdict above is already banked for this run.
        colourAssignments.version = ColourAssignments.currentVersion

        let host = URL(string: loadedSettings.opBaseURL)?.host ?? ""
        let learning = (try? learningStore.load().flatMap { $0 }) ?? LearningStore()
        attributor = Attributor(instanceHost: host,
                                learning: learning,
                                ranker: TaskRanker(config: RankingConfig(statusOrder: loadedSettings.statusOrder)))
        if let primed = (try? primedStore.load()).flatMap({ $0 }) {
            attributor.primedSurfaces = primed
        }
        attributor.emailMatchOrder = loadedSettings.emailMatchOrder
        attributor.disabledSiteRecipes = Set(loadedSettings.siteRecipesDisabled)
        if let rules = (try? emailRulesStore.load()).flatMap({ $0 }) {
            attributor.emailRules = rules
        }
        if let rules = (try? siteRulesStore.load()).flatMap({ $0 }) {
            attributor.siteRules = rules
        }
        if let calRules = (try? calendarRulesStore.load()).flatMap({ $0 }) {
            calendarRules = calRules
        }
        if let pins = (try? pinsStore.load()).flatMap({ $0 }) {
            attributor.pins = pins
        } else {
            // Migrate legacy scope→task pins (pre-rule-engine) to component pins.
            // Self-terminating one-shot: once we save the migrated [Pin] back to
            // pins.json, the [Pin] decode above succeeds on every later launch, so
            // this else branch never runs again.
            let legacyStore = JSONFileStore<[PinScope: TaskRef]>(
                url: dir.appendingPathComponent("pins.json"))
            if let legacy = (try? legacyStore.load()).flatMap({ $0 }), !legacy.isEmpty {
                attributor.pins = legacy.map { Pin(rule: .components($0.key), task: $0.value) }
                try? pinsStore.save(attributor.pins)
            }
        }

        let leisure = loadedSettings.localTasks.first(where: \.isLeisure)
            .map { TaskRef.local($0.id) }
        let config = TrackerConfig(
            minSegmentSeconds: loadedSettings.minSegmentSeconds,
            primeDwellSeconds: loadedSettings.primeDwellSeconds,
            // C14: pmset is a subprocess — off the launch path. Last
            // launch's cached reading (or the 600 s default) serves until
            // startUp's async refresh applies the live value.
            idleThresholdSeconds: UserDefaults.standard
                .object(forKey: "cachedDisplaySleepSeconds") as? TimeInterval ?? 600,
            uncertainBelow: loadedSettings.reviewThreshold,
            nonWorkTracksLocally: loadedSettings.trackLeisureLocally && leisure != nil,
            leisureTask: leisure,
            switchGraceSeconds: loadedSettings.switchGraceSeconds,
            sleepGraceSeconds: loadedSettings.sleepGraceSeconds)
        tracker = SessionTracker(attributor: attributor, config: config) { [weak self] in
            self?.taskCache ?? []
        }
        wireTracker()
        wireFirstFireNotice()
        rebuildClient()
        revalidateLicense()
        configureSyncReplica()
        taskCache = localWorkTasks()   // locals exist before OP ever connects
        applyJournalRecency()          // recency survives the relaunch
        renderLogo()
        updateJournalSummary()         // so Settings ▸ Maintenance's footprint is populated at launch, not just after the first mutation
        // Wired AFTER the persisted-mappings load above, so loading doesn't
        // re-save or re-open anything. From here, every Settings edit
        // persists AND re-opens the no-mapping skips for exactly the changed
        // project (criterion 10), then nudges a pass so it posts now.
        financeMappings.onChange = { [weak self] key in
            Task { @MainActor in
                guard let self else { return }
                try? self.financeMappingsStore.save(self.financeMappings.mappings)
                for entry in self.registry.entries where entry.backendClass == .finance {
                    SyncEngine.reopenMappingSkips(journal: self.journal,
                                                  backendID: entry.id, projectKey: key)
                }
                await self.syncIfEnabled()
            }
        }
    }

    // MARK: - Menu-bar logo animation

    /// Current pose of the mark; renderLogo composes these with menuColour.
    private var logoT = 0.0
    private var logoWink = 0.0
    /// The calendar alerts' current amount (0...1) — a THIRD, independent
    /// pose alongside t/wink, driven by its own loops (`calendarPulseAnimation`
    /// / `calendarStartFlashAnimation`, below) on their own cadences, never
    /// by `logoAnimation`'s draw-on/wink.
    private var logoFlash = 0.0
    private var logoAnimation: Task<Void, Never>?
    /// The target last shown, so the wink fires exactly when the tracked task
    /// changes (nil when stopped — a fresh start from stopped doesn't wink).
    private var lastDisplayedTarget: Target?

    private func renderLogo() {
        // The WHOLE menu-bar label is one image — mark + elapsed text in a
        // reserved-width column — so the item's width is ours, not a text
        // layout's, and the mark cannot be nudged by a digit tick (the
        // third and final jiggle fix; see AndeyeLogoImage.label).
        logoImage = AndeyeLogoImage.label(t: logoT, wink: logoWink, colour: menuColour,
                                          flash: logoFlash, text: menuText,
                                          reservedTextWidth: menuReservedWidth)
    }

    /// Hand-draws the ampersand over ~1.2 s, the tail closing into the eye at
    /// the end. Fire-and-forget frame loop — no repeating timer survives it.
    private func playDrawOn() {
        logoAnimation?.cancel()
        logoAnimation = Task { @MainActor [weak self] in
            let steps = 16
            for i in 0...steps {
                guard let self, !Task.isCancelled else { return }
                self.logoT = Double(i) / Double(steps)
                self.renderLogo()
                try? await Task.sleep(nanoseconds: 75_000_000)
            }
        }
    }

    /// A brief wink (shut → half → open over ~360 ms) each time the tracked
    /// task changes. Fire-and-forget like playDrawOn; a re-trigger mid-wink
    /// restarts from shut, and the last frame always reopens the eye.
    private func playWink() {
        guard logoT >= 1 else { return }   // never interrupt the draw-on
        logoAnimation?.cancel()
        logoAnimation = Task { @MainActor [weak self] in
            for w in [1.0, 0.45, 0.0] {
                guard let self, !Task.isCancelled else { return }
                self.logoWink = w
                self.renderLogo()
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    /// The pre-meeting alert (Martin's 2026-07-09 alert design): a QUIET,
    /// slow pulse through the lead-up to a meeting — a soft amber swell to
    /// less than half strength, a few seconds apart, deliberately far
    /// gentler than the start flash below. A standing loop, unlike
    /// `playWink`'s one-shot: it runs until `stopCalendarPulse` cancels it
    /// (the lead window closes at the event's start, the phase changes, or
    /// the signal turns off).
    private func startCalendarPulseIfNeeded() {
        guard calendarPulseAnimation == nil else { return }
        calendarPulseAnimation = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                // One soft swell: up to 0.45, back to 0 — ~1.5 s.
                for amount in [0.15, 0.3, 0.45, 0.3, 0.15, 0.0] {
                    guard !Task.isCancelled else { return }
                    self.logoFlash = amount
                    self.renderLogo()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                try? await Task.sleep(nanoseconds: 3_500_000_000)
            }
        }
    }

    private func stopCalendarPulse() {
        calendarPulseAnimation?.cancel()
        calendarPulseAnimation = nil
        // Don't blank a start flash that's mid-burst — it owns logoFlash now.
        if logoFlash != 0, calendarStartFlashAnimation == nil { logoFlash = 0; renderLogo() }
    }

    /// The meeting-start alert: a VIOLENT, unmissable flash — full-strength
    /// amber alternating at 150 ms for ~3 s (twenty half-cycles), then back
    /// to normal. One-shot per event occurrence (`calendarAlertsFired`);
    /// takes over from the pulse, and re-evaluates the phase when done so a
    /// back-to-back next event's own pulse resumes immediately.
    private func playCalendarStartFlash() {
        stopCalendarPulse()
        calendarStartFlashAnimation?.cancel()
        calendarStartFlashAnimation = Task { @MainActor [weak self] in
            for i in 0..<20 {
                guard let self, !Task.isCancelled else { return }
                self.logoFlash = i.isMultiple(of: 2) ? 1.0 : 0.0
                self.renderLogo()
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard let self, !Task.isCancelled else { return }
            self.logoFlash = 0
            self.renderLogo()
            self.calendarStartFlashAnimation = nil
            self.updateCalendarAlerts(now: Date())
        }
    }

    private func stopCalendarAlertAnimations() {
        calendarStartFlashAnimation?.cancel()
        calendarStartFlashAnimation = nil
        stopCalendarPulse()
        if logoFlash != 0 { logoFlash = 0; renderLogo() }
    }

    /// This device's stable sync identity + clock. The clock only attaches to
    /// the store when journal sync is enabled — until then every mutation is
    /// byte-for-byte pre-sync (hard deletes, no stamping), so the feature is
    /// inert for existing installs. The CloudKit transport arrives with the
    /// signing identity; enabling then = flip the setting, which stamps the
    /// backlog (one-shot) and starts the sync cycle on the 60 s timer.
    private(set) var syncClock: HLCClock?
    /// D2(a): backendID → owner deviceID. Empty (today) = ownership off.
    /// Becomes a synced setting with D2(b); the engine gate and its checks
    /// are already in place.
    private(set) var postingOwners: [String: String] = [:]
    private func configureSyncReplica() {
        guard settings.journalSyncEnabled, let sqlite = journal as? SQLiteJournalStore else { return }
        // Device id: persisted beside the journal so a settings-file restore
        // on another Mac doesn't clone identities.
        let idKey = "deviceID"
        let deviceID: String
        if let existing = sqlite.syncStateString(idKey) {
            deviceID = existing
        } else {
            deviceID = "mac-" + UUID().uuidString.prefix(8).lowercased()
            sqlite.setSyncStateString(idKey, deviceID)
        }
        let clock = HLCClock(deviceID: deviceID, last: sqlite.loadClockState())
        syncClock = clock
        sqlite.syncExcludedIDs = [Self.liveCheckpointID]
        sqlite.clock = clock
        try? sqlite.stampAllUnstamped(clock: clock)   // idempotent backlog stamp
        DebugLog.write("sync replica active, device \(deviceID)")
    }

    /// Community when nil. Verification is offline (embedded public key);
    /// an expired subscription key reports itself rather than silently
    /// downgrading with no explanation.
    private func revalidateLicense() {
        // Runs hourly (F16) as well as on key change — assign only on a real
        // change so the @Published pair doesn't churn SwiftUI every tick.
        func publish(_ newLicense: License?, _ newProblem: String?) {
            if license != newLicense { license = newLicense }
            if licenseProblem != newProblem { licenseProblem = newProblem }
            registry.license = newLicense   // the entitlement gate reads it
        }
        guard let key = settings.licenseKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            publish(nil, nil)
            return
        }
        switch LicenseVerifier.production.validate(key) {
        case .success(let l):
            publish(l, nil)
        case .failure(let e):
            var licenseProblem: String?
            defer { publish(nil, licenseProblem) }
            switch e {
            case .expired(let date):
                licenseProblem = "Licence expired \(date.formatted(date: .abbreviated, time: .omitted))"
            case .malformed:
                licenseProblem = "That doesn't look like an andeye licence key"
            case .badSignature:
                licenseProblem = "Licence key failed verification"
            case .unknownKeyID:
                licenseProblem = "Licence key was issued by a retired signing key — contact support for a replacement"
            case .unsupportedVersion:
                licenseProblem = "Licence key needs a newer version of Time&I"
            case .wrongProduct:
                licenseProblem = "That key is for a different andeye app"
            case .revoked:
                licenseProblem = "Licence key has been revoked"
            case .clockRollback:
                licenseProblem = "This Mac's clock appears to have gone backwards"
            case .unsupported:
                licenseProblem = "Licensing unavailable on this platform"
            }
        }
    }

    /// User-defined non-OP tasks rendered as first-class tasks.
    private func localWorkTasks() -> [WorkTask] {
        settings.localTasks.map {
            WorkTask(ref: .local($0.id), subject: $0.name, project: $0.projectName,
                     status: $0.isLeisure ? "Leisure" : "Open")
        }
    }

    /// Create (or reuse) a local task. `primeToCurrentSurface` is set ONLY by the
    /// genuine user-creation UI paths (Settings/Review): on a brand-new task it
    /// confirms the current frontmost surface to it so the live session
    /// attributes to the new task immediately, instead of staying on the
    /// previously-focused task until the user reassigns once. It must stay false
    /// for rename/merge/programmatic callers — they aren't a fresh user pick of
    /// "this surface is this task", and the same-name reuse path below returns
    /// before any priming so re-typing an existing name never re-primes.
    @discardableResult
    public func addLocalTask(name: String, isLeisure: Bool, project: String? = nil,
                            primeToCurrentSurface: Bool = false) -> TaskRef {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reuse an existing local task of the same name instead of duplicating.
        if let existing = settings.localTasks.first(where: {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return .local(existing.id)
        }
        let def = LocalTaskDef(name: trimmed, isLeisure: isLeisure, project: project)
        settings.localTasks.append(def)
        mergeLocalTasksIntoCache()
        // Genuine NEW creation from a user pick: bind the frontmost surface to it
        // now (confirm = soft 0.95 prime + learn) and lift the in-flight span,
        // the same way commitPin does, so attribution doesn't lag a focus cycle.
        // Snapshot the attributor first so the undo removes the priming too,
        // not just the task — otherwise ⌘Z left learned weight pointing at a
        // task that no longer exists.
        var primeRestore: (() -> Void)?
        if primeToCurrentSurface, let signal = tracker.currentFocusSignal {
            let savedLearning = attributor.learning
            let savedPrimed = attributor.primedSurfaces
            let savedDisplaced = attributor.displacedByCorrection
            let savedStickies = attributor.sessionStickies
            attributor.confirm(signal, task: .local(def.id), tasks: taskCache)
            persistAssociations()
            tracker.reevaluate()
            primeRestore = { [weak self] in
                guard let self else { return }
                self.attributor.replaceLearning(savedLearning)
                self.attributor.primedSurfaces = savedPrimed
                self.attributor.displacedByCorrection = savedDisplaced
                self.attributor.replaceSessionStickies(savedStickies)
                self.persistAssociations()
                self.tracker.reevaluate()
            }
        }
        registerUndo("add local task \(trimmed)") { [weak self] in
            primeRestore?()
            self?.removeLocalTask(def.id, undoable: false)
        }
        return .local(def.id)
    }

    /// Edit an existing local task in place (name / project / leisure). Keeps
    /// its id, so its history, colour and learned associations all carry over —
    /// only the display + grouping change (the local-task analogue of renaming
    /// a work package in OpenProject).
    public func updateLocalTask(_ id: UUID, name: String? = nil, project: String? = nil,
                                isLeisure: Bool? = nil) {
        guard let i = settings.localTasks.firstIndex(where: { $0.id == id }) else { return }
        let prior = settings.localTasks[i]
        if let name { settings.localTasks[i].name = name }
        if let project { settings.localTasks[i].project = project }
        if let isLeisure { settings.localTasks[i].isLeisure = isLeisure }
        guard settings.localTasks[i] != prior else { return }   // no-op edit: no undo noise
        mergeLocalTasksIntoCache()
        registerUndo("edit local task \(prior.name)") { [weak self] in
            guard let self,
                  let j = self.settings.localTasks.firstIndex(where: { $0.id == id }) else { return }
            self.settings.localTasks[j] = prior
            self.mergeLocalTasksIntoCache()
        }
    }

    /// Distinct local project names already in use, for offering as quick picks
    /// in the editor (free text is still allowed).
    public func localProjectNames() -> [String] {
        var seen: [String] = []
        for def in settings.localTasks where !seen.contains(def.projectName) {
            seen.append(def.projectName)
        }
        return seen
    }

    public func removeLocalTask(_ id: UUID, undoable: Bool = true) {
        if undoable, let idx = settings.localTasks.firstIndex(where: { $0.id == id }) {
            let def = settings.localTasks[idx]
            registerUndo("remove local task \(def.name)") { [weak self] in
                guard let self else { return }
                // Back at its original position (clamped), not appended —
                // undo restores the list the user saw, order included.
                self.settings.localTasks.insert(def, at: min(idx, self.settings.localTasks.count))
                self.mergeLocalTasksIntoCache()
            }
        }
        settings.localTasks.removeAll { $0.id == id }
        taskCache.removeAll { $0.ref == .local(id) }
    }

    /// Rebuild the local-task entries in the cache from settings so renames,
    /// project changes and removals all show through immediately — preserving
    /// each local task's recency (lastConfirmedAt lives only in the cache).
    private func mergeLocalTasksIntoCache() {
        var recency: [TaskRef: Date] = [:]
        for t in taskCache {
            if case .local = t.ref, let last = t.lastConfirmedAt { recency[t.ref] = last }
        }
        taskCache.removeAll { if case .local = $0.ref { return true }; return false }
        for var task in localWorkTasks() {
            task.lastConfirmedAt = recency[task.ref]
            taskCache.append(task)
        }
        applyJournalRecency()   // rebuilt locals keep their durable recency too
    }

    private func wireTracker() {
        tracker.onSession = { [weak self] session in
            guard let self else { return }
            var s = session
            // Consume THIS TASK's note when its slice is journalled — the
            // per-task map means a flush order surprise can never hand one
            // task's comment to another's slice.
            // Consume only the entries typed within THIS slice's span (+5 s
            // grace): the excursion carve splits one task's time into several
            // slices, and a comment typed after the return must ride the
            // POST-return part, not whichever part flushes first. Flush emits
            // chronologically, so at <= end is sufficient and nothing orphans.
            var entries = self.manualNotes[s.task] ?? []
            let cutoff = s.end.addingTimeInterval(5)
            let consumed = entries.filter { $0.at <= cutoff }
            entries.removeAll { $0.at <= cutoff }
            self.manualNotes[s.task] = entries.isEmpty ? nil : entries
            let note = Self.joinedNote(consumed)
            // Route the note per the two toggles: 'comment to tracked time'
            // attaches it to the time entry (s.comment, pushed to OP); 'comment
            // to task' also posts it to the task's activity feed, where it is
            // far easier to find. The auto window-list comment is the fallback
            // for the time entry only when no manual note was written.
            s.comment = CommentRouting.timeEntryComment(
                note: note, autoCommentText: s.comment,
                autoCommentEnabled: self.settings.autoComment,
                toTrackedTime: self.settings.commentToTrackedTime)
            try? self.journal.save(s)
            // The TASK-feed half no longer rides the flush: commitComment
            // posts it immediately to the DISPLAYED task. Consuming it here
            // let a grace-delayed flush from the PREVIOUS task steal the
            // note (Martin's comment landed on #238, 2026-07-09).
            // Tracked time counts as recency: the task you just worked on
            // belongs at the top of every pick list.
            if let i = self.taskCache.firstIndex(where: { $0.ref == s.task }) {
                self.taskCache[i].lastConfirmedAt = s.end
            }
            self.updateJournalSummary()
            // Fold the freshly-journalled slice into an adjacent same-task
            // neighbour, so live-created slices auto-merge exactly the way
            // drag-edited ones already do — one slice, one OP entry. A manual
            // Stop→Start leaves a real untracked gap, so it stays discrete;
            // a contiguous continue/revert/claim folds into the prior slice.
            Task {
                await self.coalesceAdjacent(around: s.start)
                await self.syncIfEnabled()
            }
        }
        tracker.onReview = { [weak self] segment in
            guard let self else { return }
            try? self.journal.save(segment)
            self.reloadReview()
        }
        tracker.onState = { [weak self] state in
            guard let self else { return }
            DebugLog.write("state -> \(state)")
            self.trackerState = state
            let now = Date()
            if case .tracking(let target, _) = state {
                if target != self.currentTarget {
                    // Every visit is credited to its own task's session
                    // accumulator. A brief excursion does NOT reset the task
                    // you came from — returning resumes it (Martin: 5s in
                    // scratch then back to HighgateOS shows HighgateOS's 5s, not 0).
                    if let old = self.currentTarget, let since = self.targetSince {
                        self.bankedElapsed[old, default: 0] += now.timeIntervalSince(since)
                    }
                    if case .task(let oldRef) = self.currentTarget, .task(oldRef) != target {
                        self.previousTask = oldRef
                    }
                    self.currentTarget = target
                    self.targetSince = now
                    self.visitSolid = false
                    self.taskChangedAt = now
                    // Re-anchor the crash checkpoint. checkpointLive now
                    // follows the tracker's OWNED slice (liveSliceOwner /
                    // liveSliceStart), so during a grace-pending switch it
                    // keeps covering the task being left until the commit
                    // flush — a crash mid-grace loses nothing, and an
                    // excursion+revert keeps the original anchor (B3). After
                    // a COMMITTED switch the owner is the new task and the
                    // rewrite is the correct fresh anchor.
                    self.clearCheckpoint()
                    self.checkpointLive()
                    // NB: the note is NOT cleared here. A display switch (incl.
                    // a sub-grace excursion that reverts) used to wipe the note
                    // before the slice it belonged to was flushed, losing it.
                    // The note is now consumed at flush time (onSession) and on
                    // stop, so it follows its slice correctly.
                }
            } else {
                self.currentTarget = nil
                self.targetSince = nil
                self.visitSolid = false
                self.bankedElapsed.removeAll()
                self.manualNotes.removeAll()   // stop flush already consumed them
                self.taskChangedAt = now
                self.clearCheckpoint()   // nothing in flight to recover
                Notifier.notify(symbol: "stop.circle", text: "Stopped", sound: "Basso")
            }
            self.refreshTitle(force: true)
        }
        tracker.onDebug = { message in
            DebugLog.write(message)
        }
        tracker.onSpanClosed = { [weak self] span in
            try? self?.journal.save(span)
        }
        tracker.onPrompt = { [weak self] prompt in
            guard let self else { return }
            self.lastPrompt = prompt
            switch prompt {
            case .taskChanged(let target):
                self.notifyContent(symbol: "arrow.right", text: self.name(of: target),
                                   sound: "Tink")
            case .resumeAfterIdle(let stoppedAt):
                // The gap defaults to a break (nothing recorded); offer a
                // one-tap claim onto the task we were on, in case it was work.
                if let last = self.lastTrackedTask() {
                    self.pendingGap = IdleGap(task: last.ref, from: stoppedAt, to: Date())
                    // Suppressed while presenting: the pendingGap stays
                    // claimable from the popover, only the naming banner goes.
                    self.notifyContent(symbol: "sun.max",
                                       text: "Back — tap to count the gap as \(last.subject)",
                                       sound: "Tink")
                } else {
                    Notifier.notify(symbol: "sun.max", text: "Welcome back", sound: "Tink")
                }
            case .callEnded:
                Notifier.notify(symbol: "phone.down", text: "Call ended — assign it?",
                                sound: "Tink")
            }
        }
    }

    /// Every dead-end here reports WHY via lastError — silent guards cost a
    /// debugging round-trip on 2026-06-11.
    private func rebuildClient() {
        registry.remove(id: OPBackend.stableID)
        connectedAs = nil
        let raw = settings.opBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        attributor.instanceHost = URL(string: raw)?.host ?? ""
        attributor.customRecognizer = nil
        guard !raw.isEmpty else {
            lastError = nil   // unconfigured is not an error: standalone mode
            return
        }
        guard let url = URL(string: raw), let scheme = url.scheme,
              ["http", "https"].contains(scheme), url.host != nil else {
            lastError = "OP URL must start with http:// or https:// and include a host"
            return
        }
        let key: String?
        do {
            key = try APIKeyStore.loadAPIKey()
        } catch {
            lastError = "Cannot read API key – \(error). Re-enter and Save."
            return
        }
        guard let key else {
            lastError = "No API key yet – open Settings (gear icon) and add your OpenProject API key"
            return
        }
        let op = OPBackend(baseURL: url, apiKey: key, transport: URLSessionTransport())
        op.onDebug = { DebugLog.write("backend: \($0)") }
        registry.register(op, id: OPBackend.stableID, class: .pm)
        attributor.customRecognizer = op.pageRecognizer
        lastError = nil
    }

    // MARK: - Multi-backend registry (THE andeyePro seam)

    /// Register an additional backend for the sync fan-out. THIS is the
    /// integration point the andeyePro repo calls to wire its paid connectors
    /// (XeroBackend etc.) — keep the call shape stable.
    ///
    /// - `backend`: any TaskBackend conformer; this package never needs to
    ///   know the product behind it.
    /// - `id`: a STABLE identity for this connection, unchanged across
    ///   launches — it keys the per-(session, backend) posting ledger, so a
    ///   changed id would re-post history. Mint one at connect time and
    ///   persist it with the connection's own settings.
    /// - `class`: routing role. `.pm` receives all confirmed time it
    ///   `owns()`; `.finance` receives ONLY effectively-billable time
    ///   (bypassing `owns()`), and never sees non-billable projects or
    ///   personal tasks. Registering the same id again replaces the entry
    ///   (reconnects are idempotent).
    public func register(backend: any TaskBackend, id: String,
                         class backendClass: BackendClass) {
        registry.register(backend, id: id, class: backendClass)
        Task { await syncIfEnabled() }
    }

    /// Remove a registered backend. Its ledger rows stay (history of what was
    /// posted where is never destroyed); re-registering the same id resumes
    /// exactly where it left off.
    public func unregister(backendID: String) {
        registry.remove(id: backendID)
    }

    // MARK: - Calendar signal (2026-07-09 spec)

    /// Settings ▸ Calendar's enable toggle: requests EventKit access lazily,
    /// on this FIRST turn-on only (never at launch — mirrors the
    /// Accessibility/Automation TCC precedent, "ask once, degrade silently
    /// if refused, never nag"). A refusal leaves the setting off, so
    /// Settings always reflects what's actually running — no silent
    /// partial-enable.
    public func enableCalendarSignal() {
        calendarBridge.requestAccess { [weak self] granted in
            Task { @MainActor in self?.settings.calendarSignalEnabled = granted }
        }
    }

    public func disableCalendarSignal() {
        settings.calendarSignalEnabled = false   // the didSet does the actual teardown
    }

    private func handleCalendarEvents(_ events: [CalendarEvent]) {
        calendarEventWindow = events
        // Keep the fired-alerts set bounded: an occurrence that has left the
        // rolling window can never alert again, so its key is dead weight.
        let windowKeys = Set(events.map(\.occurrenceKey))
        calendarAlertsFired.formIntersection(windowKeys)
        recomputeCalendarMatch()
        scheduleCalendarBoundaryCheck()
    }

    private func liveCalendarEvents(at now: Date, in window: [CalendarEvent]) -> [CalendarEvent] {
        window.filter { !$0.allDay && $0.start <= now && now < $0.end }
    }

    /// The live prior (§5): the first currently-live event that resolves
    /// through `calendarRules`, non-all-day (an all-day banner is never
    /// "what you're doing this minute" — §3). Feeds `currentCalendarMatch`,
    /// which in turn feeds the ranker boost, the pick-list clock badge, and
    /// the mismatch check below.
    private func recomputeCalendarMatch() {
        let now = Date()
        let live = liveCalendarEvents(at: now, in: calendarEventWindow)
        var match: (task: TaskRef, eventTitle: String, tentative: Bool)?
        for event in live {
            if let rule = CalendarMatcher.bestRule(rules: calendarRules, event: event,
                                                   order: settings.calendarMatchOrder) {
                match = (rule.target, event.title, event.tentative)
                break
            }
        }
        if match?.task != currentCalendarMatch?.task || match?.eventTitle != currentCalendarMatch?.eventTitle
            || match?.tentative != currentCalendarMatch?.tentative {
            currentCalendarMatch = match
            // Mirror into the attributor so the live prior nudges ATTRIBUTION
            // too (spec §5's other half), not just the pick-list order — and
            // refresh the memoised pick list, whose ranking input just changed.
            attributor.currentCalendarMatch = match.map { ($0.task, $0.tentative) }
            invalidatePickList()
            tracker.reevaluate()
        }
        updateCalendarMismatch(now: now)
        updateCalendarAlerts(now: now)
    }

    /// The pre-meeting alert's lead window in seconds — 0 when the alert is
    /// off, which `CalendarAlerts.phase` reads as "no pulse window at all".
    private var calendarLeadSeconds: TimeInterval {
        settings.calendarPreMeetingAlertEnabled
            ? Double(settings.calendarPreMeetingLeadMinutes) * 60 : 0
    }

    /// Drives the time-based meeting alerts (Martin's 2026-07-09 design):
    /// quiet pulse through the lead-up, violent flash at start, nothing
    /// otherwise. Pure decisions live in `CalendarAlerts` (Core, checked);
    /// this just starts/stops the animations on phase edges. Re-entered on
    /// every bridge emission, event boundary, alert-settings change, and
    /// once more when a start flash finishes (so a back-to-back next
    /// event's pulse resumes).
    private func updateCalendarAlerts(now: Date) {
        guard settings.calendarSignalEnabled else { return }   // teardown already cleared state
        switch CalendarAlerts.phase(events: calendarEventWindow, at: now,
                                    leadSeconds: calendarLeadSeconds,
                                    alreadyFired: calendarAlertsFired) {
        case .starting(let event):
            // Marked fired even when the start alert is toggled off: the
            // decision moment has passed either way, and enabling the toggle
            // seconds later must not retro-flash a meeting already underway.
            calendarAlertsFired.insert(event.occurrenceKey)
            if settings.calendarStartAlertEnabled {
                playCalendarStartFlash()
            } else {
                // No flash — but the phase may now be preMeeting for the
                // NEXT event; re-evaluate with the key marked.
                updateCalendarAlerts(now: now)
            }
        case .preMeeting:
            // A running start flash owns the mark until its burst ends (it
            // re-evaluates on completion) — never dim it into a pulse.
            guard calendarStartFlashAnimation == nil else { return }
            startCalendarPulseIfNeeded()
        case .none:
            stopCalendarPulse()
        }
    }

    /// Recomputes exactly when the next event boundary is crossed — an
    /// event entering its alert lead window, starting, exhausting its start
    /// grace, or ending (`CalendarAlerts.nextBoundary`) — event-driven, not
    /// a poll: calendars change on their own schedule, and the bridge's
    /// 5-minute fallback (+ change/wake notifications) already covers
    /// new/edited events, so this only needs to catch a boundary the
    /// CURRENT window already knows about.
    private func scheduleCalendarBoundaryCheck() {
        calendarBoundaryTimer?.invalidate()
        calendarBoundaryTimer = nil
        let now = Date()
        guard let next = CalendarAlerts.nextBoundary(events: calendarEventWindow, after: now,
                                                     leadSeconds: calendarLeadSeconds) else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: max(next.timeIntervalSince(now), 1),
                                         repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.recomputeCalendarMatch()
                self?.scheduleCalendarBoundaryCheck()
            }
        }
        // Tight: the meeting-start flash should land ON the minute, not
        // coalesced up to 5 s late (the OS may still slip a little; the
        // 60 s start grace absorbs that).
        timer.tolerance = 1
        calendarBoundaryTimer = timer
    }

    /// The off-calendar mismatch (§6): a live match exists, the tracked
    /// target disagrees with it, and that disagreement has held past the
    /// settle window. Drives ONLY the popover's "Calendar: <event> –
    /// Switch" banner — the menu-bar mark alerts on meeting TIME
    /// (`updateCalendarAlerts`), never on mismatch.
    private func updateCalendarMismatch(now: Date) {
        let mismatched: Bool
        if settings.calendarSignalEnabled, let match = currentCalendarMatch,
           case .tracking(let target, _) = trackerState, target != .task(match.task) {
            mismatched = true
        } else {
            mismatched = false
        }
        guard mismatched else {
            calendarMismatchSince = nil
            if calendarMismatchActive { calendarMismatchActive = false }
            return
        }
        if calendarMismatchSince == nil { calendarMismatchSince = now }
        let held = now.timeIntervalSince(calendarMismatchSince!) >= Self.calendarMismatchSettleSeconds
        if held, !calendarMismatchActive {
            calendarMismatchActive = true
        }
    }

    /// Teach a `CalendarRule` from a correction landing while a calendar
    /// event covers `timestamp` and either matched nothing or matched a
    /// DIFFERENT task — mirrors `Attributor.learnEmailRule`'s teach-on-
    /// correction shape (including the Unknown no-teach guard,
    /// `Target.teachesAttributor`'s calendar-side equivalent), kept on the
    /// Mac side because `CalendarRule` has no Attributor-owned ladder yet
    /// (v1 scope — see `calendarRulesStore`'s doc comment).
    private func teachCalendarRule(to ref: TaskRef, at timestamp: Date, in events: [CalendarEvent]) {
        guard settings.calendarSignalEnabled, ref != WorkTask.unknown.ref,
              let event = events.first(where: {
                  !$0.allDay && $0.start <= timestamp && timestamp < $0.end
              }) else { return }
        let existing = CalendarMatcher.bestRule(rules: calendarRules, event: event,
                                                order: settings.calendarMatchOrder)
        guard existing?.target != ref else { return }   // already correct — nothing to learn
        let rule = CalendarMatcher.learnableRule(event: event, for: ref)
        // Replace an existing UNPINNED rule at the same level+value (mirrors
        // EmailMatcher's own replacement semantics) — a pinned rule is
        // standing law and survives a correction untouched.
        calendarRules.removeAll {
            $0.level == rule.level && !$0.pinned
                && $0.value.caseInsensitiveCompare(rule.value) == .orderedSame
        }
        calendarRules.append(rule)
    }

    /// The review-queue hint's cached lookback fetch (§7) — one EventKit
    /// query per drawer refresh (60 s TTL, same shape as `fullPickList`'s
    /// own cache), not one per stack row. The window is derived, not a
    /// setting (Martin, 2026-07-09): hints should reach "as far as you have
    /// evil or unknown tasks" — the oldest unresolved row IS the horizon,
    /// so a fixed N-days window could only ever be too short or too long.
    private func calendarLookbackEvents() -> [CalendarEvent] {
        guard settings.calendarSignalEnabled else { return [] }
        let now = Date()
        if let cache = calendarLookbackCache, now.timeIntervalSince(cache.at) < 60 { return cache.events }
        let unknownAssigned = (try? journal.reviewSegments(assignedTo: .task(WorkTask.unknown.ref))) ?? []
        guard let oldest = (pendingReview + unknownAssigned).map(\.start).min() else {
            calendarLookbackCache = (now, [])
            return []
        }
        let from = min(oldest, now)
        let events = calendarBridge.events(overlapping: (start: from, end: now), from: from, to: now)
        calendarLookbackCache = (now, events)
        return events
    }

    /// The review drawer's hint chip (§7): the calendar event overlapping
    /// `stack`'s span, if any, and the task it resolves to (nil target =
    /// "show the event title, but there's no rule yet — open the picker
    /// prefilled with it"). All-day and free-marked events count here even
    /// though they never drive the live prior (§7 — "Annual leave"
    /// overlapping a queued day is still a legitimate allocation hint).
    public func calendarHint(for stack: ReviewStack) -> (eventTitle: String, target: TaskRef?)? {
        guard let event = calendarLookbackEvents()
            .first(where: { $0.start < stack.last && $0.end > stack.first }) else { return nil }
        let rule = CalendarMatcher.bestRule(rules: calendarRules, event: event,
                                            order: settings.calendarMatchOrder)
        return (event.title, rule?.target)
    }

    // MARK: - Presenting (screen share / call) banner quietening

    /// True while the user is plausibly presenting: the mic is live (a call
    /// almost always accompanies a screen share — the same signal the call
    /// detector uses) or a display is mirrored. While true, floating banners
    /// that would NAME a task or contact are suppressed (Settings ▸ "Quiet
    /// while presenting", default on): a toast naming a client on a shared
    /// screen is a privacy leak — the context-rules focus group called it
    /// "a genuine problem". Detection is deliberately conservative; a missed
    /// share suppresses nothing worse than before, a false positive costs
    /// one banner.
    public private(set) var presenting = false
    private var micLive = false
    private var displayMirrored = false

    private func refreshPresenting() {
        let now = micLive || displayMirrored
        guard now != presenting else { return }
        presenting = now
        DebugLog.write("presenting -> \(now) (mic \(micLive), mirrored \(displayMirrored))")
    }

    /// Any active display in a mirror set counts — AirPlay/sidecar/projector
    /// mirroring is the no-mic presentation case (a lecture theatre).
    private func refreshDisplayMirroring() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetActiveDisplayList(8, &ids, &count)
        displayMirrored = (0..<Int(count)).contains { CGDisplayIsInMirrorSet(ids[$0]) != 0 }
        refreshPresenting()
    }

    /// The gate for banners whose TEXT names a task or contact. Content-free
    /// banners ("Stopped", "Welcome back") go out unconditionally — only the
    /// naming ones vanish while presenting, and even then the information
    /// stays reachable in the popover.
    private func notifyContent(symbol: String?, text: String, sound: String) {
        if presenting, settings.quietWhilePresenting {
            DebugLog.write("presenting: suppressed a naming banner")
            return
        }
        Notifier.notify(symbol: symbol, text: text, sound: sound)
    }

    // MARK: - Away ("I'm leaving my desk") and scheduled stop

    @Published public private(set) var away = false
    private var scheduledStop: Date?

    /// Keep tracking the current task no matter what (idle, app switches,
    /// sleep) until cleared. Optionally lock the Mac as you leave.
    public func setAway(_ on: Bool) {
        guard case .tracking = trackerState else { away = false; tracker.away = false; return }
        away = on
        tracker.away = on
        DebugLog.write("away = \(on)")
        if on {
            notifyContent(symbol: "figure.walk", text: "Away — still tracking \(currentTaskName())",
                          sound: "Tink")
            if settings.lockOnLeave { lockScreen() }
        } else {
            notifyContent(symbol: "figure.walk.motion", text: "Back — \(currentTaskName())",
                          sound: "Tink")
        }
        refreshTitle(force: true)
    }

    /// Auto-stop at a future time (the live slice's end dragged forward, e.g.
    /// a meeting end). nil clears it.
    public func scheduleStop(at date: Date?) {
        scheduledStop = date
        if let date { DebugLog.write("scheduled stop at \(date)") }
    }

    private func lockScreen() {
        // Ctrl-Cmd-Q locks the screen on modern macOS; we already hold the
        // Accessibility right needed to post it.
        let src = "tell application \"System Events\" to key code 12 using {control down, command down}"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", src]
        try? process.run()
    }

    // MARK: - Lifecycle

    public func startUp() {
        installCrashTraps()
        installUndoKey()
        installAwayHotKey()
        // C14: read pmset OFF the launch path, then apply + cache for the
        // next launch's synchronous init.
        Task.detached(priority: .utility) { [weak self] in
            guard let fresh = PowerSettings.displaySleepSeconds() else { return }
            // Inner closure takes its OWN weak capture: referencing the outer
            // task's captured `self` var from this sendable closure is a
            // Swift 6 SendableClosureCaptures error (warned since 5.10).
            await MainActor.run { [weak self] in
                UserDefaults.standard.set(fresh, forKey: "cachedDisplaySleepSeconds")
                self?.tracker.setIdleThreshold(fresh)
            }
        }
        promoteStaleCheckpoint()   // recover any session a crash/quit left mid-flight
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // queue: .main → this runs on the main actor; assert it so the
            // call is synchronous (must finish before the app quits).
            MainActor.assumeIsolated {
                self?.checkpointLive()
                self?.awayHotKey = nil   // unregister the Carbon hotkey before quit
                self?.removeUndoKey()    // C13: release the ⌘Z local monitor
            }
        }
        Notifier.enabled = settings.systemNotifications
        sensors.requestPermissions()
        sensors.onEvent = { [weak self] event in
            switch event {
            case .input: break   // 2 s ticks would drown the log
            default: DebugLog.write("sensor \(event)")
            }
            // The call detector's own signal doubles as the presenting cue —
            // banner quietening must flip BEFORE the tracker reacts to the
            // same event (a call's first switch banner is exactly the leak).
            if case .microphone(let active, _) = event, active != self?.micLive {
                self?.micLive = active
                self?.refreshPresenting()
            }
            self?.tracker.handle(event)
        }
        pushOwnEmail()
        DebugLog.write("startUp: AX trusted=\(sensors.accessibilityTrusted) grace=\(settings.switchGraceSeconds)s")
        sensors.start()
        // Mirrored-display half of the presenting cue: rescan on every screen
        // topology change (projector/AirPlay attach) and once now.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplayMirroring() }
        }
        refreshDisplayMirroring()
        // Calendar signal: `settings`'s own didSet drives start/stop on every
        // LATER toggle, but its initial assignment in init() runs before
        // `self` is fully initialized (two-phase init), so it never fired —
        // start here explicitly if a past session already left it enabled
        // (permission itself was already granted then; this never prompts).
        if settings.calendarSignalEnabled {
            calendarBridge.onEvent = { [weak self] events in self?.handleCalendarEvents(events) }
            calendarBridge.start(excludedCalendarNames: settings.calendarExcludedNames)
        }
        Notifier.requestAuthorization()
        titleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let stop = self.scheduledStop, Date() >= stop {
                    self.scheduledStop = nil
                    if self.away { self.setAway(false) }
                    self.userStopped()
                }
                self.refreshTitle(force: false)
                self.updateCalendarMismatch(now: Date())
            }
        }
        taskRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkpointLive()        // crash-safety: persist the in-flight session
                await self?.refreshTasks()
                await self?.syncIfEnabled()   // retry path for failed/late pushes
            }
        }
        // Nothing here is deadline-sensitive to the second: let the OS batch
        // the wakeup with others (checkpointTimer below already does).
        taskRefreshTimer?.tolerance = 5
        // Tight crash-safety cadence: checkpointLive itself no-ops unless we're
        // .tracking, so a stopped app does nothing here. The 5 s tolerance lets
        // the OS batch this with other timer fires — no extra wakeups.
        let cp = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkpointLive() }
        }
        cp.tolerance = 5
        checkpointTimer = cp
        Task { await refreshTasks() }
        reloadReview()
        playDrawOn()
    }

    /// Change-detection instead of interval gating: a 1 Hz timer gated by
    /// ">= 1 s since last refresh" skipped alternate ticks (even-seconds bug)
    /// and froze the text across the minute boundary. Computing every tick
    /// and assigning only on change gives 1 Hz updates in the first minute
    /// and per-minute after — by construction, since that is when the string
    /// changes.
    private func refreshTitle(force: Bool) {
        let newText: String
        let newSizingTemplates: [String]
        let newColour: NSColor
        switch trackerState {
        case .stopped:
            newText = "–"
            newSizingTemplates = []
            newColour = MenuTitle.colour(certainty: nil, lowHex: settings.colourLow,
                                         highHex: settings.colourHigh)
            lastDisplayedTarget = nil
        case .tracking(let target, let certainty):
            let now = Date()
            let running = targetSince.map { now.timeIntervalSince($0) } ?? 0
            // When THIS task's current visit survives the grace it has "taken
            // over": every OTHER task's session is now ended (a real stint
            // elsewhere starts fresh on return). Brief excursions never reach
            // here, so they leave the other accumulators intact — the clock
            // shows the current contiguous session, i.e. what would post to OP.
            if !visitSolid, running >= settings.switchGraceSeconds {
                visitSolid = true
                bankedElapsed = bankedElapsed.filter { $0.key == target }
            }
            // tracker.liveSliceStart spans the whole contiguous stretch —
            // INCLUDING sub-grace excursion windows that reverted back to this
            // task — so it recovers re-tagged seconds the per-visit banked figure
            // drops; banked+running is the fallback when no live slice is open.
            // ONLY when the displayed task owns the open slice, though: during
            // a grace-pending switch the display already follows the new task,
            // and pairing it with the old slice's clock showed the old task's
            // elapsed under the new task's name. An excursion shows its own
            // visit clock (what would post if the switch commits).
            let ownsSlice = tracker.liveSliceOwner == target
            let elapsed = MenuTitle.displayedElapsed(
                liveSliceStart: ownsSlice ? tracker.liveSliceStart : nil,
                bankedFallback: bankedElapsed[target, default: 0],
                running: running, now: now)
            let body = MenuTitle.text(elapsed: elapsed, certainty: certainty,
                                      showPercent: settings.showPercent)
            // Wink when the TRACKED TASK changes — the eye acknowledging the
            // switch — never on time ticks. stopped→tracking (nil last) is a
            // start, not a switch, so it doesn't wink; the draw-on owns app
            // launch instead.
            if let last = lastDisplayedTarget, last != target { playWink() }
            lastDisplayedTarget = target
            // Elapsed WITHOUT the task name — the popover already shows the task
            // as its headline, so menuText (which carries the name for the menu
            // bar) would duplicate it there. MUST be change-gated like its
            // neighbours: an unconditional assign fires objectWillChange at
            // 1 Hz, re-rendering every open window (timeline, pie, settings)
            // every second, 24/7, even where elapsedText is never shown.
            if force || elapsedText != body { elapsedText = body }
            // menuTaskChars == 0 → withTaskName returns the body unchanged (off).
            newText = MenuTitle.withTaskName(name(of: target), chars: settings.menuTaskChars,
                                             body: body)
            // Same task-name suffix on every template as on the real text —
            // keeps every candidate a full apples-to-apples string, though the
            // suffix is a constant shift and doesn't change which one is widest.
            newSizingTemplates = MenuTitle.sizingTemplates(
                elapsed: elapsed, certainty: certainty, showPercent: settings.showPercent
            ).map { MenuTitle.withTaskName(name(of: target), chars: settings.menuTaskChars, body: $0) }
            newColour = MenuTitle.colour(certainty: certainty, lowHex: settings.colourLow,
                                         highHex: settings.colourHigh)
        }
        // Measure the text column from the sizing candidates plus the live
        // text (belt-and-braces: the live text should never exceed its
        // bracket's templates, but if it ever does the reservation grows
        // instead of clipping). Same font the label image draws with.
        let newWidth = (newSizingTemplates + [newText])
            .map { AndeyeLogoImage.textWidth($0) }
            .max().map { ($0 + 1).rounded(.up) } ?? 0
        var labelChanged = force
        if force || newText != menuText { menuText = newText; labelChanged = true }
        if force || newSizingTemplates != menuSizingTemplates {
            menuSizingTemplates = newSizingTemplates
        }
        if force || newWidth != menuReservedWidth {
            menuReservedWidth = newWidth
            labelChanged = true
        }
        if force || !newColour.isEqual(menuColour) {
            menuColour = newColour
            labelChanged = true   // the mark carries the certainty tint
        }
        // The text lives INSIDE the label image now, so the image re-renders
        // on ANY visible change — text, reservation, or tint.
        if labelChanged { renderLogo() }
    }

    // MARK: - Crash-safe recording

    /// A fixed-id provisional row mirroring the in-flight session, rewritten
    /// every minute and on quit. Never pushed to OP (pushedToOP=true sentinel).
    /// If a crash leaves it behind, startUp promotes it to a real slice — so
    /// tracked time survives even an unclean exit.
    static let liveCheckpointID = UUID(uuidString: "00000000-0000-0000-0000-0000C0FFEE00")!

    public func checkpointLive() {
        // Anchor at the tracker's OWNED live slice, not the display target
        // (reviewer B3): the display flips at PEND time, before any flush, so
        // a checkpoint keyed to targetSince was destroyed by every
        // provisional switch — and a sub-grace excursion + revert re-anchored
        // it at the REVERT moment, so a crash lost everything before the
        // excursion. liveSliceOwner/liveSliceStart cover exactly what a
        // flush would journal.
        guard case .tracking(_, let certainty) = trackerState,
              case .task(let ref)? = tracker.liveSliceOwner else { return }
        let since = tracker.liveSliceStart ?? targetSince ?? Date()
        try? journal.update(Session(id: Self.liveCheckpointID, task: ref, start: since,
                                    end: max(Date(), since),   // clock stepped back: never end<start (C9)
                                    certainty: certainty, pushedToOP: true))
    }

    private func clearCheckpoint() {
        try? journal.deleteSession(Self.liveCheckpointID)
    }

    private func promoteStaleCheckpoint() {
        let all = (try? journal.allSessions()) ?? []
        let stale = all.first { $0.id == Self.liveCheckpointID }
        // Real journalled slices only (drop the checkpoint row itself) — these
        // are what a switch-flush would already have written, so an overlap with
        // them means promoting the checkpoint would duplicate time + OP entry.
        let journalled = all.filter { $0.id != Self.liveCheckpointID }
        guard let recovered = CheckpointRecovery.recover(
            stale: stale, floor: 60, alreadyJournalled: journalled) else {
            clearCheckpoint(); return
        }
        // Recover crash-lost time as a real, pushable slice.
        try? journal.save(Session(task: recovered.task, start: recovered.start,
                                  end: recovered.end, certainty: recovered.certainty,
                                  comment: "recovered after restart"))
        clearCheckpoint()
        DebugLog.write("recovered crash-lost session \(recovered.start)..\(recovered.end)")
    }

    // MARK: - User actions

    public func currentTaskName() -> String {
        if case .tracking(let target, _) = trackerState { return name(of: target) }
        return "Not tracking"
    }

    /// The cached WorkTask currently being tracked, or nil when not tracking a
    /// backend/local task (leisure, do-not-track, or an uncached ref). Lets the
    /// popover resolve the running task's effective billability the same way a
    /// pick-list row does. Limitation: a ref not in `taskCache` yields nil, so
    /// no billable glyph shows for it — the cache is the only project-context
    /// source the popover has.
    public func currentTask() -> WorkTask? {
        guard case .tracking(.task(let ref), _) = trackerState else { return nil }
        return taskCache.first { $0.ref == ref }
    }

    public func name(of target: Target) -> String {
        switch target {
        case .doNotTrack: return "Do not track"
        case .task(let ref):
            // The Unknown sentinel is never seeded into taskCache (so it can
            // never leak into the pick list) — resolve it directly instead.
            if ref == WorkTask.unknown.ref { return WorkTask.unknown.subject }
            if let t = taskCache.first(where: { $0.ref == ref }) { return t.subject }
            return ref.isRemote ? ref.fallbackLabel : "Leisure"
        }
    }

    /// Make recency durable across restarts. `lastConfirmedAt` is otherwise an
    /// in-memory field (stamped on pick and on live-slice flush) that resets to
    /// nil every launch, so a heavily-tracked task silently drops out of the
    /// recent pick-list after an app restart — e.g. the morning after an
    /// overnight gap, the exact "where did Client Work go?" symptom. The journal
    /// is the durable record of what was actually tracked, so we re-derive each
    /// task's last-tracked time from it and take the later of that and any
    /// in-memory value.
    private func applyJournalRecency() {
        // Aggregate query, NOT allSessions(): this runs on the 60 s refresh,
        // and a full-table decode here grows without bound with history.
        let lastEnd = (try? journal.latestEndByTask(excluding: [Self.liveCheckpointID])) ?? [:]
        for i in taskCache.indices {
            if let l = lastEnd[taskCache[i].ref] {
                taskCache[i].lastConfirmedAt =
                    max(taskCache[i].lastConfirmedAt ?? .distantPast, l)
            }
        }
    }

    /// Memoised pick list. SwiftUI bodies call `fullPickList()`/`searchTasks()`
    /// on every render at several sites (popover switch list, timeline pickers,
    /// Spent reassign, Review assign bar), and the full ranker sort walks every
    /// task with learning lookups. The cache is invalidated by `taskCache.didSet`
    /// (element mutations fire it too, so lastConfirmedAt bumps count), settings
    /// changes and every learning write; the short TTL covers the ranking's
    /// time-decay term without a per-render resort.
    private var pickListCache: (tasks: [WorkTask], at: Date)?
    private var searchCache: (query: String, basedOn: Date, results: [WorkTask])?
    private func invalidatePickList() {
        pickListCache = nil
        searchCache = nil
    }

    /// The popover / picker ordering: recently-confirmed tasks first (most
    /// recent first), then everything else ranked. The whole list — it's
    /// scrollable and filterable, so there's no recent/likely cap any more.
    public func fullPickList() -> [WorkTask] {
        let now = Date()
        if let c = pickListCache, now.timeIntervalSince(c.at) < 5 { return c.tasks }
        let ranked = TaskRanker(config: RankingConfig(statusOrder: settings.statusOrder,
                                                      currentUser: connectedAs))
            .recentThenRanked(taskCache, at: now, learning: attributor.learning,
                              calendarMatch: currentCalendarMatch.map { (task: $0.task, tentative: $0.tentative) })
        pickListCache = (ranked, now)
        return ranked
    }

    public func userPicked(_ task: WorkTask) {
        // "Auto-dismisses after ~8s or on next pick" (spec §6) — a fresh pick
        // always closes out a leftover learn/fire notice from the one before.
        learnNotice = nil
        fireNotice = nil
        siteLearnNotice = nil
        siteFireNotice = nil
        tracker.confirm(task: task.ref, at: Date())
        // Re-emit the unchanged surface so span accrual restarts immediately
        // (B1's other half): after a manual stop the sensor's dedup key
        // still holds the current window, and without this the new task
        // accrues nothing until the next window change or input pause.
        sensors.reemitCurrentSurface()
        if let i = taskCache.firstIndex(where: { $0.ref == task.ref }) {
            taskCache[i].lastConfirmedAt = Date()
        }
        teachCalendarRule(to: task.ref, at: Date(), in: calendarEventWindow)
        persistAssociations()
        lastPrompt = nil
    }

    private func persistAssociations() {
        invalidatePickList()   // every learning/pin/rule write lands here
        try? learningStore.save(attributor.learning)
        try? primedStore.save(attributor.primedSurfaces)
        try? pinsStore.save(attributor.pins)
        try? emailRulesStore.save(attributor.emailRules)
        try? siteRulesStore.save(attributor.siteRules)
        try? calendarRulesStore.save(calendarRules)
        scheduleRetroPass()
    }

    /// The full broad→narrow identity of the current focus surface plus the
    /// smart default prefix length — the pin editor's starting state. nil when
    /// there's nothing to pin (no current surface).
    public func pinDraft() -> (kind: PinScope.Kind, segments: [String], defaultCount: Int)? {
        guard let signal = tracker.currentFocusSignal,
              let id = PinScope.identity(of: signal) else { return nil }
        return (id.kind, id.segments,
                PinScope.defaultPrefixCount(kind: id.kind, segments: id.segments))
    }

    /// The email-flavoured identity chain for the current focus surface, when
    /// it carries email evidence (a detected mail host, or captured
    /// correspondents/subject) — the pin editor's grain ladder source
    /// (pin-editor slice of the 2026-07-03 context-rules spec, §5.1/Option B).
    /// nil for a plain surface, where the classic Components strip (fed by
    /// `pinDraft()`) is unaffected.
    public func pinEmailIdentity() -> ContextIdentity? {
        guard let signal = tracker.currentFocusSignal else { return nil }
        let identity = attributor.identity(of: signal)
        guard identity.segments.contains(where: { $0.kind.isEmailGrain }) else { return nil }
        return identity
    }

    /// Commit a component-prefix pin: the chosen prefix is ALWAYS `ref` at
    /// 100 %. When `replacingID` is given (editing an existing pin) the same id
    /// is reused, so a changed scope updates in place instead of duplicating.
    public func commitPin(kind: PinScope.Kind, prefix: [String], to ref: TaskRef,
                          replacingID: UUID? = nil, priority: Int? = nil) {
        guard !prefix.isEmpty else { return }
        commitPin(rule: .components(PinScope(kind: kind, prefix: prefix)),
                  to: ref, replacingID: replacingID, priority: priority)
    }

    /// Commit any pin rule (components OR a boolean expression) — the general
    /// path the Expression editor and the AI mode both feed into. `replacingID`
    /// reuses the id so editing updates in place instead of duplicating.
    public func commitPin(rule: PinRule, to ref: TaskRef, replacingID: UUID? = nil,
                          priority: Int? = nil) {
        let savedPins = attributor.pins   // upsert may REPLACE — snapshot, don't just unpin
        let pin = Pin(id: replacingID ?? UUID(), rule: rule, task: ref, priority: priority)
        attributor.upsert(pin)
        persistAssociations()
        tracker.reevaluate()   // lift the live session to 100% now, not on next focus
        registerUndo(replacingID == nil ? "pin \(name(of: .task(ref)))" : "edit pin") { [weak self] in
            guard let self else { return }
            self.attributor.pins = savedPins
            self.persistAssociations()
            self.tracker.reevaluate()
            self.objectWillChange.send()
        }
        objectWillChange.send()
    }

    /// The pin (+ its task) covering the current focus surface, if any — drives
    /// the popover's 📌 badge. nil for ranked / soft-primed surfaces.
    public var currentPin: (pin: Pin, task: WorkTask)? {
        guard let signal = tracker.currentFocusSignal,
              let pin = attributor.matchingPin(for: signal),
              let task = taskCache.first(where: { $0.ref == pin.task }) else { return nil }
        return (pin, task)
    }

    /// Clear the pin covering the current focus surface (the badge's ✕).
    public func unpinCurrentSurface() {
        guard let signal = tracker.currentFocusSignal,
              let pin = attributor.matchingPin(for: signal) else { return }
        let savedPins = attributor.pins
        attributor.unpin(id: pin.id)
        persistAssociations()
        registerUndo("unpin \(name(of: .task(pin.task)))") { [weak self] in
            guard let self else { return }
            self.attributor.pins = savedPins
            self.persistAssociations()
            self.tracker.reevaluate()
            self.objectWillChange.send()
        }
        objectWillChange.send()
    }

    public func userStopped() {
        if away { away = false; tracker.away = false }
        scheduledStop = nil
        tracker.stop(at: Date())
    }

    /// "Change to": relabel the RUNNING session to `ref`, keeping its elapsed
    /// time (the mis-attributed time moves to the right task, the clock does
    /// not reset). Distinct from userPicked, which starts a fresh session.
    public func changeCurrentTask(to ref: TaskRef, undoable: Bool = true) {
        guard case .tracking(let oldTarget, _) = trackerState, .task(ref) != oldTarget else { return }
        // "Auto-dismisses after ~8s or on next pick" (spec §6) — a genuine
        // reassign counts as the next pick too.
        learnNotice = nil
        fireNotice = nil
        siteLearnNotice = nil
        siteFireNotice = nil
        // Make the popover relabel reversible: ⌘Z relabels back to the task it
        // was on (the inverse is itself a change, marked non-undoable so it
        // doesn't stack endlessly). The relabel also TEACHES (surface assign +
        // calendar rule below); the inverse's own re-relabel would only
        // counter-teach, so snapshot the learned state and restore it after —
        // ⌘Z leaves the attributor exactly as it stood, not approximately.
        if undoable, case .task(let oldRef) = oldTarget {
            let savedLearning = attributor.learning
            let savedPrimed = attributor.primedSurfaces
            let savedDisplaced = attributor.displacedByCorrection
            let savedStickies = attributor.sessionStickies
            let savedCalendarRules = calendarRules
            registerUndo("change to \(name(of: oldTarget))") { [weak self] in
                guard let self else { return }
                self.changeCurrentTask(to: oldRef, undoable: false)
                self.attributor.replaceLearning(savedLearning)
                self.attributor.primedSurfaces = savedPrimed
                self.attributor.displacedByCorrection = savedDisplaced
                self.attributor.replaceSessionStickies(savedStickies)
                self.calendarRules = savedCalendarRules
                self.persistAssociations()
                self.tracker.reevaluate()
            }
        }
        let now = Date()
        let elapsed = (bankedElapsed[oldTarget] ?? 0)
            + (targetSince.map { now.timeIntervalSince($0) } ?? 0)
        let keptNote = manualNote
        tracker.relabelCurrentSession(to: ref)   // re-tags spans; fires onState
        // Durably TEACH this window→task, not just the soft prime relabel does:
        // otherwise the learned model re-wins and the window snaps back to its
        // old task when focus returns (Martin: "Change to andeye" kept
        // reverting to a 70%-certain KLARC on every return).
        if let signal = tracker.currentFocusSignal {
            attributor.assign(signal, target: .task(ref), tasks: taskCache)
            persistAssociations()
        }
        teachCalendarRule(to: ref, at: now, in: calendarEventWindow)
        // Preserve the displayed clock onto the corrected task and continue.
        currentTarget = .task(ref)
        targetSince = now.addingTimeInterval(-elapsed)
        bankedElapsed = [:]
        visitSolid = true
        manualNote = keptNote
        if let i = taskCache.firstIndex(where: { $0.ref == ref }) {
            taskCache[i].lastConfirmedAt = now
        }
        persistAssociations()
        refreshTitle(force: true)
    }

    public func userPostponed() {
        lastPrompt = nil
    }

    /// Turn the live (ongoing) slice into a real, editable timeline slice ending
    /// now, while continuing to track the same task from now — so the live track
    /// can be edited without stopping it. Returns the just-journalled slice.
    @discardableResult
    public func commitLiveSlice() -> Session? {
        guard case .tracking(.task(let ref), _) = trackerState else { return nil }
        let now = Date()
        let from = tracker.liveSliceStart ?? targetSince ?? now
        tracker.commitLive(at: now)
        // Keep the displayed clock continuous: the committed time is now banked,
        // the fresh run starts at `now`.
        targetSince = now
        bankedElapsed = [.task(ref): now.timeIntervalSince(from)]
        visitSolid = true
        updateJournalSummary()
        refreshTitle(force: true)
        // Search from the live slice's own start (not the calendar day) so a
        // slice that began before midnight is still found.
        return ((try? journal.sessions(from: from.addingTimeInterval(-2), to: now)) ?? [])
            .filter { $0.task == ref && $0.id != Self.liveCheckpointID }
            .max(by: { $0.end < $1.end })
    }

    // MARK: - Per-task workspaces (window layouts)

    // Workspace layouts were cut 2026-06-23: geometry-only restore (no Chrome
    // tab/URL, no terminal cwd) plus unreliable multi-window/Spaces spawning
    // made it net-negative. See TODO.md for what re-adding it would require.

    /// One-tap: the idle gap WAS work — record it on its task, keeping the
    /// window detail that was captured around it. Zero taps leaves it a break.
    public func claimIdleGap() {
        guard let g = pendingGap else { return }
        pendingGap = nil
        Task {
            // ONE ⌘Z step for the whole claim: the created slice, the
            // follow-on merge into the prior same-task slice, and the gap
            // offer itself (undo re-surfaces it, so the decision is fully
            // reversible — not just the data).
            await undoGroup("claim idle gap") {
                registerUndo("restore idle-gap offer") { [weak self] in
                    self?.pendingGap = g
                }
                await createTimelineSession(Session(task: g.task, start: g.from, end: g.to,
                                                    certainty: 0.95, comment: "worked through idle gap"),
                                            origin: .manual)
                // Continue, don't split: merge the claimed gap into the prior
                // same-task slice it butts up against, so "continue when away"
                // yields one continuous slice / one OP entry.
                await coalesceAdjacent(around: g.from)
            }
        }
    }

    public func dismissIdleGap() { pendingGap = nil }

    /// One committed comment from the popover bar (enter pressed). Two
    /// destinations, deliberately split (Martin, 2026-07-09 — his
    /// comment posted to #238):
    /// - The TASK's activity feed gets it NOW, addressed to the task the
    ///   popover is DISPLAYING — what the user sees is what gets commented.
    ///   Riding the flush was the bug: the note went to whichever slice
    ///   happened to close next, which during a grace-delayed switch is the
    ///   PREVIOUS task.
    /// - The tracked-time comment still rides the slice (accumulated into
    ///   manualNote, consumed at flush) — it belongs to the time entry.
    public func commitComment(_ text: String) {
        guard case .tracking(let target, _) = trackerState,
              case .task(let ref) = target else { return }
        let priorNotes = manualNotes[ref]
        manualNotes[ref, default: []].append((text: text, at: Date()))
        // The timeline's cached fetch composes the live slice's comment from
        // these notes: bump the revision so an open timeline shows the comment
        // the moment it's committed, not on the next 30 s reload.
        journalRevision &+= 1
        // ⌘Z takes the note back out of the in-flight slice. Once the slice
        // has FLUSHED the note lives on a journal row (edit it there); and a
        // copy already posted to the task's activity feed stays posted — an
        // undo never silently rewrites a backend's history.
        registerUndo("comment \(name(of: target))") { [weak self] in
            guard let self else { return }
            self.manualNotes[ref] = priorNotes
            self.journalRevision &+= 1
        }
        // A commented visit is work by attestation: pin it so its slice
        // surfaces however short (Martin, 2026-07-09 — three quick test
        // comments once collapsed into one slice on one task).
        tracker.pinCurrentVisit(target: target)
        guard let taskNote = CommentRouting.taskComment(note: text,
                                                        toTask: settings.commentToTask)
        else { return }
        Task { await self.postTaskComment(ref: ref, note: taskNote) }
    }

    /// Post a note to the task's activity feed (OP work-package comment), so
    /// 'comment to task' notes are findable on the task itself. With no backend
    /// attached this is a no-op today; standalone storage lands with the
    /// backend-seam refactor (a local timestamped comment list).
    private func postTaskComment(ref: TaskRef, note: String) async {
        // Backend path when it exists (ownership-guarded: never an .op note
        // to Xero or vice versa); EVERY other case — .local task, standalone,
        // a backend without task comments, or a failed post — lands in the
        // journal's task_comments store instead of vanishing.
        if let backend, backend.supportsTaskComments,
           backend.owns(ref), let taskID = ref.backendTaskID {
            do {
                try await backend.addTaskComment(taskID: taskID, text: note)
                DebugLog.write("posted task comment to task #\(taskID)")
                return
            } catch {
                lastError = "\(backend.displayName) task comment failed: \(error) — kept locally"
            }
        }
        try? journal.saveTaskComment(ref, text: note, at: Date())
        DebugLog.write("stored local task comment for \(ref.storageKey)")
    }

    public func assignReview(_ ids: [UUID], to target: Target, undoable: Bool = true) {
        // Unknown task category §4: sweeping to Unknown also re-points its
        // overlapping unpushed low-certainty sessions (no lift — tidying,
        // not a confidence gain), computed BEFORE the segments' own state
        // changes so the overlap check sees the queue as it stood.
        let repoints = target == .task(WorkTask.unknown.ref)
            ? repointSessionsToUnknown(ids) : []
        if undoable {
            let learningSnapshot = attributor.learning
            let primedSnapshot = attributor.primedSurfaces
            let pinsSnapshot = attributor.pins
            let stickiesSnapshot = attributor.sessionStickies
            let calendarSnapshot = calendarRules
            registerUndo("assign \(ids.count) review rows") { [weak self] in
                guard let self else { return }
                try? self.journal.assign(ids, to: nil)
                for r in repoints {
                    if var s = try? self.journal.session(id: r.sessionID) {
                        s.task = r.priorTask
                        try? self.journal.update(s)
                    }
                }
                self.attributor.replaceLearning(learningSnapshot)
                self.attributor.primedSurfaces = primedSnapshot
                self.attributor.pins = pinsSnapshot
                // The assign also wrote stickies and (possibly) a calendar
                // rule — restore those too, so ⌘Z really is "as it stood".
                self.attributor.replaceSessionStickies(stickiesSnapshot)
                self.calendarRules = calendarSnapshot
                self.persistAssociations()
                self.reloadReview()
            }
        }
        try? journal.assign(ids, to: target)
        // Sweeping to Unknown is an explicit "don't know", not a correction —
        // it must never teach the attributor (Target.teachesAttributor is
        // false only for the Unknown sentinel).
        if target.teachesAttributor {
            // Teach from EVERY distinct surface covered by the selection —
            // the old first(where:) taught only the first row (approvals-
            // drawer spec §1 side-bug), throwing away the rest of the evidence.
            let signals = pendingReview.teachingSignals(for: Set(ids))
            for signal in signals {
                attributor.assign(signal, target: target, tasks: taskCache)
            }
            // Calendar teach, same Unknown-guarded shape as the live paths —
            // the review queue's own signals are typically PAST timestamps
            // (unlike userPicked/changeCurrentTask's "now"), so this checks
            // the cached lookback window rather than the live one.
            if case .task(let ref) = target {
                let lookback = calendarLookbackEvents()
                for signal in signals {
                    teachCalendarRule(to: ref, at: signal.timestamp, in: lookback)
                }
            }
            if !signals.isEmpty { persistAssociations() }
        }
        reloadReview()
    }

    /// Unknown task category §4: sessions overlapping the just-swept
    /// segments, unpushed and still below the push bar, re-point to Unknown
    /// at their CURRENT certainty. Returns what changed so the caller's undo
    /// closure can restore each session's prior task.
    private func repointSessionsToUnknown(_ ids: [UUID]) -> [UnknownRepoint] {
        let sweptSegments = pendingReview.filter { ids.contains($0.id) }
        guard !sweptSegments.isEmpty else { return [] }
        let sessions = ((try? journal.allSessions()) ?? []).filter { $0.id != Self.liveCheckpointID }
        let repoints = UnknownSweep.sessionsToRepoint(segments: sweptSegments, sessions: sessions,
                                                      bar: settings.certaintyAutoPushThreshold)
        for r in repoints {
            if var s = try? journal.session(id: r.sessionID) {
                s.task = WorkTask.unknown.ref
                try? journal.update(s)
            }
        }
        return repoints
    }

    /// The drawer's default shape (Martin's stack-by-default choice): every
    /// pending row collapsed to ONE decision per distinct surface.
    public func reviewStacks() -> [ReviewStack] {
        pendingReview.stacked()
    }

    /// The drawer badge's count — stacks, not raw rows (Hick's law: present
    /// ~5 decisions, never 1,040).
    public var pendingDecisionCount: Int {
        reviewStacks().count
    }

    /// Accept a whole stack at once: assigns every segment in it via the
    /// existing `assignReview`, which already teaches from every distinct
    /// surface it covers (a stack IS one surface, so this teaches once).
    public func assignStack(_ stack: ReviewStack, to target: Target) {
        assignReview(stack.segments.map(\.id), to: target)
    }

    /// Push the settings' own-address list into the capture engine (never
    /// reported as counterparties). Called at startup and on settings change.
    private func pushOwnEmail() {
        let own = EmailSignal.ownEntrySets(settings.ownEmailEntries)
        sensors.setOwnEmail(addresses: own.addresses, domains: own.domains)
    }

    /// The synthetic `ActivitySignal` for a review-queue row — the same
    /// construction `assignReview` feeds the attributor above, exposed so
    /// the review queue's post-assign grain footer (2026-07-03 spec §5.3,
    /// "later polish") can build the identity of what it JUST taught,
    /// mirroring `PopoverView`'s `justPicked` tuple. Delegates to the row's
    /// own reconstruction so the email evidence captured at queue time rides
    /// along — that evidence is what lets the footer offer correspondent/
    /// domain/subject grains rather than only the whole mail system.
    public func signal(for segment: ReviewSegment) -> ActivitySignal {
        segment.signal
    }

    private func reloadReview() {
        // Review-queue admission floor (Martin: "extremely little value in
        // having a user spend time categorising a <1m slice"): filtered HERE,
        // the ONE place the visible queue materialises, so every consumer —
        // the drawer's stacks, the badge count, the AI prompt, multi-select
        // assign — sees the same floored queue, and rows persisted before the
        // floor existed vanish on the next reload with no migration. The
        // journal keeps sub-floor rows untouched — the floor thins the
        // drawer, never the timeline or journal — and a load-time filter
        // also means a lowered floor setting reveals the rows it had been
        // hiding, instead of their having been dropped for good at flush.
        pendingReview = ((try? journal.pendingReview()) ?? [])
            .meetingReviewFloor(settings.reviewFloorSeconds)
        retroDigest = (try? journal.retroDigests(limit: 200)) ?? []
        updateJournalSummary()
    }

    // MARK: - Retro-acceptance (approvals-drawer spec §3)

    /// A correction burst (a pin, several quick assigns) settles into ONE
    /// pass this long after the last mutation, instead of re-scoring the
    /// whole queue on every single write.
    private static let retroPassDebounceSeconds: TimeInterval = 2
    /// Per-pass ceiling so a large queue can't beachball the main thread.
    private static let retroPassCap = 500
    private var retroPassTimer: Timer?

    private func scheduleRetroPass() {
        retroPassTimer?.invalidate()
        retroPassTimer = Timer.scheduledTimer(withTimeInterval: Self.retroPassDebounceSeconds,
                                              repeats: false) { [weak self] _ in
            Task { @MainActor in self?.runRetroPass() }
        }
    }

    /// Re-score the pending queue against the retro bar (the push threshold —
    /// Martin's answer to open question (d): a bulk clear should meet the
    /// same bar as unattended posting) and apply whatever clears. Scoring
    /// reuses the attributor's own `explain()` — the same path `explainSpan`/
    /// the Evidence Card read — so a retro clearance can never disagree with
    /// what a human would see opening that row right now.
    private func runRetroPass() {
        let bar = settings.certaintyAutoPushThreshold
        // Unknown task category §3: segments already swept to Unknown left
        // pendingReview(), so they need re-adding here to be reclaimable — a
        // later confident rule scores them exactly like the pending queue and
        // claims them back out, "feed it pending + unknown-assigned segments
        // together" (RetroAcceptance.plan is agnostic to where a segment came
        // from).
        let unknownAssigned = (try? journal.reviewSegments(assignedTo: .task(WorkTask.unknown.ref))) ?? []
        // The re-add obeys the same admission floor as the queue itself
        // (pendingReview is already floored by reloadReview): a sub-floor
        // Unknown glance is exactly the kind of row the floor exists to keep
        // out of circulation, so no path may resurrect it — while an Unknown
        // segment that itself meets the floor stays reclaimable as ever.
        let combined = (pendingReview + unknownAssigned)
            .meetingReviewFloor(settings.reviewFloorSeconds)
        let pending = Array(combined.prefix(Self.retroPassCap))
        guard !pending.isEmpty else { return }
        let cache = taskCache
        let attributor = self.attributor
        // Scored at the SEGMENT's own start time (like explainSpan), so the
        // time-of-day prior matches what actually happened, not "now".
        let scoring: (ActivitySignal) -> (target: Target, score: Double)? = { signal in
            let explanation = attributor.explain(signal, tasks: cache, now: signal.timestamp)
            guard let chosen = explanation.chosen else { return nil }
            return (chosen, explanation.chosenScore)
        }
        // Lifts must never touch the live-checkpoint sentinel (its task/
        // certainty are crash-recovery state, not history) NOR an already-
        // pushed session — re-pointing a pushed row's task would propagate an
        // amendment to the backend off the back of a bulk pass. The retro
        // lift exists for the UNPUSHED low-certainty pile only.
        let sessions = ((try? journal.allSessions()) ?? [])
            .filter { $0.id != Self.liveCheckpointID && !$0.pushedToOP }
        let plan = RetroAcceptance.plan(pending: pending, sessions: sessions, bar: bar, score: scoring)
        guard !plan.clearances.isEmpty else { return }
        applyRetroPlan(plan, bar: bar, reclaimedFrom: Set(unknownAssigned.map(\.id)))
    }

    /// Apply a retro-acceptance plan: clear the segments, lift the overlapping
    /// sessions, and journal ONE digest for the whole pass so it can be undone
    /// as a unit ("Cleared N items – undo"). `reclaimedFrom` names which
    /// cleared segment ids were previously swept to Unknown (rather than
    /// still-pending) — display only, so a mixed pass's digest reads
    /// honestly instead of implying every clearance came from the queue.
    private func applyRetroPlan(_ plan: RetroPlan, bar: Double, reclaimedFrom: Set<UUID> = []) {
        var idsByTarget: [Target: [UUID]] = [:]
        for clearance in plan.clearances {
            idsByTarget[clearance.target, default: []].append(clearance.segmentID)
        }
        for (target, ids) in idsByTarget {
            try? journal.assign(ids, to: target)
        }
        var priorSessions: [RetroDigest.PriorSessionState] = []
        for lift in plan.lifts {
            priorSessions.append(RetroDigest.PriorSessionState(
                id: lift.sessionID, task: lift.priorTask, certainty: lift.priorCertainty))
            if var session = try? journal.session(id: lift.sessionID) {
                session.task = lift.newTask
                session.certainty = lift.newCertainty
                try? journal.update(session)
            }
        }
        let count = plan.clearances.count
        let reclaimedCount = plan.clearances.filter { reclaimedFrom.contains($0.segmentID) }.count
        var reason = "Confidence reached \(Int((bar * 100).rounded()))% or above"
        if reclaimedCount == count, reclaimedCount > 0 {
            reason += " (reclaimed from Unknown)"
        } else if reclaimedCount > 0 {
            reason += " (\(reclaimedCount) reclaimed from Unknown)"
        }
        let digest = RetroDigest(
            clearedSegmentIDs: plan.clearances.map(\.segmentID),
            target: dominantRetroTarget(in: plan.clearances),
            count: count,
            reason: reason,
            priorSessions: priorSessions)
        try? journal.saveRetroDigest(digest)
        reloadReview()
    }

    /// The digest's headline target: the most-common clearance target in the
    /// pass (ties keep the first one seen) — display only, undo doesn't need
    /// it (it restores each segment/session from the stored payload).
    private func dominantRetroTarget(in clearances: [RetroClearance]) -> Target {
        var counts: [Target: Int] = [:]
        var order: [Target] = []
        for clearance in clearances {
            if counts[clearance.target] == nil { order.append(clearance.target) }
            counts[clearance.target, default: 0] += 1
        }
        return order.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? clearances[0].target
    }

    /// Undo one retro-acceptance pass: restores every cleared segment to
    /// pending, restores every lifted session's prior task+certainty, and
    /// removes the digest — "nothing is lost" (spec §8 criterion 1).
    public func undoRetroDigest(_ id: UUID) {
        guard let digest = retroDigest.first(where: { $0.id == id }) else { return }
        try? journal.assign(digest.clearedSegmentIDs, to: nil)
        for prior in digest.priorSessions {
            guard var session = try? journal.session(id: prior.id) else { continue }
            session.task = prior.task
            session.certainty = prior.certainty
            try? journal.update(session)
        }
        try? journal.deleteRetroDigest(id)
        reloadReview()
    }

    /// Bumped on every journal mutation (this is called on all of them) and on
    /// a committed in-flight note (which the timeline composes into the live
    /// slice), so a view can invalidate a cached journal read without polling —
    /// even when the summary STRING is unchanged (e.g. a same-duration
    /// reassign).
    @Published public private(set) var journalRevision = 0

    private func updateJournalSummary() {
        // COUNT queries instead of decoding the whole table. The checkpoint row
        // (pushedToOP=true sentinel) is counted in both totals, exactly as the
        // old allSessions()-minus-checkpoint logic netted out: total includes it
        // and `handled` includes it, so both shift by one and the visible
        // "journalled vs handled" arithmetic is unchanged. (The row is normally
        // absent — present only while a live session is in flight.)
        let total = (try? journal.sessionCount()) ?? 0
        let pushed = (try? journal.pushedCount()) ?? 0
        let awaiting = (try? journal.sessions(
            needingPushAtOrAbove: settings.certaintyAutoPushThreshold).count) ?? 0
        journalSummary = "\(total) sessions journalled · \(pushed) handled · \(awaiting) awaiting push"
        journalFootprintSummary = Self.footprintText(try? journal.journalFootprint())
        journalRevision &+= 1
    }

    /// (a) iCloud quota stewardship: render the honest footprint split — real
    /// byte counts, not an estimate, so the copy never overclaims OR scares
    /// (the synced journal really is tiny; window-span detail never syncs).
    private static func footprintText(_ footprint: (syncedBytes: Int, localDetailBytes: Int)?) -> String {
        guard let footprint else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let synced = formatter.string(fromByteCount: Int64(footprint.syncedBytes))
        let detail = formatter.string(fromByteCount: Int64(footprint.localDetailBytes))
        return "Synced journal: \(synced) · local-only window detail (never syncs): \(detail)"
    }

    // MARK: - Undo

    /// Infinite, session-bounded undo of data edits (timeline, review,
    /// local tasks, colours). ⌘Z anywhere in the app. The stack + grouping
    /// semantics live in Core (UndoStack, checked); this owns the sounds,
    /// the notification and the published count.
    private let undoStack = UndoStack()
    @Published public private(set) var undoCount = 0

    private func registerUndo(_ label: String, inverse: @escaping () async -> Void) {
        undoStack.register(label, inverse: inverse)
        undoCount = undoStack.count
    }

    /// Bundle every mutation in `body` into ONE undo step (a handle drag that
    /// overwrites several records, or an overlap save that trims a neighbour
    /// and moves a slice, undoes in a single ⌘Z). Nestable.
    public func undoGroup(_ label: String, _ body: () async -> Void) async {
        await undoStack.group(label, body)
        undoCount = undoStack.count
    }

    public func undo() {
        guard let last = undoStack.pop() else {
            NSSound(named: "Funk")?.play()
            return
        }
        undoCount = undoStack.count
        notifyContent(symbol: "arrow.uturn.backward", text: last.label, sound: "Pop")
        Task { await last.inverse() }
    }

    /// The ⌘Z local monitor's token (C13): removed at terminate/deinit —
    /// app-lifetime in practice, but a leaked monitor outliving a torn-down
    /// controller (tests, previews) would fire into a dead weak self.
    private var undoKeyMonitor: Any?

    private func installUndoKey() {
        undoKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "z" {
                self?.undo()
                return nil
            }
            return event
        }
    }

    private func removeUndoKey() {
        if let undoKeyMonitor { NSEvent.removeMonitor(undoKeyMonitor) }
        undoKeyMonitor = nil
    }

    /// True system-wide ⌘⇧L: toggles Away from any app (kVK_ANSI_L = 37). The
    /// popover's SwiftUI .keyboardShortcut only fires while andeye is key, so
    /// this is the one that works on your way out of the room. setAway no-ops
    /// unless we're .tracking, so the chord is harmless when stopped.
    private func installAwayHotKey() {
        let signature = OSType(0x416D6274)   // 'Ambt'
        awayHotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(cmdKey | shiftKey),
            signature: signature,
            id: 1) { [weak self] in
            guard let self else { return }
            self.setAway(!self.away)
        }
        if awayHotKey == nil {
            DebugLog.write("global ⌘⇧L hotkey: registration failed")
        }
    }

    deinit {
        // Belt-and-braces: also unregister if the controller is torn down
        // without a willTerminate (e.g. in tests / previews). deinit runs
        // GlobalHotKey.deinit which unregisters the Carbon hotkey + handler.
        awayHotKey = nil
    }

    // MARK: - Timeline

    /// Sessions overlapping an arbitrary [from, to] window — the continuous
    /// timeline's fetch, so a viewport can span midnight / several days — plus
    /// the synthetic live slice (folded into the same-task block it continues)
    /// when the current visit overlaps the window.
    public func timelineSessions(from: Date, to: Date) -> [Session] {
        // The live checkpoint row is internal crash-recovery state, not a
        // user-facing slice — never draw it on the timeline.
        var list = ((try? journal.sessions(from: from, to: to)) ?? [])
            .filter { $0.id != Self.liveCheckpointID }
        if case .tracking(.task(let ref), let certainty) = trackerState {
            var liveStart = tracker.liveSliceStart ?? targetSince ?? Date()
            let liveEnd = Date()
            guard liveEnd > from, liveStart < to else { return list }
            // Fold the live slice visually into the same-task block it
            // continues (the journal only coalesces on flush): walk back over
            // contiguous same-task journalled slices, drop them, extend the
            // live start to cover them.
            let fold = TimelineMath.foldLive(list, task: ref, liveStart: liveStart)
            list = fold.remaining
            liveStart = fold.start
            // The live slice CARRIES the folded rows' stored comments plus
            // its pending committed note, so a comment stays visible in the
            // timeline from the moment it's entered — through the flush that
            // journals it AND any merge under the live block. (Martin's
            // comments used to vanish until he stopped and left a gap.)
            let pending = Self.joinedNote(manualNotes[ref])
            list.append(Session(id: Self.liveSessionID, task: ref, start: liveStart,
                                end: liveEnd, certainty: certainty,
                                comment: TimelineMath.joinComments([fold.foldedComment,
                                                                    pending])))
        }
        return list
    }

    public static let liveSessionID = UUID(uuidString: "00000000-0000-0000-0000-00000000A11E")!

    /// The stored comments of the journalled rows the displayed live block
    /// folds (see `timelineSessions`) — read-only context for the timeline
    /// editor, whose comment field edits ONLY the in-flight note (the stored
    /// parts belong to journalled slices). Bounded to a 2-day lookback: the
    /// fold chains only across ≤2 s gaps, so anything older can't be part of
    /// the live block anyway.
    public func liveFoldedComment() -> String? {
        guard case .tracking(.task(let ref), _) = trackerState else { return nil }
        let liveStart = tracker.liveSliceStart ?? targetSince ?? Date()
        let rows = ((try? journal.sessions(from: liveStart.addingTimeInterval(-2 * 86_400),
                                           to: liveStart.addingTimeInterval(2))) ?? [])
            .filter { $0.id != Self.liveCheckpointID }
        return TimelineMath.foldLive(rows, task: ref, liveStart: liveStart).foldedComment
    }

    /// Read-only projection of the tracker's provisional-switch window for the
    /// timeline hatch: the sub-range of the live slice whose commit is still
    /// undecided (a confident WORK switch that hasn't yet held past the grace
    /// floor — a return to the prior task before `graceEnds` reverts it).
    /// `since` is where the provisional run began, `graceEnds` when it commits.
    /// nil unless such a switch is in flight. Pure display state — reading it
    /// never writes to the journal or changes segmentation.
    public var liveGraceRange: (since: Date, graceEnds: Date)? {
        guard let since = tracker.pendingSwitchSince,
              let ends = tracker.graceEndsAt else { return nil }
        return (since, ends)
    }

    // MARK: - Posting-ledger mirrors of the legacy pushed flags
    //
    // The edit paths below reset `pushedToOP`/`opTimeEntryID` so a slice
    // re-enters the push queue (or record that it is handled). Eligibility is
    // now ledger-driven, so each of those resets must move the PRIMARY PM
    // ledger row the same way — and ONLY that row: a finance backend's posted
    // entry is never deleted by a timeline edit (prospective-only), so
    // clearing its row would re-post a duplicate.

    /// The ledger identity of the primary pm backend. Falls back to the OP
    /// stable id when nothing is registered (standalone edits still mirror
    /// consistently) — but never hardcode the OP id at a call site: the
    /// primary pm may one day not be OP, and a mismatched id here would
    /// strand the real row and re-post history.
    private var primaryPMLedgerID: String {
        registry.primaryPM?.id ?? OPBackend.stableID
    }

    /// The primary pm row is gone: the session re-enters the pm queue.
    private func clearPrimaryPosting(_ id: UUID) {
        try? journal.clearPostingRecord(session: id, backendID: primaryPMLedgerID)
    }

    /// The primary pm backend holds `entryID` for this session (a PATCH-in-
    /// place or reconcile re-point): record it so sync never re-creates it.
    private func setPrimaryPosted(_ id: UUID, entryID: RemoteEntryID?) {
        try? journal.setPostingRecord(PostingRecord(
            sessionID: id, backendID: primaryPMLedgerID,
            state: .posted, entryID: entryID))
    }

    /// One reusable ISO-8601 formatter for OP pushes — it was allocated per
    /// push in several paths (allocating a formatter is not cheap).

    /// A slice the timeline should frame + open when it next appears — set when
    /// you click a slice in the pie window's mini-timeline. The timeline consumes
    /// and clears it.
    @Published public var pendingTimelineFocus: Session?

    /// The view shown in the single Time window, and in the optional second
    /// window (control/right-click a preview). Flipping the primary in place is
    /// the normal "switch"; the second window is the escape hatch for both at
    /// once.
    @Published public var timeWindowView: TimeView = .timeline
    @Published public var timeWindow2View: TimeView = .spent

    /// Record which time view is showing (persists, so "last viewed" survives a
    /// relaunch).
    public func noteTimeViewOpened(_ which: TimeView) {
        if settings.lastViewedTimeView != which { settings.lastViewedTimeView = which }
    }

    /// Scan OP for duplicate time entries over a recent window and plan the
    /// richest-survivor reconcile against the journal. Empty when not connected
    /// or nothing duplicated.
    public func findDuplicateActions(daysBack: Int = 90) async -> [ReconcileAction] {
        guard let backend else { return [] }
        let to = Date()
        let from = to.addingTimeInterval(-Double(daysBack) * 86_400)
        let entries = (try? await backend.listTimeEntries(from: from, to: to)) ?? []
        let sessions = ((try? journal.sessions(from: from, to: to)) ?? [])
            .filter { $0.id != Self.liveCheckpointID }
        return DuplicateReconcile.plan(entries: entries, sessions: sessions)
    }

    /// Apply ONE confirmed reconcile: fold the deleted entries' comments into the
    /// survivor, delete the duplicates, and re-point the journal slices so future
    /// edits still PATCH the right entry. Nothing is lost.
    public func applyReconcile(_ action: ReconcileAction) async {
        guard let backend else { return }
        if let merged = action.mergedComment {
            try? await backend.updateEntryComment(id: action.survivorID, comment: merged)
        }
        for id in action.deleteIDs {
            try? await backend.deleteTimeEntry(id: id)
        }
        for sid in action.repointSessionIDs {
            if var s = try? journal.session(id: sid) {
                s.opTimeEntryID = action.survivorID
                try? journal.update(s)
                setPrimaryPosted(sid, entryID: action.survivorID)   // ledger follows
            }
        }
        updateJournalSummary()
    }

    // MARK: - iCloud quota stewardship (b/c)

    /// (b) Age-consolidation preview: plan collapsing everything older than
    /// `settings.journalConsolidateAfterYears` into per-day per-task rollups,
    /// without touching anything yet. The live-tracking sentinels are never
    /// candidates (they're always recent, but excluded on principle like
    /// every other journal read that plans against `allSessions()`).
    public func consolidationPreview() -> JournalPrune.Plan {
        let sessions = ((try? journal.allSessions()) ?? [])
            .filter { $0.id != Self.liveCheckpointID && $0.id != Self.liveSessionID }
        let days = Int(settings.journalConsolidateAfterYears * 365)
        return JournalPrune.plan(sessions: sessions, olderThanDays: days)
    }

    /// Apply a previewed consolidation plan: create the rollups, then delete
    /// the raw originals they replace. Order matters not at all here (ids
    /// never collide — the rollup carries a freshly-derived id) but creating
    /// first means an interrupted apply never loses time outright.
    public func applyConsolidation(_ plan: JournalPrune.Plan) {
        // Snapshot the raw originals BEFORE deleting: consolidation is
        // journal-local (no backend writes), so undo can restore the exact
        // rows — rollups out, originals back, remote linkage untouched.
        let originals = plan.deleteIDs.compactMap { try? journal.session(id: $0) }
        for session in plan.create { try? journal.save(session) }
        for id in plan.deleteIDs { try? journal.deleteSession(id) }
        if !plan.isEmpty {
            let createdIDs = plan.create.map(\.id)
            registerUndo("consolidate \(originals.count) slices") { [weak self] in
                guard let self else { return }
                for id in createdIDs { try? self.journal.deleteSession(id) }
                for row in originals { try? self.journal.save(row) }
                self.updateJournalSummary()
            }
        }
        updateJournalSummary()
    }

    /// (c) Hard-cap preview — STRONGLY DISCOURAGED: plan deleting the oldest
    /// raw slices (never rollups) until the synced journal is back under
    /// `capMB`. Preview only; nothing is deleted until `applyHardCapPrune`.
    public func hardCapPreview(capMB: Double) -> JournalPrune.Plan {
        let sessions = ((try? journal.allSessions()) ?? [])
            .filter { $0.id != Self.liveCheckpointID && $0.id != Self.liveSessionID }
        return JournalPrune.hardCapPlan(sessions: sessions, capBytes: Int(capMB * 1_048_576))
    }

    /// Apply a previewed hard-cap plan: permanent deletion, no creates (the
    /// plan never proposes rollups). The UI double-confirms before this runs —
    /// and ⌘Z within the session still brings the rows back (permanence
    /// starts when the session ends, not the moment the button is clicked).
    public func applyHardCapPrune(_ plan: JournalPrune.Plan) {
        let originals = plan.deleteIDs.compactMap { try? journal.session(id: $0) }
        for id in plan.deleteIDs { try? journal.deleteSession(id) }
        if !originals.isEmpty {
            registerUndo("prune \(originals.count) slices") { [weak self] in
                guard let self else { return }
                for row in originals { try? self.journal.save(row) }
                self.updateJournalSummary()
            }
        }
        updateJournalSummary()
    }

    /// Today's project breakdown + total (the timeline window's mini-pie
    /// cross-preview).
    public func todaySpentNodes() -> [TimeAggregator.Node] {
        spentNodes(from: Calendar.current.startOfDay(for: Date()), to: Date())
    }

    /// The latest work block's slices + extent (the pie window's mini-timeline
    /// cross-preview). nil when there's no recent activity.
    public func currentBlock() -> (sessions: [Session], start: Date, end: Date)? {
        let recent = timelineSessions(from: Date().addingTimeInterval(-2 * 86_400), to: Date())
        guard let block = TimelineMath.latestBlock(in: recent) else { return nil }
        let slices = recent.filter { $0.end > block.start && $0.start < block.end }
        return (slices, block.start, block.end)
    }

    /// Which view the single Time window opens on, per the 3-way setting.
    public func initialTimeView() -> TimeView {
        switch settings.timeViewOpenMode {
        case .timeline: return .timeline
        case .spent: return .spent
        case .lastViewed: return settings.lastViewedTimeView
        }
    }

    public func timelineSpans(for session: Session) -> [FocusSpan] {
        (try? journal.spans(from: session.start, to: session.end)) ?? []
    }

    /// Why the attributor would pick a task for this window — drives the
    /// timeline's "why was this tracked as X?" panel. Scored at the window's own
    /// time so the time-of-day prior matches what actually happened.
    public func explainSpan(_ span: FocusSpan) -> AttributionExplanation {
        explain(span.signal, now: span.signal.timestamp)
    }

    // MARK: - Context rules: Evidence Card + un-learn (2026-07-03 spec)

    /// Why a signal attributes the way it does, for a raw focus signal (not
    /// tied to a journalled `FocusSpan`) — the popover host's Evidence Card
    /// source. `explainSpan` above is the timeline's equivalent.
    public func explain(_ signal: ActivitySignal, now: Date = Date()) -> AttributionExplanation {
        attributor.explain(signal, tasks: taskCache, now: now)
    }

    /// The current focus signal, or nil when nothing is focused — the
    /// popover host's Evidence Card source (the timeline host uses a
    /// journalled `FocusSpan`'s own signal instead).
    public func currentFocusSignal() -> ActivitySignal? {
        tracker.currentFocusSignal
    }

    /// The full broad→narrow identity of a signal — the Evidence Card's grain
    /// ladder / sees-line source, unconditionally (unlike `pinEmailIdentity()`,
    /// which gates on an email grain for the pin editor's Components-strip
    /// swap).
    public func identity(of signal: ActivitySignal) -> ContextIdentity {
        attributor.identity(of: signal)
    }

    /// What [✕ forget] would remove for this signal, or nil (pin / OP-URL /
    /// nothing learned — see `Attributor.forgettable`).
    public func forgettable(for signal: ActivitySignal, now: Date = Date()) -> Attributor.Unlearn? {
        attributor.forgettable(for: signal, now: now)
    }

    /// The live "would then fall back to…" preview — never mutates (see
    /// `Attributor.explainWithout`).
    public func explainWithout(_ u: Attributor.Unlearn, _ signal: ActivitySignal,
                               now: Date = Date()) -> AttributionExplanation {
        attributor.explainWithout(u, signal, tasks: taskCache, now: now)
    }

    /// What the fallback preview's own [✕ forget] would remove — the
    /// "forget that fallback too" affordance on the same preview line
    /// (never mutates; see `Attributor.forgettableWithout`).
    public func forgettableWithout(_ u: Attributor.Unlearn, _ signal: ActivitySignal,
                                   now: Date = Date()) -> Attributor.Unlearn? {
        attributor.forgettableWithout(u, signal, now: now)
    }

    /// An existing rule this commit would REPLACE (same level+value,
    /// unpinned) — the card's "replaces: X → OldTask" warning before a
    /// Remember/Always commit (2026-07-03 spec §5.5). Mirrors
    /// `learnEmailRule`'s own replacement filter.
    public func conflictingRule(level: EmailMatchLevel, value: String) -> EmailRule? {
        attributor.emailRules.first {
            $0.level == level && !$0.pinned && $0.value.caseInsensitiveCompare(value) == .orderedSame
        }
    }

    /// `conflictingRule`'s site twin — mirrors `learnSiteRule`'s own
    /// replacement filter (same recipe+field+value, unpinned).
    public func conflictingSiteRule(recipeID: String?, field: String, value: String) -> SiteRule? {
        attributor.siteRules.first {
            $0.recipeID == recipeID && $0.field == field && !$0.pinned
                && $0.value.caseInsensitiveCompare(value) == .orderedSame
        }
    }

    /// The Evidence Card's [✕ forget] / [✕ suppress]: remove exactly what `u`
    /// names, with a full undo (R2 — one action, never a leap of faith). State
    /// is small enough to snapshot wholesale rather than deriving a bespoke
    /// inverse per `Unlearn` case; a forgotten session sticky is restored by
    /// re-asserting it through `assign` (the only public way to create one)
    /// and then restoring the OTHER stores over its side effects, so the
    /// round trip is exact.
    public func forget(_ u: Attributor.Unlearn, signal: ActivitySignal) {
        let savedRules = attributor.emailRules
        let savedSiteRules = attributor.siteRules
        let savedPrimes = attributor.primedSurfaces
        let savedLearning = attributor.learning
        let savedDisplaced = attributor.displacedByCorrection
        let savedStickies = attributor.sessionStickies
        attributor.forget(u, signal: signal)
        persistAssociations()
        tracker.reevaluate()
        registerUndo(forgetUndoLabel(u)) { [weak self] in
            guard let self else { return }
            self.attributor.emailRules = savedRules
            self.attributor.siteRules = savedSiteRules
            self.attributor.primedSurfaces = savedPrimes
            self.attributor.replaceLearning(savedLearning)
            // Wholesale snapshot restore (stickies included) — exact, where
            // the old re-assert-the-sticky path was only an approximation
            // that itself re-recorded displacement state.
            self.attributor.replaceSessionStickies(savedStickies)
            self.attributor.displacedByCorrection = savedDisplaced
            self.persistAssociations()
            self.tracker.reevaluate()
            self.objectWillChange.send()
        }
        objectWillChange.send()
    }

    private func forgetUndoLabel(_ u: Attributor.Unlearn) -> String {
        switch u {
        case .emailRule(let rule): return "forget rule \(rule.value)"
        case .siteRule(let rule): return "forget rule \(rule.value)"
        case .primedSurface: return "forget remembered surface"
        case .sessionSticky: return "forget today's categorisation"
        case .rankedAssociation(let target): return "suppress learning toward \(name(of: target))"
        }
    }

    /// The Evidence Card's Remember (0.95, learned) / Always (1.0, pinned)
    /// commit at the grain the user selected: an email-flavoured grain
    /// (including the system row) writes an `EmailRule`; a ◆ recipe-field
    /// grain writes a `SiteRule` (Remember learned, Always PINNED — still
    /// 0.95, mirroring the card's pinned-EmailRule convention); the host row
    /// on a non-mail page writes the recipe-less `site`-level SiteRule on
    /// Remember (the policy note's "one correction generalises the whole
    /// host") while its Always stays the existing PinScope root pin (1.0,
    /// standing law) — 2026-07-09 site-recipes spec §6. A plain PinScope
    /// path grain writes a `Pin` when pinned (Remember there is today's soft
    /// prime + learned association, already applied by the caller's own pick
    /// — see `PopoverView`/`TimelineView`). This is what replaces the
    /// retired silent `learnEmailRule` call in `confirm`/`assign`
    /// (2026-07-03 spec §5.2/§5.4).
    public func commitGrain(_ identity: ContextIdentity, grainCount: Int, signal: ActivitySignal,
                            to ref: TaskRef, pinned: Bool, now: Date = Date()) {
        guard grainCount >= 1, grainCount <= identity.segments.count else { return }
        let segment = identity.segments[grainCount - 1]
        guard segment.available else { return }
        let host = signal.tabURL.flatMap { URL(string: $0)?.host?.lowercased() }
        if let level = segment.kind.emailMatchLevel {
            let restore = attributorSnapshotRestore()
            attributor.learnEmailRule(signal, to: ref, level: level, value: segment.emailMatchValue,
                                      pinned: pinned, origin: .card, now: now)
            persistAssociations()
            tracker.reevaluate()
            // Global ⌘Z covers the commit too, not only the notice's [undo]
            // (which routes through `forget` and registers its own step).
            registerUndo("learn rule \(segment.emailMatchValue)") { [weak self] in
                self?.learnNotice = nil
                restore()
            }
            showLearnNotice(rules: [EmailRule(level: level, value: segment.emailMatchValue,
                                              target: ref, pinned: pinned, createdAt: now, origin: .card)],
                            signal: signal)
            objectWillChange.send()
        } else if case .recipeField(let field) = segment.kind, let host,
                  let recipe = SiteRecipes.recipe(forHost: host,
                                                  disabled: attributor.disabledSiteRecipes) {
            commitSiteRule(recipeID: recipe.id, field: field, value: segment.value,
                           signal: signal, to: ref, pinned: pinned, now: now)
        } else if segment.kind == .urlHost, !pinned, let host {
            commitSiteRule(recipeID: nil, field: SiteRule.siteField, value: host,
                           signal: signal, to: ref, pinned: false, now: now)
        } else if pinned, let id = PinScope.identity(of: signal) {
            let prefix = Array(id.segments.prefix(grainCount))
            guard !prefix.isEmpty else { return }
            commitPin(kind: id.kind, prefix: prefix, to: ref)
        }
    }

    /// The site half of `commitGrain` — same undo + notice shape as the
    /// email branch: one snapshot-restore ⌘Z step, one First-LEARN notice
    /// whose [undo] forgets exactly the rule written.
    private func commitSiteRule(recipeID: String?, field: String, value: String,
                                signal: ActivitySignal, to ref: TaskRef,
                                pinned: Bool, now: Date) {
        let restore = attributorSnapshotRestore()
        attributor.learnSiteRule(recipeID: recipeID, field: field, value: value,
                                 to: ref, pinned: pinned, origin: .card, now: now)
        persistAssociations()
        tracker.reevaluate()
        registerUndo("learn rule \(value.lowercased())") { [weak self] in
            self?.siteLearnNotice = nil
            restore()
        }
        showSiteLearnNotice(rules: [SiteRule(recipeID: recipeID, field: field,
                                             value: value.lowercased(), target: ref,
                                             pinned: pinned, createdAt: now, origin: .card)],
                            signal: signal)
        objectWillChange.send()
    }

    /// `commitGrain`'s multi-correspondent sibling (2026-07-03 spec §5.5,
    /// "later polish", additive — `commitGrain` itself is untouched). When a
    /// message carries more than one counterparty, the correspondent grain
    /// writes one `EmailRule` per CHECKED address instead of `commitGrain`'s
    /// single rule for the primary correspondent. `chosen` is the grain
    /// footer's / Evidence Card's checkbox selection, matched case-
    /// insensitively against `ContextIdentity.correspondentChoices(signal)`
    /// (the pure fan-out lives there, check-covered without an Attributor).
    /// A no-op if `chosen` picks nothing.
    public func commitCorrespondentGrain(_ signal: ActivitySignal, chosen: Set<String>,
                                         to ref: TaskRef, pinned: Bool, now: Date = Date()) {
        let values = ContextIdentity.correspondentRuleValues(signal, chosen: chosen)
        guard !values.isEmpty else { return }
        let restore = attributorSnapshotRestore()
        for value in values {
            attributor.learnEmailRule(signal, to: ref, level: .correspondent, value: value,
                                      pinned: pinned, origin: .card, now: now)
        }
        persistAssociations()
        tracker.reevaluate()
        // One ⌘Z step for the whole fan-out, same as the notice's [undo].
        registerUndo(values.count == 1 ? "learn rule \(values[0])"
                                       : "learn \(values.count) rules") { [weak self] in
            self?.learnNotice = nil
            restore()
        }
        // Fan-out learning must not be silent either — ONE notice covering
        // every rule just written, whose [undo] removes them all.
        showLearnNotice(rules: values.map {
            EmailRule(level: .correspondent, value: $0, target: ref,
                      pinned: pinned, createdAt: now, origin: .card)
        }, signal: signal)
        objectWillChange.send()
    }

    // MARK: - First-LEARN / First-FIRE notices (2026-07-03 spec §6)

    /// A one-line popover-anchored trace of the durable rule(s) a commit just
    /// wrote — so learning is never silent (spec §6 MVP item 6). Usually one
    /// rule; the multi-correspondent fan-out passes them all, so [undo]
    /// removes the whole batch. `signal` is the exact signal the rules were
    /// committed against, so undo forgets them through the same
    /// `forget(_:signal:)` path (with its usual undo-stack registration)
    /// rather than a bespoke removal.
    public struct LearnNotice: Equatable, Sendable {
        public let rules: [EmailRule]
        public let taskName: String
        public let signal: ActivitySignal
    }
    /// A one-line popover-anchored trace of a learned rule's FIRST-ever win
    /// (spec §6 later-polish item, brought forward) — informational only, no
    /// undo (a rule that's working as intended is a Rules Ledger/Evidence
    /// Card matter, not a passing toast's).
    public struct FireNotice: Equatable, Sendable {
        public let rule: EmailRule
        public let taskName: String
    }
    @Published public private(set) var learnNotice: LearnNotice?
    @Published public private(set) var fireNotice: FireNotice?
    /// Popover-anchored only — never a system notification (spec §6 MVP
    /// item 6 explicitly). Auto-dismisses after this long, or sooner on the
    /// next task pick (see `userPicked`/`changeCurrentTask`) — never blocks
    /// the express path either way.
    static let noticeDismissSeconds: TimeInterval = 8

    private func showLearnNotice(rules: [EmailRule], signal: ActivitySignal) {
        guard let first = rules.first else { return }
        let notice = LearnNotice(rules: rules, taskName: name(of: .task(first.target)), signal: signal)
        learnNotice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeDismissSeconds) { [weak self] in
            guard let self, self.learnNotice == notice else { return }
            self.learnNotice = nil
        }
    }

    /// The First-LEARN notice's [undo]: forgets exactly the rule(s) it named.
    public func undoLearnNotice() {
        guard let notice = learnNotice else { return }
        learnNotice = nil
        for rule in notice.rules { forget(.emailRule(rule), signal: notice.signal) }
    }

    public func dismissLearnNotice() { learnNotice = nil }
    public func dismissFireNotice() { fireNotice = nil }

    /// Wires `Attributor.onFirstFire` to publish the First-FIRE notice. Called
    /// once from `init`, after `attributor`/`tracker` are both set up.
    private func wireFirstFireNotice() {
        attributor.onFirstFire = { [weak self] rule in
            guard let self else { return }
            let notice = FireNotice(rule: rule, taskName: self.name(of: .task(rule.target)))
            self.fireNotice = notice
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeDismissSeconds) { [weak self] in
                guard let self, self.fireNotice == notice else { return }
                self.fireNotice = nil
            }
        }
        attributor.onFirstSiteFire = { [weak self] rule in
            guard let self else { return }
            let notice = SiteFireNotice(rule: rule, taskName: self.name(of: .task(rule.target)))
            self.siteFireNotice = notice
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeDismissSeconds) { [weak self] in
                guard let self, self.siteFireNotice == notice else { return }
                self.siteFireNotice = nil
            }
        }
    }

    // MARK: - Site-rule notices (site-recipes spec §6 — identical hooks:
    // nothing durable is ever learned silently)

    /// `LearnNotice`'s site twin — a parallel struct rather than a
    /// generalisation, matching the parallel-rule-type call (spec §5).
    public struct SiteLearnNotice: Equatable, Sendable {
        public let rules: [SiteRule]
        public let taskName: String
        public let signal: ActivitySignal
    }
    public struct SiteFireNotice: Equatable, Sendable {
        public let rule: SiteRule
        public let taskName: String
    }
    @Published public private(set) var siteLearnNotice: SiteLearnNotice?
    @Published public private(set) var siteFireNotice: SiteFireNotice?

    private func showSiteLearnNotice(rules: [SiteRule], signal: ActivitySignal) {
        guard let first = rules.first else { return }
        let notice = SiteLearnNotice(rules: rules, taskName: name(of: .task(first.target)),
                                     signal: signal)
        siteLearnNotice = notice
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.noticeDismissSeconds) { [weak self] in
            guard let self, self.siteLearnNotice == notice else { return }
            self.siteLearnNotice = nil
        }
    }

    /// The site First-LEARN notice's [undo]: forgets exactly the rule(s) it
    /// named — through `forget(_:signal:)`, so it registers its own ⌘Z step
    /// like the email twin.
    public func undoSiteLearnNotice() {
        guard let notice = siteLearnNotice else { return }
        siteLearnNotice = nil
        for rule in notice.rules { forget(.siteRule(rule), signal: notice.signal) }
    }

    public func dismissSiteLearnNotice() { siteLearnNotice = nil }
    public func dismissSiteFireNotice() { siteFireNotice = nil }

    // MARK: - Rules Ledger (Settings ▸ Context rules…)

    /// Learned + pinned email rules grouped by task, for the ledger window.
    public func rulesLedger(search: String = "") -> [RulesLedgerGroup] {
        RulesLedger.grouped(attributor.emailRules, nameOf: { name(of: .task($0)) }, search: search)
    }

    /// Ledger row delete (✕) — the same undo mechanism as the card's forget.
    public func deleteRule(_ rule: EmailRule) {
        deleteRules([rule])
    }

    /// Bulk ledger forget (multi-select ✕ / a group's "Forget all") — every
    /// rule removed in the SAME undo step, so one ⌘Z restores the whole act
    /// instead of one row at a time (2026-07-03 spec §6, "bulk forget").
    public func deleteRules(_ rules: [EmailRule]) {
        guard !rules.isEmpty else { return }
        let saved = attributor.emailRules
        attributor.emailRules.removeAll { candidate in rules.contains { $0.sameRule(as: candidate) } }
        persistAssociations()
        tracker.reevaluate()
        let label = rules.count == 1 ? "delete rule \(rules[0].value)" : "delete \(rules.count) rules"
        registerUndo(label) { [weak self] in
            guard let self else { return }
            self.attributor.emailRules = saved
            self.persistAssociations()
            self.tracker.reevaluate()
            self.objectWillChange.send()
        }
        objectWillChange.send()
    }

    /// The ledger's "Copy rules" export — every learned + pinned email rule
    /// as human-readable plain text (2026-07-03 spec §6, "export").
    public func rulesExportText() -> String {
        RulesLedger.exportText(attributor.emailRules, nameOf: { name(of: .task($0)) })
    }

    // MARK: - Rules Ledger, "Sites" segment (site-recipes spec §6)

    /// Learned + pinned site rules grouped by task — the ledger's Sites
    /// segment, `rulesLedger`'s exact contract.
    public func siteRulesLedger(search: String = "") -> [SiteRulesLedgerGroup] {
        SiteRulesLedger.grouped(attributor.siteRules, nameOf: { name(of: .task($0)) },
                                search: search)
    }

    /// Site-row delete (✕) — `deleteRule`'s twin.
    public func deleteSiteRule(_ rule: SiteRule) {
        deleteSiteRules([rule])
    }

    /// Bulk site-rule forget: every rule removed in the SAME undo step,
    /// exactly `deleteRules`' shape.
    public func deleteSiteRules(_ rules: [SiteRule]) {
        guard !rules.isEmpty else { return }
        let saved = attributor.siteRules
        attributor.siteRules.removeAll { candidate in rules.contains { $0.sameRule(as: candidate) } }
        persistAssociations()
        tracker.reevaluate()
        let label = rules.count == 1 ? "delete rule \(rules[0].value)" : "delete \(rules.count) rules"
        registerUndo(label) { [weak self] in
            guard let self else { return }
            self.attributor.siteRules = saved
            self.persistAssociations()
            self.tracker.reevaluate()
            self.objectWillChange.send()
        }
        objectWillChange.send()
    }

    /// The Sites segment's "Copy rules" export.
    public func siteRulesExportText() -> String {
        SiteRulesLedger.exportText(attributor.siteRules, nameOf: { name(of: .task($0)) })
    }

    /// The Settings ▸ Diagnostics "What recipes see here" dump: what the
    /// recipe layer derives from the CURRENT focus surface (the pure
    /// formatter lives in Core — `SiteRecipes.probeText` — so it's checked).
    /// Shown on demand only; never routed to DebugLog (spec §9).
    public func siteRecipeProbeText() -> String {
        guard let signal = tracker.currentFocusSignal else {
            return "No focused surface yet — focus the page you want to inspect, then reopen Settings."
        }
        return SiteRecipes.probeText(for: signal,
                                     disabled: attributor.disabledSiteRecipes)
    }

    /// Teach the attributor that this window is `ref` (a strong correction, like
    /// a confirmation): future time on it attributes here. The visible "edit the
    /// weighting" action behind the why-panel.
    public func teachSurface(_ span: FocusSpan, to ref: TaskRef) {
        let restore = attributorSnapshotRestore()
        attributor.confirm(span.signal, task: ref, tasks: taskCache)
        persistAssociations()
        tracker.reevaluate()
        registerUndo("unteach \(name(of: .task(ref)))") { restore() }
        objectWillChange.send()
    }

    public func boostSurface(_ span: FocusSpan, to ref: TaskRef, weight: Double = 4) {
        let restore = attributorSnapshotRestore()
        attributor.learnSurface(span.signal, to: ref, weight: weight)
        persistAssociations(); tracker.reevaluate()
        registerUndo("remove boost toward \(name(of: .task(ref)))") { restore() }
        objectWillChange.send()
    }

    /// Snapshot the attributor's whole learned state NOW and hand back the
    /// inverse that restores it — the one shape every teach/boost/grain undo
    /// shares (email + site rules, primes, learned weights, stickies,
    /// displacement history; pins have their own snapshot in
    /// `commitPin`/`unpin`).
    private func attributorSnapshotRestore() -> () -> Void {
        let savedRules = attributor.emailRules
        let savedSiteRules = attributor.siteRules
        let savedPrimes = attributor.primedSurfaces
        let savedLearning = attributor.learning
        let savedDisplaced = attributor.displacedByCorrection
        let savedStickies = attributor.sessionStickies
        return { [weak self] in
            guard let self else { return }
            self.attributor.emailRules = savedRules
            self.attributor.siteRules = savedSiteRules
            self.attributor.primedSurfaces = savedPrimes
            self.attributor.replaceLearning(savedLearning)
            self.attributor.displacedByCorrection = savedDisplaced
            self.attributor.replaceSessionStickies(savedStickies)
            self.persistAssociations()
            self.tracker.reevaluate()
            self.objectWillChange.send()
        }
    }

    public func pinSurface(_ span: FocusSpan, to ref: TaskRef) {
        guard let id = PinScope.identity(of: span.signal) else {
            boostSurface(span, to: ref, weight: 6); return
        }
        let n = PinScope.defaultPrefixCount(kind: id.kind, segments: id.segments)
        commitPin(kind: id.kind, prefix: Array(id.segments.prefix(n)), to: ref)
    }

    /// Per-task colour: the Unknown sentinel first (fixed neutral grey — it
    /// reads as "undecided", never a real project hue, and isn't user
    /// recolourable), then a user override, then the task's persisted colour
    /// record — allocated by `ColourEngine` (hue-neighbourhood strategy, CVD-
    /// aware max-distinct) on FIRST SIGHT and stable ever after. The old
    /// hash fallback survives only as the one-time migration snapshot
    /// (`legacyHashColourHex`), so pre-engine tasks keep exactly the colour
    /// they always had.
    public func colour(for ref: TaskRef) -> NSColor {
        if ref == WorkTask.unknown.ref { return .systemGray }
        if let hex = settings.taskColours[ref.storageKey], let c = NSColor(hex: hex) {
            return c
        }
        if let record = colourAssignments.tasks[ref.storageKey],
           let c = NSColor(hex: record.hex) {
            return c
        }
        // First sight: allocate within the project's hue neighbourhood and
        // persist — from here on this task's colour is data, not derivation.
        // The repair gate runs FIRST: `taskHex` reads (and, for a new
        // project, creates) the anchor, so allocating here without it would
        // shade the newcomer around a wrong anchor AND close the legacy
        // repair by minting an "auto" record — the 2026-07-10 bypass, where
        // timeline/MiniPie/Settings first-sights beat the pie (then the only
        // repair site) to the record.
        let key = taskCache.first(where: { $0.ref == ref }).flatMap { projectKey(for: $0) }
        if let key { repairColourAnchorIfNeeded(projectKey: key) }
        let hex = ColourEngine.taskHex(ref.storageKey, projectKey: key,
                                       in: &colourAssignments)
        scheduleColoursSave()
        return NSColor(hex: hex) ?? .systemGray
    }

    /// Repair gate for one project's anchor — MUST run before any path that
    /// creates or reads the project's record (`projectRecord`/`taskHex`), at
    /// every such site, so the repair never depends on which view renders
    /// first. Armed until the one-time marker file exists (see
    /// `finalizeColourRepairsIfComplete`). Membership can be gathered from
    /// the cache whenever the key is resolvable at all: resolving a key
    /// requires the ref's task to be cached, and tasks of one project always
    /// arrive together (locals at init, backend tasks per fetch).
    private func repairColourAnchorIfNeeded(projectKey key: String) {
        guard colourRepairArmed, !colourProjectsRepairChecked.contains(key) else { return }
        colourProjectsRepairChecked.insert(key)
        let members = taskCache.compactMap { task in
            projectKey(for: task) == key ? task.ref.storageKey : nil
        }
        if ColourEngine.repairProjectAnchor(projectKey: key,
                                            memberTaskKeys: members,
                                            overrides: settings.taskColours,
                                            storeLoadedPreV2: colourStoreLoadedPreV2,
                                            in: &colourAssignments) {
            scheduleColoursSave()
        }
    }

    /// One-shot close of the anchor-repair era, run once the task cache is
    /// COMPLETE — after a successful backend refresh, or at startup when the
    /// app is standalone (locals are all there is). Sweeps every resolvable
    /// project through the repair, closes whatever nil-provenance anchors
    /// remain (their projects resolve to no cached task, so there is no
    /// legacy colour to restore), then writes the marker that disarms the
    /// repair. Residual risk, accepted: if a pre-provenance binary later
    /// rewrites colours.json AND the marker is separately deleted, the
    /// repair re-arms — and re-derives the same deterministic anchors, so
    /// the re-run changes nothing unless the user recoloured the legacy
    /// child in between.
    private func finalizeColourRepairsIfComplete() {
        guard colourRepairArmed else { return }
        var keys = Set<String>()
        for task in taskCache {
            if let key = projectKey(for: task) { keys.insert(key) }
        }
        for key in keys.sorted() { repairColourAnchorIfNeeded(projectKey: key) }
        _ = ColourEngine.adoptUnrepairedAnchors(in: &colourAssignments)
        colourRepairArmed = false
        try? coloursStore.save(colourAssignments)   // v2 stamp lands with the marker
        FileManager.default.createFile(atPath: colourRepairMarkerURL.path, contents: Data())
    }

    /// One coalesced colours.json write per burst of first sights. A fresh
    /// install rendering a full pie allocates dozens of records inside one
    /// SwiftUI render pass — a synchronous save per record was dozens of
    /// file writes for one frame. The records live in memory the moment they
    /// allocate; the only crash-window cost is that an unsaved burst
    /// re-allocates next launch (possibly in a different render order, so a
    /// colour the user glimpsed for under a second could differ — nothing
    /// already persisted ever moves).
    private var coloursSaveScheduled = false
    private func scheduleColoursSave() {
        guard !coloursSaveScheduled else { return }
        coloursSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.coloursSaveScheduled = false
            try? self.coloursStore.save(self.colourAssignments)
        }
    }

    /// Stable colour for the PROJECT containing `ref`: the project's own
    /// anchor record (allocated on first sight, like task colours). This is
    /// what the pie's project ring and legend swatch use — previously they
    /// borrowed the first child task's colour, so a project's apparent
    /// colour changed whenever its biggest task or the sort order did.
    /// nil when the ref is unknown to the cache (caller falls back).
    public func projectColour(containing ref: TaskRef?) -> NSColor? {
        guard let ref, ref != WorkTask.unknown.ref,
              let task = taskCache.first(where: { $0.ref == ref }),
              let key = projectKey(for: task) else { return nil }
        // The ref only RESOLVES the project key — the anchor never derives
        // from this particular child (pre-2026-07-10 it did, which made the
        // anchor depend on whichever child the pie's current sort put
        // first). Pre-engine projects get their legacy ring colour restored
        // (and poisoned 2026-07-09 anchors replaced) by the repair gate,
        // which picks its legacy child deterministically from the store.
        repairColourAnchorIfNeeded(projectKey: key)
        let before = colourAssignments.recordCount
        let record = ColourEngine.projectRecord(key, in: &colourAssignments)
        if colourAssignments.recordCount != before {
            scheduleColoursSave()
        }
        return NSColor(hex: record.hex)
    }

    /// The pre-engine per-task hash colour (djb2 of the ref description →
    /// HSB hue), kept ONLY so the one-time colours.json migration can
    /// snapshot what each already-seen task looked like. Never used for new
    /// allocation.
    private static func legacyHashColourHex(for ref: TaskRef) -> String {
        var hash: UInt64 = 5381
        for byte in String(describing: ref).utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        let hue = CGFloat(hash % 360) / 360
        let colour = NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1)
        let rgb = colour.usingColorSpace(.sRGB) ?? colour
        return String(format: "#%02X%02X%02X",
                      Int(rgb.redComponent * 255),
                      Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }

    public func setColour(_ colour: NSColor, for ref: TaskRef) {
        let previous = settings.taskColours[ref.storageKey]
        registerUndo("colour change") { [weak self] in
            self?.settings.taskColours[ref.storageKey] = previous
        }
        let rgb = colour.usingColorSpace(.sRGB) ?? colour
        let hex = String(format: "#%02X%02X%02X",
                         Int(rgb.redComponent * 255),
                         Int(rgb.greenComponent * 255),
                         Int(rgb.blueComponent * 255))
        settings.taskColours[ref.storageKey] = hex
    }

    /// Forgiving search over the full ranked task list.
    /// Forgiving search over the full ranked task list. Also matches a task by
    /// the words the learner has associated with it (e.g. "voting" finds the task
    /// you always work in a "voting" window, whatever its OP subject says).
    public func searchTasks(_ query: String) -> [WorkTask] {
        let base = fullPickList()
        let stamp = pickListCache?.at ?? Date()
        if let c = searchCache, c.query == query, c.basedOn == stamp { return c.results }
        let learning = attributor.learning
        let results = FuzzyMatch.filter(base, query: query) {
            learning.learnedValues(for: .task($0))
        }
        searchCache = (query, stamp, results)
        return results
    }

    /// Sorted, de-duplicated window (focus-span) edges in [from, to] — the
    /// times an edit can snap to so a tracked window lands wholly in one task
    /// instead of being split across the slice boundary.
    public func windowBoundaries(from: Date, to: Date) -> [Date] {
        var edges = Set<Date>()
        for s in (try? journal.spans(from: from, to: to)) ?? [] {
            edges.insert(s.start)
            edges.insert(s.end)
        }
        return edges.sorted()
    }

    /// Time Spent hierarchy for the pie: project -> task -> app, including
    /// the live session when the range covers now. Sessions crossing the
    /// range boundary are clipped so totals never double-count across days.
    public func spentNodes(from: Date, to: Date) -> [TimeAggregator.Node] {
        // RESOLVED view (D1): the pie shows the seconds posting bills.
        var sessions = ((try? journal.resolvedSessions(from: from, to: to)) ?? [])
            .filter { $0.id != Self.liveCheckpointID }   // internal recovery row
            .map { s -> Session in
                var c = s
                c.start = max(s.start, from)
                c.end = min(s.end, to)
                return c
            }
        if case .tracking(.task(let ref), let certainty) = trackerState,
           let since = tracker.liveSliceStart ?? targetSince, since < to, Date() > from {
            sessions.append(Session(id: Self.liveSessionID, task: ref,
                                    start: max(since, from), end: min(Date(), to),
                                    certainty: certainty))
        }
        let spans = (try? journal.spans(from: from, to: to)) ?? []
        // + [WorkTask.unknown]: the sentinel isn't seeded into taskCache (so
        // it never leaks into the pick list), but grouping/labelling here
        // needs to resolve it — otherwise Unknown-assigned time would show
        // as the generic ".local" fallback label instead of "Unknown".
        return TimeAggregator.byProject(sessions: sessions, tasks: taskCache + [WorkTask.unknown],
                                        spans: spans)
    }

    /// The journalled slices a live-start drag from `liveStart` back to
    /// `newStart` spans (live/checkpoint rows excluded). The overlap WARNING and
    /// the absorb TRIM BOTH derive from this one window, so what the user is
    /// warned about always equals what actually gets trimmed — a calendar-day
    /// anchor (used before) desynced the two when the drag crossed midnight.
    /// Bounded by the drag distance, never a full-history scan.
    private func liveEditContext(from newStart: Date, to liveStart: Date) -> [Session] {
        ((try? journal.sessions(from: newStart.addingTimeInterval(-2), to: liveStart)) ?? [])
            .filter { $0.id != Self.liveSessionID && $0.id != Self.liveCheckpointID }
    }

    /// Different-task slices the live start would cross if dragged to
    /// `newStart` — what an absorb would trim/delete. The timeline shows these
    /// as a warning before the second Save confirms.
    public func liveStartConflicts(newStart: Date) -> [Session] {
        guard case .tracking(.task(let ref), _) = trackerState else { return [] }
        let liveStart = tracker.liveSliceStart ?? targetSince ?? Date()
        guard newStart < liveStart else { return [] }
        return liveEditContext(from: newStart, to: liveStart)
            .filter { $0.task != ref && $0.end > newStart && $0.start < liveStart }
            .sorted { $0.start < $1.start }
    }

    /// Timeline edit of the live slice's start. Dragging it back behaves like
    /// dragging any slice's edge: same-task slices it reaches fold in (deleted,
    /// their time and comment absorbed into the one ongoing slice), and — when
    /// `absorbOtherTasks` is set (the timeline confirms via a warning first) —
    /// other-task slices it crosses are trimmed/deleted through the very same
    /// TimelineMath.trims path a normal edge drag uses. One undo step.
    public func adjustLiveStart(to date: Date, absorbOtherTasks: Bool = false) async {
        guard case .tracking(.task(let ref), _) = trackerState else { return }
        let liveStart = tracker.liveSliceStart ?? targetSince ?? Date()
        // Same window as the warning (liveStartConflicts) so warn-set == absorb-
        // set even across midnight.
        let context = liveEditContext(from: min(date, Date()), to: liveStart)

        let sameTask = context.filter {
            $0.task == ref && $0.start < liveStart
                && $0.end >= min(date, Date()).addingTimeInterval(-2)
        }
        let newStart = ([min(date, Date())] + sameTask.map(\.start)).min() ?? min(date, Date())
        let foldedNote = sameTask
            .compactMap { ($0.comment?.isEmpty == false) ? $0.comment : nil }
            .joined(separator: "; ")
        let otherTrims = absorbOtherTasks
            ? TimelineMath.trims(for: newStart, liveStart, in: context.filter { $0.task != ref })
            : []

        await undoGroup("extend \(name(of: .task(ref)))") {
            // The group's journal inverses restore the folded/trimmed ROWS;
            // this inverse restores the LIVE side (clock start, banked
            // elapsed, in-flight note) — without it, undo brought the rows
            // back under a live slice still stretched over them. Registered
            // first so it replays last: rows first, then the clock.
            if newStart != liveStart || !sameTask.isEmpty || !otherTrims.isEmpty {
                let priorTargetSince = targetSince
                let priorBanked = bankedElapsed
                let priorNote = manualNote
                registerUndo("restore live start") { [weak self] in
                    guard let self, case .tracking = self.trackerState else { return }
                    let current = self.tracker.liveSliceStart ?? liveStart
                    if liveStart < current {
                        self.tracker.backdateSessionStart(to: liveStart)
                    } else if liveStart > current {
                        self.tracker.trimSessionStart(to: liveStart)
                    }
                    self.targetSince = priorTargetSince
                    self.bankedElapsed = priorBanked
                    self.manualNote = priorNote
                    self.updateJournalSummary()
                    self.refreshTitle(force: true)
                }
            }
            for s in sameTask { await deleteTimelineSession(s) }
            for trim in otherTrims {
                if trim.delete { await deleteTimelineSession(trim.session) }
                else { await applyTimelineEdit(trim.session) }
            }
            if !sameTask.isEmpty || !otherTrims.isEmpty {
                tracker.backdateSessionStart(to: newStart)
                if !foldedNote.isEmpty, manualNote.isEmpty { manualNote = foldedNote }
            } else {
                tracker.adjustCurrentStart(to: newStart)
            }
            targetSince = newStart
            bankedElapsed = [:]
        }
        updateJournalSummary()
        refreshTitle(force: true)
    }

    /// The most recently tracked task — the obvious resume candidate. Looks back
    /// 36 h, not just "today", so just after midnight the candidate is still the
    /// task you were on at 23:50 rather than nothing.
    public func lastTrackedTask() -> WorkTask? {
        let lookback = Date().addingTimeInterval(-36 * 3600)
        guard let last = ((try? journal.sessions(from: lookback, to: Date())) ?? [])
            .filter({ $0.id != Self.liveCheckpointID }).last else {
            return nil
        }
        return taskCache.first { $0.ref == last.task }
    }

    /// The task to "revert" to: the last closed slice's task, but only when it
    /// differs from what we're tracking now (otherwise there is nothing to
    /// undo). Drives the popover's one-click "← <prev>" when a switch was wrong.
    public func revertTargetTask() -> WorkTask? {
        guard case .tracking(let current, _) = trackerState else { return nil }
        guard let prev = previousTask, .task(prev) != current,
              let task = taskCache.first(where: { $0.ref == prev }) else { return nil }
        return task
    }

    /// "That switch was wrong": fold the current (mis-attributed) running slice
    /// back onto the previous task, keeping the clock — no reset. Same machinery
    /// as the popover's "Change to".
    public func revertToLastTask() {
        guard let target = revertTargetTask() else { return }
        changeCurrentTask(to: target.ref)
    }

    /// A brand-new manual slice (drawn or gap-filled on the timeline).
    /// `origin`: .edited for timeline-drawn slices; claimIdleGap passes
    /// .manual ("I claim this time", not "I shaped these bounds").
    public func createTimelineSession(_ session: Session,
                                      origin: SliceOrigin = .edited) async {
        try? journal.save(session)
        try? journal.escalateOrigin(session.id, to: origin)
        registerUndo("create \(name(of: .task(session.task)))") { [weak self] in
            guard let self else { return }
            let saved = try? self.journal.session(id: session.id)
            await self.deleteTimelineSession(saved ?? session, undoable: false)
        }
        updateJournalSummary()
        await syncIfEnabled()
    }

    /// Persist a timeline edit; PATCH the OP entry when one exists.
    public func applyTimelineEdit(_ session: Session, undoable: Bool = true) async {
        if undoable,
           let previous = try? journal.session(id: session.id) {
            // A task-change edit also TEACHES (teachAssociation below);
            // snapshot so the inverse unlearns it exactly. Same-task edits
            // restore an identical snapshot — a no-op.
            let restoreLearning = previous.task != session.task
                ? attributorSnapshotRestore() : nil
            registerUndo("edit \(name(of: .task(previous.task)))") { [weak self] in
                guard let self else { return }
                var restore = previous
                // Trust the CURRENT row's remote linkage over the snapshot's:
                // a follow-on coalesce in the same undo group may have
                // absorbed this row (deleting its backend entry) and re-saved
                // it unlinked — restoring the snapshot's pointer would aim
                // every later PATCH at a dead entry. When nothing touched the
                // row, current == snapshot and this is a no-op.
                if let current = try? self.journal.session(id: previous.id) {
                    restore.opTimeEntryID = current.opTimeEntryID
                    restore.pushedToOP = current.pushedToOP
                }
                await self.applyTimelineEdit(restore, undoable: false)
                restoreLearning?()
            }
        }
        var session = session
        let previous = try? journal.session(id: session.id)
        // Task changed (e.g. a mis-filed slice reassigned in the editor): the
        // old OP entry belongs to the old work package — delete it, drop the
        // id, and let sync recreate under the new task. Also teach the
        // attributor so the same surface stops mis-filing in future.
        if let previous, previous.task != session.task {
            if let oldEntry = previous.opTimeEntryID, let backend {
                try? await backend.deleteTimeEntry(id: oldEntry)
            }
            session.opTimeEntryID = nil
            session.pushedToOP = false
            clearPrimaryPosting(session.id)   // re-enter the pm queue
            teachAssociation(for: session)
        }
        // A sub-minute session was marked handled without an OP entry; if an
        // edit grows it to pushable size it must re-enter the push queue.
        if session.pushedToOP, session.opTimeEntryID == nil,
           session.end.timeIntervalSince(session.start) >= 60 {
            session.pushedToOP = false
            clearPrimaryPosting(session.id)   // drop the skipped ledger row too
        }
        try? journal.update(session)
        try? journal.escalateOrigin(session.id, to: .edited)
        if let backend, backend.owns(session.task),
           let taskID = session.task.backendTaskID, let entryID = session.opTimeEntryID {
            do {
                try await backend.updateTimeEntry(
                    id: entryID, taskID: taskID, start: session.start,
                    duration: session.end.timeIntervalSince(session.start),
                    activityID: settings.activityOverrides[session.task] ?? settings.defaultActivityID,
                    comment: session.comment)
                DebugLog.write("timeline edit pushed to backend entry \(entryID)")
            } catch {
                lastError = "\(backend.displayName) update failed: \(error)"
            }
        } else if previous?.task != session.task {
            await syncIfEnabled()   // reassigned: push under the new task
        }
        updateJournalSummary()
    }

    /// The longest focus span inside a session — the surface that dominated it,
    /// for teaching a durable window→task (or →don't-track) association.
    private func dominantSpan(of session: Session) -> FocusSpan? {
        ((try? journal.spans(from: session.start, to: session.end)) ?? [])
            .max { $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start) }
    }

    /// Teach the attributor the dominant surface→task association inside a
    /// reassigned session, so future time on that window stops mis-filing.
    private func teachAssociation(for session: Session) {
        // Unknown task category: re-pointing to Unknown is an explicit
        // "don't know", not a correction — same guard `assignReview` applies
        // (Target.teachesAttributor), so a span allocated to Unknown via any
        // of this helper's callers never masquerades as learned evidence.
        guard Target.task(session.task).teachesAttributor else { return }
        guard let dominant = dominantSpan(of: session) else { return }
        attributor.assign(dominant.signal, target: .task(session.task), tasks: taskCache)
        persistAssociations()
    }

    /// "Don't track this": drop the slice's tracked time (and any OP entry) but
    /// keep its window detail, and teach the attributor its dominant surface is
    /// non-work so similar time stops auto-tracking. Undo restores the slice.
    /// Used to undo e.g. an away stretch you didn't actually work.
    public func markSessionDoNotTrack(_ session: Session) async {
        // ONE ⌘Z step restoring BOTH halves: the slice comes back AND the
        // don't-track teaching is unlearned — previously undo restored the
        // slice but the surface kept auto-suppressing future tracking.
        await undoGroup("don't track \(name(of: .task(session.task)))") {
            if let dominant = dominantSpan(of: session) {
                let restore = attributorSnapshotRestore()
                attributor.assign(dominant.signal, target: .doNotTrack, tasks: taskCache)
                persistAssociations()
                registerUndo("unlearn don't-track") { restore() }
            }
            await deleteTimelineSession(session)
        }
    }

    public func deleteTimelineSession(_ session: Session, undoable: Bool = true) async {
        if undoable {
            var restore = session
            restore.opTimeEntryID = nil
            restore.pushedToOP = false   // re-push on restore
            registerUndo("delete \(name(of: .task(session.task)))") { [weak self] in
                guard let self else { return }
                try? self.journal.save(restore)
                self.updateJournalSummary()
                await self.syncIfEnabled()
            }
        }
        try? journal.deleteSession(session.id)
        // The pm entry is deleted below, so the pm row must go too (an undo
        // restore re-pushes). Finance rows stay: their entries are untouched.
        clearPrimaryPosting(session.id)
        if let entryID = session.opTimeEntryID, let backend {
            try? await backend.deleteTimeEntry(id: entryID)
        }
        updateJournalSummary()
    }

    public func reassignTimelineSessions(_ sessions: [Session], to task: TaskRef,
                                          undoable: Bool = true) async {
        if undoable {
            let originals = sessions.filter { $0.id != Self.liveSessionID }
            let restoreLearning = attributorSnapshotRestore()
            registerUndo("reassign \(originals.count) slices") { [weak self] in
                guard let self else { return }
                // restore each to its original task
                for original in originals {
                    await self.reassignTimelineSessions(
                        (try? self.journal.allSessions())?.filter { $0.id == original.id } ?? [],
                        to: original.task, undoable: false)
                }
                // The forward reassign TAUGHT the new association (and the
                // re-point above taught the old one back); restore the exact
                // pre-reassign learned state on top of both.
                restoreLearning()
            }
        }
        for var session in sessions where session.id != Self.liveSessionID {
            // Re-creating under the new task is simpler and more reliable than
            // PATCHing the work-package link.
            if let entryID = session.opTimeEntryID, let backend {
                try? await backend.deleteTimeEntry(id: entryID)
            }
            session.task = task
            session.opTimeEntryID = nil
            session.pushedToOP = false
            clearPrimaryPosting(session.id)   // recreate under the new task
            try? journal.update(session)
            try? journal.escalateOrigin(session.id, to: .edited)
            teachAssociation(for: session)   // stop the same window mis-filing again
        }
        await syncIfEnabled()
    }

    /// One-line feedback for the Spent view (also forces a refresh since it
    /// is @Published — the pie reads the journal, which the reassign changed).
    @Published public private(set) var actionNote: String?

    /// Move time spent in app `appLabel` to `target` across a period — by
    /// SPLITTING each session at that app's window spans (the Games time is
    /// usually a minor slice of a larger task's sessions, so whole-session
    /// matching found nothing). Teaches the attributor so it stops recurring.
    public func reassignSpentApp(_ appLabel: String, from: Date, to: Date,
                                 to target: TaskRef) async {
        let candidates = ((try? journal.sessions(from: from, to: to)) ?? [])
            .filter { $0.task != target }
        var work: [(Session, [Session])] = []
        var movedSeconds: TimeInterval = 0
        for session in candidates {
            let spans = ((try? journal.spans(from: session.start, to: session.end)) ?? [])
                .filter { $0.signal.app == appLabel }
            guard !spans.isEmpty else { continue }
            let ranges = spans.map {
                (start: max($0.start, session.start), end: min($0.end, session.end))
            }
            let pieces = TimelineMath.split(session, reassign: ranges, to: target)
            let moved = pieces.filter { $0.task == target }
            guard !moved.isEmpty else { continue }
            movedSeconds += moved.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
            work.append((session, pieces))
        }
        guard !work.isEmpty else {
            actionNote = "No \(appLabel) windows recorded in this period to move"
            return
        }
        await undoGroup("move \(appLabel) → \(name(of: .task(target)))") {
            let restoreLearning = attributorSnapshotRestore()
            registerUndo("unteach move") { restoreLearning() }
            for (session, pieces) in work { await replaceSession(session, with: pieces) }
        }
        actionNote = "Moved \(MenuTitle.text(elapsed: movedSeconds, certainty: nil, showPercent: false)) of \(appLabel) → \(name(of: .task(target)))"
    }

    private var coalescing = false
    /// Serialises sync: `syncIfEnabled` is fired from many places (every slice
    /// flush, the 60 s timer, every timeline edit). Without this, two overlapping
    /// runs both fetch the same unpushed session across their network `await` and
    /// both POST it — the duplicate-OP-entry bug. `syncRequested` runs one more
    /// pass if a trigger arrived mid-sync, so nothing eligible is missed.
    private var syncing = false
    private var syncRequested = false

    /// Merge same-task sessions that now butt up against each other (after an
    /// edit/drag) into one, without losing data. Direct journal+OP cleanup,
    /// guarded against re-entry.
    public func coalesceAdjacent(around date: Date) async {
        guard !coalescing else { return }
        coalescing = true
        defer { coalescing = false }
        // A window AROUND the edit point, not the calendar day — so two same-
        // task slices straddling midnight (23:50–00:20) still fold into one.
        // Bounded (±12 h) so it never becomes a full-history scan.
        let from = date.addingTimeInterval(-12 * 3600)
        let to = date.addingTimeInterval(12 * 3600)
        let original = ((try? journal.sessions(from: from, to: to)) ?? [])
            .filter { $0.id != Self.liveCheckpointID }   // never fold the crash-safety row
        let merged = TimelineMath.mergeAdjacent(original)
        guard merged.count != original.count else { return }
        // Compensating undo, registered BEFORE mutating: the exact prior rows
        // come back — absorbed originals re-saved (remote linkage cleared,
        // their backend entries are deleted below; sync re-creates), and each
        // rewritten survivor restored to its prior extent (its still-live
        // backend entry PATCHed back). Inside a caller's undoGroup (a timeline
        // save, an idle-gap claim) this folds into that ONE ⌘Z step, so
        // undoing an edit whose save fused neighbours restores the pre-edit
        // rows — not the fused row (the 2026-07-09 comment-edit incident).
        let plan = TimelineMath.coalescePlan(original: original, merged: merged)
        registerUndo("merge adjacent slices") { [weak self] in
            guard let self else { return }
            for var row in plan.removed {
                row.opTimeEntryID = nil
                row.pushedToOP = false   // its entry was deleted; re-push
                try? self.journal.save(row)
            }
            for rewrite in plan.rewrites {
                let prior = rewrite.prior
                try? self.journal.update(prior)
                if let backend = self.backend, backend.owns(prior.task),
                   let taskID = prior.task.backendTaskID,
                   let entryID = prior.opTimeEntryID {
                    try? await backend.updateTimeEntry(
                        id: entryID, taskID: taskID, start: prior.start,
                        duration: prior.end.timeIntervalSince(prior.start),
                        activityID: self.settings.activityOverrides[prior.task]
                            ?? self.settings.defaultActivityID,
                        comment: prior.comment)
                }
            }
            self.updateJournalSummary()
            await self.syncIfEnabled()
        }
        let survivors = Set(merged.map(\.id))
        for o in original where !survivors.contains(o.id) {
            try? journal.deleteSession(o.id)
            clearPrimaryPosting(o.id)   // absorbed: its pm entry is deleted below
            if let e = o.opTimeEntryID, let backend { try? await backend.deleteTimeEntry(id: e) }
        }
        for m in merged where original.first(where: { $0.id == m.id }) != m {
            var survivor = m
            // The survivor keeps the earliest slice's id (and OP entry). If that
            // entry already exists on OP, rewrite it IN PLACE to the merged
            // extent — `pushEligible` only ever *creates*, so a re-push would
            // duplicate the log. Patch + mark handled; leave only never-pushed
            // survivors for sync to create fresh.
            if let backend, backend.owns(survivor.task),
               let taskID = survivor.task.backendTaskID,
               let entryID = survivor.opTimeEntryID {
                do {
                    try await backend.updateTimeEntry(
                        id: entryID, taskID: taskID, start: survivor.start,
                        duration: survivor.end.timeIntervalSince(survivor.start),
                        activityID: settings.activityOverrides[survivor.task] ?? settings.defaultActivityID,
                        comment: survivor.comment)
                    survivor.pushedToOP = true   // updated in place; don't re-create
                    setPrimaryPosted(survivor.id, entryID: entryID)
                    DebugLog.write("coalesce patched backend entry \(entryID)")
                } catch {
                    // Keep it handled rather than risk a duplicate; the stale
                    // entry can be re-synced by a later edit.
                    survivor.pushedToOP = true
                    setPrimaryPosted(survivor.id, entryID: entryID)
                    lastError = "\(backend.displayName) merge-update failed: \(error)"
                }
            }
            try? journal.update(survivor)
        }
        await syncIfEnabled()
        updateJournalSummary()
        DebugLog.write("coalesced \(original.count) → \(merged.count) sessions")
    }

    /// Replace a session with split pieces (delete original + OP entry,
    /// create each piece, teach moved pieces). Caller wraps in an undo group.
    private func replaceSession(_ session: Session, with pieces: [Session]) async {
        await deleteTimelineSession(session)
        for piece in pieces { await createTimelineSession(piece) }
        for piece in pieces where piece.task != session.task { teachAssociation(for: piece) }
    }

    /// Split a slice: the given time ranges (selected windows in the detail
    /// strip) move to `target`, the rest stays. One undo step.
    ///
    /// The block those windows came from can be backed by MORE THAN ONE journal
    /// session — the live block folds earlier contiguous same-task rows into a
    /// single displayed slice (see `timelineSessions`), and a post-flush
    /// coalesce can lag. Splitting only `session` silently dropped any selected
    /// window living in an earlier row: the clip in `TimelineMath.split` emptied,
    /// the guard returned, and the move did nothing. So gather EVERY same-task
    /// session overlapping the selected ranges and split each. `session` names
    /// the block's task; live callers pass the just-committed tail (via
    /// `commitLiveSlice`) so its own windows are already a real row here.
    public func splitAndReassign(_ session: Session,
                                 ranges: [(start: Date, end: Date)],
                                 to target: TaskRef) async {
        guard let lo = ranges.map({ $0.start }).min(),
              let hi = ranges.map({ $0.end }).max() else { return }
        let sessions = ((try? journal.sessions(from: lo.addingTimeInterval(-2),
                                               to: hi.addingTimeInterval(2))) ?? [])
            .filter { $0.task == session.task
                        && $0.id != Self.liveCheckpointID && $0.id != Self.liveSessionID }
        let work = TimelineMath.splitAcross(sessions, reassign: ranges, to: target)
        guard !work.isEmpty else { return }
        await undoGroup("split \(name(of: .task(session.task)))") {
            // Registered first → replays last: after the rows are restored,
            // the teaching the moved pieces wrote is unlearned too.
            let restoreLearning = attributorSnapshotRestore()
            registerUndo("unteach split") { restoreLearning() }
            for (original, pieces) in work { await replaceSession(original, with: pieces) }
        }
    }

    /// Timeline span-select "Allocate": the counterpart to `splitAndReassign`
    /// for an arbitrary TIME RANGE that isn't scoped to one slice's task (a
    /// shift-drag / shift-click selection on the bar, not bound to any
    /// slice's edges). Sessions wholly inside the range re-point in place via
    /// the same whole-slice reassign path the old reassign bar uses; ones
    /// straddling an edge go through the same split-and-replace path the
    /// detail strip's window moves already use. One undo step for the whole
    /// gesture. Teaching and the pushed-session re-queue both ride along for
    /// free through those two paths — including the Unknown no-teach guard
    /// in `teachAssociation`, so allocating to Unknown never masquerades as
    /// learned evidence.
    public func allocateSpan(from start: Date, to end: Date, target: TaskRef) async {
        guard end > start else { return }
        let sessions = ((try? journal.sessions(from: start.addingTimeInterval(-2),
                                               to: end.addingTimeInterval(2))) ?? [])
            .filter { $0.id != Self.liveCheckpointID && $0.id != Self.liveSessionID }
        let plan = SpanAllocation.plan(sessions: sessions, range: (start, end), to: target)
        guard !plan.isEmpty else { return }
        await undoGroup("allocate \(name(of: .task(target)))") {
            // Registered first → replays last: rows back, then the exact
            // pre-allocate learned state (both paths below teach).
            let restoreLearning = attributorSnapshotRestore()
            registerUndo("unteach allocate") { restoreLearning() }
            for action in plan {
                switch action {
                case .repoint(let original):
                    await reassignTimelineSessions([original], to: target)
                case .split(let original, let pieces):
                    await replaceSession(original, with: pieces)
                }
            }
        }
    }

    /// Reassign a whole task's period sessions to another task.
    public func reassignSpentTask(_ ref: TaskRef, from: Date, to: Date,
                                  to target: TaskRef) async {
        let sessions = ((try? journal.sessions(from: from, to: to)) ?? [])
            .filter { $0.task == ref }
        await reassignTimelineSessions(sessions, to: target)
        actionNote = sessions.isEmpty
            ? "No time found to move"
            : "Moved \(sessions.count) session\(sessions.count == 1 ? "" : "s") → \(name(of: .task(target)))"
    }

    // MARK: - AI assist (clipboard out, paste back)

    public func copyAIPrompt() {
        let prompt = AIAssist.classificationPrompt(tasks: taskCache, segments: pendingReview)
        copyToClipboard(prompt)
    }

    /// Put a string on the general pasteboard (the AI-assist flows copy a prompt
    /// for the user to paste into the AI of their choice).
    public func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The raw app / title / url of the current focus surface — the fields the
    /// AI pin prompt is built from. nil when there's nothing focused.
    public func currentSurfaceFields() -> (app: String, title: String?, url: String?)? {
        guard let s = tracker.currentFocusSignal else { return nil }
        return (s.app, s.windowTitle, s.tabURL)
    }

    /// Dev diagnostic: probe the front browser's AX tree for sender candidates,
    /// format a report, and copy it to the clipboard. Drives the email-sender
    /// signal design (TODO 2026-06-29). Shares `EmailCaptureEngine`'s
    /// deadline-bounded `osascript` channel with live capture (2026-07-03),
    /// so it blocks up to a couple of seconds — run off the main actor via
    /// `Task.detached`; only the clipboard write needs to be back on main.
    public func probeEmailSender() async -> String {
        let probe = await Task.detached(priority: .utility) {
            EmailSignalProbe.buildReport()
        }.value
        // Tracker-side ground truth: what the pin editor would see right
        // now. When the browser probe above succeeds but the grain ladder
        // still doesn't show, the divergence is in this half.
        var out = probe + "\n\n— tracker state —\n"
        out += "state: \(trackerState)\n"
        if let s = tracker.currentFocusSignal {
            out += "signal: app=\(s.app)  title=\(s.windowTitle ?? "nil")\n"
            let host = s.tabURL.flatMap { URL(string: $0)?.host }
            out += "tabURL: \(s.tabURL ?? "nil")  (host: \(host ?? "nil") → \(EmailSystem.detect(urlHost: host).rawValue))\n"
            out += "correspondents: \(s.correspondents?.joined(separator: ", ") ?? "nil")\n"
            out += "subject: \(s.emailSubject ?? "nil")\n"
            let id = attributor.identity(of: s)
            out += "identity: " + id.segments.map {
                "\($0.kind)\($0.available ? "" : "(not captured)")=\($0.display)"
            }.joined(separator: " ▸ ") + "\n"
            out += "pinEmailIdentity: \(pinEmailIdentity() != nil ? "LADDER" : "nil → classic strip")\n"
        } else {
            out += "signal: nil (nothing observed while tracking yet)\n"
        }
        out += "currentPin: \(currentPin.map { String(describing: $0.pin.rule) } ?? "none")\n"
        let recipeHealth = sensors.emailRecipeHealth()
        out += "recipeHealth: " + (recipeHealth.isEmpty ? "no validated captures yet"
            : recipeHealth.map { system, record in
                "\(system.rawValue)=\(record.isUnhealthy ? "UNHEALTHY" : "ok") "
                    + "(streak \(record.consecutiveFailures)"
                    + "\(record.lastFault.map { ", last \($0.rawValue)" } ?? ""))"
            }.sorted().joined(separator: "  ")) + "\n"
        copyToClipboard(out)
        return out
    }

    public func ingestAIResponse(_ raw: String) -> String {
        do {
            let assignments = try AIAssist.parseResponse(
                raw, validSegmentIDs: Set(pendingReview.map(\.id)),
                taskRefByID: AIAssist.taskRefLookup(taskCache))
            for a in assignments {
                assignReview([a.segmentID], to: a.target)
            }
            return "Applied \(assignments.count) assignments."
        } catch {
            return "Rejected: \(error)"
        }
    }

    // MARK: - OP

    public func saveAPIKey(_ key: String) {
        do {
            try APIKeyStore.saveAPIKey(key)
        } catch {
            lastError = "API key save failed – \(error)"
            return
        }
        reconnect()
    }

    /// Reconnect using the already-stored API key — e.g. after re-entering only
    /// the instance URL (the key lives in its own file and need not be retyped).
    public func reconnect() {
        rebuildClient()
        Task { await refreshTasks() }
    }

    /// True when an API key is already on disk, so the UI can offer "Connect"
    /// without forcing a re-entry.
    public func hasStoredAPIKey() -> Bool {
        (try? APIKeyStore.loadAPIKey())?.isEmpty == false
    }

    /// The backend's web page for a remote task ("Open in OpenProject" etc.);
    /// nil when standalone or the backend has no task pages.
    public func taskWebURL(id: String) -> URL? {
        backend?.taskURL(id: id)
    }

    /// The backend's LOGGED-TIME page for a task — reconcile flows land here
    /// (OP: the cost report filtered to the work package) so "check the
    /// entries" doesn't dump the user on the task page to hunt. Falls back to
    /// the task page for backends without one.
    public func taskTimeEntriesWebURL(id: String) -> URL? {
        backend?.taskTimeEntriesURL(id: id) ?? backend?.taskURL(id: id)
    }

    /// The primary backend's display name, for menu labels ("Open in
    /// OpenProject"). nil in standalone mode.
    public var primaryBackendName: String? { backend?.displayName }

    /// The timestamped comment list stored locally against a task — the
    /// standalone half of comment-to-task (notes for .local tasks, backends
    /// without a comment endpoint, and failed posts land here). Newest last.
    public func storedTaskComments(for ref: TaskRef) -> [(date: Date, text: String)] {
        (try? journal.taskComments(for: ref)) ?? []
    }

    /// The journal for a period rendered as CSV or Markdown — the standalone
    /// way OUT of andeye (invoicing, records) with or without a backend.
    public enum TimesheetFormat { case csv, markdown }
    public func timesheetExport(period: TimePeriod, format: TimesheetFormat) -> String {
        let now = Date()
        let range = period.range(anchor: now, now: now)
        // The RESOLVED view (D1): the export shows the same seconds posting
        // bills — cross-device overlap trims apply to both or neither.
        let sessions = ((try? journal.resolvedSessions(from: range.start, to: range.end)) ?? [])
            .filter { $0.id != Self.liveCheckpointID }
        let resolve: TimesheetExport.NameResolver = { [weak self] ref in
            // The Unknown sentinel is never in taskCache (excluded from every
            // pick list on purpose) — resolve it directly so exported time
            // reads "Unknown", not the generic uncached-local fallback below.
            if ref == WorkTask.unknown.ref { return (WorkTask.unknown.subject, nil) }
            if let t = self?.taskCache.first(where: { $0.ref == ref }) {
                return (t.subject, t.project)
            }
            if ref.isRemote { return (ref.fallbackLabel, nil) }
            return ("(deleted local task)", nil)
        }
        switch format {
        case .csv: return TimesheetExport.csv(sessions: sessions, names: resolve)
        case .markdown: return TimesheetExport.markdown(sessions: sessions, names: resolve)
        }
    }

    /// The connected backend's name for UI copy ("OpenProject", "Xero"); nil
    /// when standalone.
    public var backendName: String? { backend?.displayName }

    public func refreshTasks() async {
        guard let backend else {
            if lastError == nil, !settings.opBaseURL.isEmpty {
                lastError = "Not connected – check OP URL and API key in Settings"
            }
            // Truly standalone (no backend configured): the local-only task
            // cache IS complete, so the colour-anchor repair era can close
            // now. A configured-but-unreachable backend does NOT close it —
            // its projects aren't resolvable yet, and adopting their
            // poisoned anchors here would lock the wrong colours in.
            if settings.opBaseURL.isEmpty {
                finalizeColourRepairsIfComplete()
            }
            return
        }
        do {
            if connectedAs == nil {
                connectedAs = try? await backend.fetchMe()
            }
            // Carry recency over the refresh: lastConfirmedAt lives only in
            // the cache and a wholesale replace was silently dropping it.
            let recency = Dictionary(uniqueKeysWithValues:
                taskCache.compactMap { task in task.lastConfirmedAt.map { (task.ref, $0) } })
            var fetched = try await backend.fetchTasks()
            for i in fetched.indices {
                if let last = recency[fetched[i].ref] {
                    fetched[i].lastConfirmedAt = max(fetched[i].lastConfirmedAt ?? .distantPast, last)
                }
            }
            taskCache = fetched + localWorkTasks().map { local in
                var task = local
                task.lastConfirmedAt = recency[local.ref]
                return task
            }
            applyJournalRecency()   // durable recency, not just this session's
            migrateTitleKeyedBilling()   // ids now known: move title-keyed flags
            // Backend fetch succeeded → the cache now holds every resolvable
            // project, under its final (id-based) key: sweep the colour
            // repair across all of them and close the repair era.
            finalizeColourRepairsIfComplete()

            if activities.isEmpty, backend.supportsActivities {
                activities = (try? await backend.fetchActivities()) ?? []
                if settings.defaultActivityID == nil {
                    settings.defaultActivityID = activities.first?.id
                }
            }
            lastError = nil
        } catch {
            lastError = "\(backend.displayName) fetch failed: \(error)"
        }
    }

    /// F16: a menu-bar app can run for weeks; a lease that lapsed (or a key
    /// that was renewed) must take effect without a relaunch. Cheap and pure,
    /// re-run hourly off the sync tick.
    private var lastLicenseRevalidation = Date.distantPast

    /// Invoice-poll throttle shared across the per-pass engines — a fresh
    /// clock per pass would re-poll the backend's invoice status every
    /// minute instead of half-hourly.
    private let invoicePollClock = InvoicePollClock()

    /// Per-backend posting health for Settings (A5): rows the queue can no
    /// longer move on its own. `stuck` = quarantined after the transient
    /// cap; `diverged` = posted entries the journal has since moved away
    /// from (D4 detection); `lockedInvoices` = sent invoices covering posted
    /// time (the invoice-lock layer) with a per-invoice unlock. Only
    /// backends with something to show appear.
    public struct PostingHealth: Identifiable {
        public let id: String        // backend id (ledger identity)
        public let name: String      // display name for the row
        public let stuck: Int
        public let diverged: Int
        public let lockedInvoices: [(ref: String, count: Int)]
    }

    public func postingHealthReport() -> [PostingHealth] {
        registry.entries.compactMap { entry in
            let stuck = ((try? journal.postingRecords(state: .stuck,
                                                      backendID: entry.id)) ?? []).count
            // Live drift (this pass, retrying) + PARKED frozen divergences
            // (terminal until a human reconciles).
            let diverged = (postingDivergences[entry.id] ?? 0)
                + ((try? journal.postingRecords(state: .diverged,
                                                backendID: entry.id)) ?? []).count
            // Invoice locks live on posted rows (and on rows that were
            // parked .diverged while locked) — grouped by invoice ref for
            // the per-invoice unlock gesture.
            var lockCounts: [String: Int] = [:]
            for state in [PostingState.posted, .diverged] {
                for row in ((try? journal.postingRecords(state: state,
                                                         backendID: entry.id)) ?? []) {
                    if let ref = row.lockedInvoiceRef { lockCounts[ref, default: 0] += 1 }
                }
            }
            let lockedInvoices = lockCounts.sorted { $0.key < $1.key }
                .map { (ref: $0.key, count: $0.value) }
            guard stuck > 0 || diverged > 0 || !lockedInvoices.isEmpty else { return nil }
            return PostingHealth(id: entry.id, name: entry.backend.displayName,
                                 stuck: stuck, diverged: diverged,
                                 lockedInvoices: lockedInvoices)
        }
    }

    /// Per-invoice unlock (the invoice-lock layer): lifts the app-side guard
    /// on every entry billed under `ref` so deliberate corrections can flow
    /// again; the same invoice is never auto re-locked. The Xero-side
    /// credit-note/void remains the accountant's act.
    public func unlockInvoice(ref: String, backendID: String) {
        SyncEngine(journal: journal, backends: registry.entries)
            .unlockInvoice(ref: ref, backendID: backendID)
        actionNote = "Unlocked invoice \(ref) — edits can reconcile again"
        Task { await syncIfEnabled() }
    }

    /// The repair gesture for quarantined rows: clearing a `.stuck` row puts
    /// its session back in the queue with a fresh attempt budget.
    public func retryStuck(backendID: String) {
        let rows = ((try? journal.postingRecords(state: .stuck, backendID: backendID)) ?? [])
        for row in rows {
            try? journal.clearPostingRecord(session: row.sessionID, backendID: backendID)
        }
        if !rows.isEmpty {
            actionNote = "Retrying \(rows.count) stuck entr\(rows.count == 1 ? "y" : "ies")"
            Task { await syncIfEnabled() }
        }
    }

    public func syncIfEnabled() async {
        if Date().timeIntervalSince(lastLicenseRevalidation) > 3_600 {
            lastLicenseRevalidation = Date()
            revalidateLicense()
        }
        guard !registry.isEmpty else { return }
        // Non-reentrant: if a push is already in flight, just ask it to run once
        // more when it finishes (a concurrent run would re-POST the same session
        // across its network await — duplicate backend entries).
        if syncing { syncRequested = true; return }
        syncing = true
        defer { syncing = false }
        let engine = SyncEngine(journal: journal, backends: registry.entries,
                                invoicePollClock: invoicePollClock)
        engine.excludedSessionIDs = [Self.liveCheckpointID]
        engine.onDebug = { DebugLog.write("sync: \($0)") }
        // D2(a): the posting-owner gate. The owner map is empty until it
        // becomes a synced setting (D2(b)) — empty = ownership off, so
        // single-device behaviour is byte-for-byte unchanged today.
        engine.localDeviceID = syncClock?.deviceID
        engine.postingOwners = postingOwners
        repeat {
            syncRequested = false
            // Snapshot billability into VALUES before the off-main awaits: the
            // engine resumes off the main actor, so the closure must not read
            // live controller state.
            let rules = billing
            let projectKeys = projectKeyByTask()
            let reports = await engine.pushEligible(
                threshold: settings.certaintyAutoPushThreshold,
                defaultActivityID: settings.defaultActivityID,   // nil = OP's default
                activityOverrides: settings.activityOverrides,
                includeComments: settings.autoComment,
                financeEligible: { session in
                    rules.financeEligible(task: session.task,
                                          projectKey: projectKeys[session.task],
                                          sessionStart: session.start)
                },
                financePostFloor: settings.financeAutoPostWindowDays > 0
                    ? Date().addingTimeInterval(-settings.financeAutoPostWindowDays * 86_400)
                    : nil)
            for report in reports where report.posted > 0 {
                let name = registry.entry(id: report.backendID)?.backend.displayName
                    ?? report.backendID
                DebugLog.write("pushed \(report.posted) entries to \(name)")
            }
            for report in reports where report.permanentlySkipped > 0 {
                let name = registry.entry(id: report.backendID)?.backend.displayName
                    ?? report.backendID
                DebugLog.write("\(name): \(report.permanentlySkipped) permanently rejected, closed off")
                lastError = "\(name) refused \(report.permanentlySkipped) "
                    + (report.permanentlySkipped == 1 ? "entry" : "entries")
                    + " permanently (task deleted or frozen) — they won't retry"
            }
            // D4 detection: posted entries the journal has since moved away
            // from (edit/trim/delete after posting). Published per backend so
            // Settings can show "N entries need re-syncing"; amendment is the
            // follow-on feature.
            postingDivergences = Dictionary(uniqueKeysWithValues: reports
                .filter { $0.diverged > 0 }
                .map { ($0.backendID, $0.diverged) })
            for (backendID, n) in postingDivergences {
                let name = registry.entry(id: backendID)?.backend.displayName ?? backendID
                DebugLog.write("\(name): \(n) posted entr\(n == 1 ? "y" : "ies") diverged from the journal")
            }
            if let op = backend as? OPBackend, !op.startTimesSupported {
                lastError = "OP rejected start times – entries pushed date-only (check Administration → Time and costs → start/end times)"
            }
            if let failing = reports.first(where: { $0.error != nil }), let error = failing.error {
                let name = registry.entry(id: failing.backendID)?.backend.displayName
                    ?? failing.backendID
                lastError = "\(name) push failed: \(error)"
            }
        } while syncRequested
        updateJournalSummary()
    }

    // MARK: - Billable flags (project Bool, task tri-state)

    /// The user's billable rules — its own user-ownable file (billing.json),
    /// keyed by stable backend-scoped project ids. Default non-billable.
    @Published public private(set) var billing: BillableRules

    private func saveBilling() {
        try? billingStore.save(billing)
    }

    /// Stable project key for a task's containing project (see BillableRules
    /// key builders): id-based when the backend project id was captured,
    /// title-based fallback until the next task refresh migrates it, name-
    /// based for local projects. nil when the task has no project at all.
    public func projectKey(for task: WorkTask) -> String? {
        if case .local = task.ref {
            return BillableRules.localProjectKey(task.project ?? "Personal")
        }
        let owner = registry.entries.first { $0.backend.owns(task.ref) }?.id
            ?? OPBackend.stableID
        if let projectID = task.projectID {
            return BillableRules.projectKey(backendID: owner, projectID: projectID)
        }
        guard let title = task.project else { return nil }
        return BillableRules.titleProjectKey(backendID: owner, title: title)
    }

    /// Snapshot of every cached task's project key, for the sync closure.
    private func projectKeyByTask() -> [TaskRef: String] {
        Dictionary(uniqueKeysWithValues: taskCache.compactMap { task in
            projectKey(for: task).map { (task.ref, $0) }
        })
    }

    // MARK: - Finance mappings (D6 Settings editor)

    /// Whether the Billing-mappings Settings section shows at all.
    public var hasFinanceBackend: Bool {
        registry.entries.contains { $0.backendClass == .finance }
    }

    /// The finance backend's own tasks, fetched for the mapping pickers —
    /// (backendID, displayName, tasks). Refreshed on section appearance;
    /// a fetch failure leaves the previous options standing.
    @Published public private(set) var financeTaskOptions:
        [(backendID: String, name: String, tasks: [WorkTask])] = []

    public func refreshFinanceTaskOptions() async {
        var out: [(backendID: String, name: String, tasks: [WorkTask])] = []
        for entry in registry.entries where entry.backendClass == .finance {
            guard let tasks = try? await entry.backend.fetchTasks() else { continue }
            out.append((entry.id, entry.backend.displayName,
                        tasks.sorted { ($0.project ?? "", $0.subject) < ($1.project ?? "", $1.subject) }))
        }
        if !out.isEmpty || financeTaskOptions.isEmpty { financeTaskOptions = out }
    }

    /// The BILLABLE remote projects — the rows of the mapping editor (only
    /// billable time ever reaches a finance backend, so unmapped
    /// non-billable projects are noise).
    public func billableSourceProjects() -> [(name: String, key: String)] {
        var seen = Set<String>()
        var out: [(name: String, key: String)] = []
        for task in taskCache {
            guard task.ref.isRemote, let name = task.project,
                  !seen.contains(name), isProjectBillable(named: name),
                  let key = projectKey(for: task) else { continue }
            seen.insert(name)
            out.append((name, key))
        }
        return out.sorted { $0.name < $1.name }
    }

    public func financeMapping(forProjectKey key: String) -> FinanceMapping? {
        financeMappings.mappings[key]
    }

    /// The Settings gesture: map (or nil = unmap) a source project to a
    /// finance-backend task. Persistence + the criterion-10 reopen ride the
    /// store's change handler.
    public func setFinanceMapping(projectKey: String, backendTaskID: String?) {
        let prior = financeMappings.mappings[projectKey]
        let new = backendTaskID.map(FinanceMapping.init)
        guard prior != new else { return }
        registerUndo("billing mapping") { [weak self] in
            self?.financeMappings.set(prior, forProjectKey: projectKey)
        }
        financeMappings.set(new, forProjectKey: projectKey)
    }

    /// The cached tasks belonging to a project as DISPLAYED (the pie/legend
    /// label) — the cascade's membership and the flip's stranded-time scope.
    public func tasksInProject(named name: String) -> [WorkTask] {
        taskCache.filter { $0.project == name }
    }

    public func isProjectBillable(named name: String) -> Bool {
        guard let first = tasksInProject(named: name).first else { return false }
        return billing.projectBillable(projectKey(for: first))
    }

    public func taskBillableState(_ ref: TaskRef) -> BillableState {
        billing.taskState(ref)
    }

    /// Effective billability of one task (override else project else
    /// non-billable) — drives the UI's checkmarks.
    public func isTaskBillable(_ task: WorkTask) -> Bool {
        billing.effectiveBillable(task: task.ref, projectKey: projectKey(for: task))
    }

    /// Flip a project's billable flag. Cascades to INHERITING tasks only
    /// (inheritance is resolved at read time, so no task rows are touched);
    /// the report carries the manually-set tasks left behind and the
    /// confirmed hours the flip strands uninvoiced — the UI alert's data.
    /// Undoable. Returns nil when the project has no cached tasks to key on.
    @discardableResult
    public func setProjectBillable(named name: String, billable: Bool) -> BillableFlipReport? {
        let members = tasksInProject(named: name)
        guard let first = members.first, let key = projectKey(for: first) else { return nil }
        guard billing.projectBillable(key) != billable else { return nil }
        let report = BillableFlipReport(
            name: name, billable: billable,
            leftBehind: billing.manuallySetTasks(in: members),
            strandedSeconds: strandedFinanceSeconds(tasks: Set(members.map(\.ref))))
        let previous = billing
        registerUndo("mark \(name) \(billable ? "billable" : "non-billable")") { [weak self] in
            self?.billing = previous
            self?.saveBilling()
        }
        billing.setProject(key, billable: billable)
        saveBilling()
        Task { await syncIfEnabled() }   // prospective: new time follows the new flag
        return report
    }

    /// Set one task's tri-state override (`.inherit` clears it). Undoable;
    /// the report warns about stranded time exactly like a project flip.
    @discardableResult
    public func setTaskBillable(_ task: WorkTask, state: BillableState) -> BillableFlipReport? {
        guard billing.taskState(task.ref) != state else { return nil }
        let becomesBillable = state == .billable
            || (state == .inherit && billing.projectBillable(projectKey(for: task)))
        let report = BillableFlipReport(
            name: task.subject, billable: becomesBillable, leftBehind: [],
            strandedSeconds: strandedFinanceSeconds(tasks: [task.ref]))
        let previous = billing
        registerUndo("billable setting \(task.subject)") { [weak self] in
            self?.billing = previous
            self?.saveBilling()
        }
        billing.setTask(task.ref, state: state)
        saveBilling()
        Task { await syncIfEnabled() }
        return report
    }

    /// Confirmed, uninvoiced seconds on `tasks`: what a billability flip
    /// strands (billable→off stops these posting; off→billable leaves them
    /// behind the prospective-only gate). "Uninvoiced" = no `.posted` ledger
    /// row against any finance-class backend — with none registered (the
    /// community build), everything unposted counts, which is exactly the
    /// history that will never invoice.
    private func strandedFinanceSeconds(tasks: Set<TaskRef>) -> TimeInterval {
        let sessions = ((try? journal.allSessions()) ?? [])
            .filter { $0.id != Self.liveCheckpointID }
        let financeIDs = Set(registry.entries(class: .finance).map(\.id))
        var posted: Set<UUID> = []
        if !financeIDs.isEmpty {
            for session in sessions where tasks.contains(session.task) {
                let rows = (try? journal.postingRecords(session: session.id)) ?? []
                if rows.contains(where: { financeIDs.contains($0.backendID) && $0.state == .posted }) {
                    posted.insert(session.id)
                }
            }
        }
        return Billing.strandedSeconds(sessions: sessions, tasks: tasks,
                                       threshold: settings.certaintyAutoPushThreshold,
                                       postedSessionIDs: posted)
    }

    /// One-time title-key → id-key billing migration: once a task refresh has
    /// captured project ids, any flag still keyed by title moves to the id
    /// key (so subsequent renames keep it). Idempotent; runs after every
    /// refresh, doing nothing once no title keys remain.
    private func migrateTitleKeyedBilling() {
        var mapping: [String: String] = [:]
        for task in taskCache {
            guard !task.isLocalOnly, let projectID = task.projectID,
                  let title = task.project else { continue }
            let owner = registry.entries.first { $0.backend.owns(task.ref) }?.id
                ?? OPBackend.stableID
            let titleKey = BillableRules.titleProjectKey(backendID: owner, title: title)
            guard billing.projects[titleKey] != nil else { continue }
            mapping[titleKey] = BillableRules.projectKey(backendID: owner, projectID: projectID)
        }
        guard !mapping.isEmpty else { return }
        billing.migrateProjectKeys(mapping)
        saveBilling()
        // Colour anchors share the billing key convention (colour-strategy
        // spec, open question 7), so they migrate on the same trigger — a
        // project rename after id capture keeps its hue anchor.
        if colourAssignments.migrateProjectKeys(mapping) > 0 {
            try? coloursStore.save(colourAssignments)
        }
    }
}

/// Notifications when running as a real .app bundle; silent no-op otherwise
/// (UNUserNotificationCenter requires a bundle identifier).
/// Last-words crash logging: the app has died "for no apparent reason" more
/// than once; these traps write the cause into the debug log before dying.
/// (Not strictly async-signal-safe — best-effort forensics, not correctness.)
func installCrashTraps() {
    NSSetUncaughtExceptionHandler { exception in
        DebugLog.write("CRASH NSException \(exception.name.rawValue): \(exception.reason ?? "?")\n"
            + exception.callStackSymbols.prefix(10).joined(separator: "\n"))
    }
    for sig in [SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
        signal(sig) { s in
            DebugLog.write("CRASH signal \(s)\n"
                + Thread.callStackSymbols.prefix(10).joined(separator: "\n"))
            exit(128 + s)
        }
    }
}

/// Diagnostic event log at a world-readable path so remote debugging over the
/// scoped SSH user works (the agent cannot read Martin's home). Window titles
/// appear in it; delete the file to clear, toggle by removing write access.
public enum DebugLog {
    public static let path = "/Users/Shared/andeye-debug.log"
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    public static func write(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }
}

/// Self-drawn floating banner. Deliberately NO system notification API:
/// UNUserNotificationCenter aborts the process on code-identity churn and
/// NSUserNotification is dead on modern macOS (never displayed, crashed on
/// delivery) — both bitten us. A floating panel needs no permissions and
/// cannot take the app down.
enum Notifier {
    /// Wired to AndeyeSettings.systemNotifications; sounds still play when off.
    static var enabled = true
    private static var panel: NSPanel?
    private static var dismissTask: DispatchWorkItem?

    static func requestAuthorization() {}

    /// `symbol` is an SF Symbol name drawn as the leading glyph (the "logo"),
    /// so a task change reads as "→ andeye" rather than the slow-to-read
    /// "Task changed — andeye". Falls back to text only if the symbol is
    /// unavailable.
    static func notify(symbol: String?, text: String, sound: String) {
        DispatchQueue.main.async {
            NSSound(named: sound)?.play()
            guard enabled else { return }
            showBanner(symbol: symbol, text: text)
        }
    }

    /// Back-compat text-only entry point.
    static func notify(title: String, body: String, sound: String) {
        notify(symbol: nil, text: "\(title) — \(body)", sound: sound)
    }

    private static func showBanner(symbol: String?, text: String) {
        dismissTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        guard let screen = NSScreen.main else { return }

        let padding: CGFloat = 14
        let iconSize: CGFloat = 17
        let gap: CGFloat = 8

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.sizeToFit()

        var iconView: NSImageView?
        if let symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            image.isTemplate = true
            let view = NSImageView(image: image)
            view.contentTintColor = .labelColor
            view.symbolConfiguration = .init(pointSize: iconSize, weight: .semibold)
            iconView = view
        }

        let iconSpace = iconView == nil ? 0 : iconSize + gap
        let textWidth = min(label.frame.width, 360)
        let width = padding * 2 + iconSpace + textWidth
        let height = max(label.frame.height, iconSize) + padding * 1.2
        let rect = NSRect(x: screen.visibleFrame.maxX - width - 16,
                          y: screen.visibleFrame.maxY - height - 12,
                          width: width, height: height)

        let p = NSPanel(contentRect: rect, styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: rect.size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10

        if let iconView {
            iconView.frame = NSRect(x: padding, y: (height - iconSize) / 2,
                                    width: iconSize, height: iconSize)
            background.addSubview(iconView)
        }
        label.frame = NSRect(x: padding + iconSpace, y: (height - label.frame.height) / 2,
                             width: textWidth, height: label.frame.height)
        background.addSubview(label)
        p.contentView = background
        p.orderFrontRegardless()
        panel = p

        let task = DispatchWorkItem { panel?.orderOut(nil); panel = nil }
        dismissTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: task)
    }
}
