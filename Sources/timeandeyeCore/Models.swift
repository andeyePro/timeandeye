import Foundation

package enum Andeye {
    package static let version = "0.1.0"
}

/// Identity of a task. `.op` = OpenProject work package; `.remote` = a task
/// in a GUID-keyed backend (Xero), id stored verbatim (the conformer
/// normalises case); `.local` = andeye-only (leisure tracking etc.), never
/// pushed. Additive cases only: the JSON wire shape of existing rows is
/// frozen by checks.
public enum TaskRef: Hashable, Codable, Sendable {
    case op(Int)
    case remote(String)
    case local(UUID)
}

public extension TaskRef {
    /// The id string a backend call needs: "\(n)" for .op, the GUID for
    /// .remote, nil for .local (local tasks never push).
    var backendTaskID: String? {
        switch self {
        case .op(let id): return String(id)
        case .remote(let id): return id
        case .local: return nil
        }
    }

    /// True for tasks that live in a remote backend — the push-eligibility
    /// test and the SQLite `is_op` column's real meaning.
    var isRemote: Bool { backendTaskID != nil }

    /// Label of last resort when the task cache has no subject for the ref.
    var fallbackLabel: String {
        switch self {
        case .op(let id): return "WP #\(id)"
        case .remote(let id): return "Task \(id.prefix(8))…"
        case .local: return "Local task"
        }
    }
}

/// What a stretch of time can be attributed to.
public enum Target: Hashable, Codable, Sendable {
    case task(TaskRef)
    case doNotTrack
}

public extension Target {
    /// Whether assigning to this target should teach the attributor.
    ///
    /// - Sweeping to the built-in Unknown task (Unknown task category,
    ///   2026-07-09) is an explicit "don't know", not a correction — it must
    ///   never teach (that would let an admission of uncertainty masquerade
    ///   as learned evidence).
    /// - Clearing (`.doNotTrack` — the review drawer's Clear button/⌫) never
    ///   teaches either (Martin, 2026-07-10): "drop from this list and don't
    ///   add to timesheets … may be selected because the user can't be
    ///   bothered assigning 1m tracks — which the app should not 'learn'
    ///   from". No sticky, no learned lean toward stopping the clock.
    ///   Existing learned don't-track associations stay in the store
    ///   untouched; clears just stop creating new ones. The timeline's own
    ///   "Don't track this" is a different, deliberate teach-this-surface-
    ///   is-non-work action and doesn't route through this flag.
    /// - A real task teaches normally.
    var teachesAttributor: Bool {
        switch self {
        case .doNotTrack: return false
        case .task(let ref): return ref != WorkTask.unknown.ref
        }
    }
}

public struct WorkTask: Equatable, Codable, Sendable, Identifiable {
    /// Stable identity: the backend ref (what pick lists already key by).
    public var id: TaskRef { ref }
    public var ref: TaskRef
    public var subject: String
    /// Display TITLE of the containing project (what lists/pies group by).
    public var project: String?
    /// STABLE backend id of the containing project ("14" for an OP project),
    /// captured from the project link so billable flags can key on identity
    /// rather than the rename-fragile title. nil for local tasks and for
    /// caches written before the capture existed (title-keyed fallback +
    /// one-time migration cover those — see BillableRules).
    public var projectID: String?
    public var status: String
    public var lastConfirmedAt: Date?
    public var assignee: String?

    public var isLocalOnly: Bool {
        if case .local = ref { return true }
        return false
    }

    public init(ref: TaskRef, subject: String, project: String? = nil,
                projectID: String? = nil, status: String,
                lastConfirmedAt: Date? = nil, assignee: String? = nil) {
        self.ref = ref
        self.subject = subject
        self.project = project
        self.projectID = projectID
        self.status = status
        self.lastConfirmedAt = lastConfirmedAt
        self.assignee = assignee
    }
}

public extension WorkTask {
    /// Reserved sentinel identity for the built-in "Unknown" task (Unknown
    /// task category, 2026-07-09): review-queue time the user can't place is
    /// swept here — tracked, safe, off the queue, reclaimable — instead of
    /// sitting in the drawer forever. A fixed `.local` task, NOT a new
    /// `TaskRef` case (that would ripple through Codable/sync); mirrors
    /// `AppController.liveCheckpointID`'s sentinel-UUID pattern. Local tasks
    /// never push to a backend, which is exactly right for Unknown. Kept out
    /// of `taskCache`'s normal seeding (never returned by `localWorkTasks()`)
    /// so it can never leak into the pick list or the attributor's candidate
    /// pool — it is reachable only by direct ref comparison (`name(of:)`,
    /// `colour(for:)`, the review drawer's dedicated action).
    static let unknownID = UUID(uuidString: "00000000-0000-0000-0000-000000FACADE")!
    static let unknown = WorkTask(ref: .local(unknownID), subject: "Unknown", status: "Unknown")
}

/// One observation from the sensors: what is focused right now.
public struct ActivitySignal: Equatable, Codable, Sendable {
    public var app: String
    public var windowTitle: String?
    public var tabURL: String?
    public var timestamp: Date
    /// Email correspondents (sender + recipients minus self) when the surface is a
    /// detected email message — the Mac capture fills these via the page recipe.
    /// Optional so old journalled signals (which lack the keys) still decode.
    public var correspondents: [String]?
    /// The email subject, when known.
    public var emailSubject: String?

    public init(app: String, windowTitle: String? = nil, tabURL: String? = nil,
                timestamp: Date, correspondents: [String]? = nil,
                emailSubject: String? = nil) {
        self.app = app
        self.windowTitle = windowTitle
        self.tabURL = tabURL
        self.timestamp = timestamp
        self.correspondents = correspondents
        self.emailSubject = emailSubject
    }

    /// Fold a second capture's email evidence into this signal — the ONE
    /// merge rule for evidence accumulating over time (a review row extended
    /// across a same-surface return visit, repeated rows of one surface in a
    /// multi-select teach). Correspondents union: first-seen order, case-
    /// insensitively de-duplicated (mirrors `correspondentChoices`), because
    /// the downstream checkbox fan-out lets the user PRUNE addresses but
    /// nothing can restore one a merge silently dropped. Subject: first
    /// non-empty wins — a same-surface extension is the same message, and the
    /// subject grain wants one stable value — but a slice captured before the
    /// async page recipe delivered adopts the first subject that appears.
    public mutating func mergeEmailEvidence(correspondents incoming: [String]?,
                                            subject: String?) {
        if let incoming, !incoming.isEmpty {
            var merged = correspondents ?? []
            var seen = Set(merged.map { $0.lowercased() })
            for address in incoming where seen.insert(address.lowercased()).inserted {
                merged.append(address)
            }
            correspondents = merged
        }
        if emailSubject?.isEmpty != false, let subject, !subject.isEmpty {
            emailSubject = subject
        }
    }
}

/// Everything the platform sensor layer can tell Core. Sensors emit these;
/// Core tests emit them from scripts.
package enum SensorEvent: Equatable, Sendable {
    case focus(ActivitySignal)
    /// A late-arriving correspondents/subject capture for the CURRENT open
    /// span (2026-07-03 diagnosis fix: capture must never block `poll()`, so
    /// it always races the user's next focus change). The tracker applies it
    /// retroactively to the open span if the surface is still the one it was
    /// captured for, and drops it silently otherwise.
    case focusEnrichment(ActivitySignal)
    case input(Date)                     // keyboard/mouse seen at this time
    case willSleep(Date)
    case didWake(Date)
    case microphone(active: Bool, at: Date)
    case screenLocked(Date)
    case screenUnlocked(Date)
}

/// One app's window placement, captured for a task's "workspace" layout so it
/// can be relaunched and re-arranged on demand. Platform-agnostic (Core) so it
/// persists in settings; the macOS layer does the actual capture/restore.
package struct WindowFrame: Codable, Equatable, Sendable {
    package var bundleID: String
    package var x: Double
    package var y: Double
    package var w: Double
    package var h: Double
    /// Best-effort window title at capture time, used to match a specific window
    /// back to its frame on restore when an app has several. Often empty (the
    /// title needs the screen-recording grant to read), so restore also falls
    /// back to capture order. Optional for back-compat with layouts saved before
    /// this field existed.
    package var title: String

    package init(bundleID: String, x: Double, y: Double, w: Double, h: Double,
                title: String = "") {
        self.bundleID = bundleID
        self.x = x; self.y = y; self.w = w; self.h = h
        self.title = title
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        w = try c.decode(Double.self, forKey: .w)
        h = try c.decode(Double.self, forKey: .h)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
    }
}

/// The stable identity of a window/tab for priming and learning:
/// URL host+path when there is a URL, else the window title.
package struct Surface: Hashable, Codable, Sendable {
    package var app: String
    package var detail: String

    package init(app: String, detail: String) {
        self.app = app
        self.detail = detail
    }

    package init(signal: ActivitySignal) {
        self.app = signal.app
        if let raw = signal.tabURL, let url = URL(string: raw), let host = url.host {
            var path = url.path
            while path.hasSuffix("/") { path = String(path.dropLast()) }   // platform-stable
            var detail = host + path
            // Webmail routes the MESSAGE identity through the URL fragment
            // (mail.google.com/mail/u/0/#inbox/<threadid>), which host+path
            // drops — collapsing ALL of Gmail to one surface, so one
            // correction re-pointed every Gmail tab (2026-07-03 diagnosis,
            // RC2). Lift the fragment into the identity ONLY on known-mail
            // hosts: ordinary sites keep their exact pre-existing surface
            // (and their persisted primed.json keys keep matching).
            if EmailSystem.detect(urlHost: host) != .unknown,
               let fragment = url.fragment, !fragment.isEmpty {
                detail += "#" + fragment
            }
            self.detail = detail
        } else {
            self.detail = signal.windowTitle ?? ""
        }
    }
}

/// A contiguous stretch of focus on one surface, attributed to one target.
/// Codable: spans persist to the journal so the timeline's zoom strip can
/// show window-level detail.
public struct FocusSpan: Equatable, Codable, Sendable {
    public var target: Target
    public var certainty: Double
    public var signal: ActivitySignal
    public var start: Date
    public var end: Date
    /// What decided this span's target (nil on spans stored before
    /// 2026-07-10) — flush folds spans' provenance into the session's.
    public var provenance: SessionProvenance?
    /// Evidence only — true for a span captured WHILE `SessionTracker.away`
    /// was pinned (target `.doNotTrack`, certainty 0): the focus/window
    /// change record from an away stretch that no real session ever owns.
    /// Away-observed spans must NEVER bill, teach, refile or aggregate —
    /// `dominant(...)` filters them out first, and their `.doNotTrack`
    /// target already keeps them out of billing/teaching/aggregation on its
    /// own. Exists so a long away stretch is reconstructable afterwards
    /// (2026-08-07 incident: ~24h away left no record at all). Additive and
    /// leniently decoded — defaults false, so every span journalled before
    /// this field existed decodes as ordinary (non-away) evidence.
    public var observedWhileAway: Bool

    public init(target: Target, certainty: Double, signal: ActivitySignal,
                start: Date, end: Date, provenance: SessionProvenance? = nil,
                observedWhileAway: Bool = false) {
        self.target = target
        self.certainty = certainty
        self.signal = signal
        self.start = start
        self.provenance = provenance
        self.end = end
        self.observedWhileAway = observedWhileAway
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(Target.self, forKey: .target)
        certainty = try c.decode(Double.self, forKey: .certainty)
        signal = try c.decode(ActivitySignal.self, forKey: .signal)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        provenance = try c.decodeIfPresent(SessionProvenance.self, forKey: .provenance)
        // Absent on spans journalled before this field existed — same
        // lenient shape as WindowFrame.title above.
        observedWhileAway = try c.decodeIfPresent(Bool.self, forKey: .observedWhileAway) ?? false
    }
}

extension FocusSpan {
    /// The dominant (longest) focus span overlapping a `[from, to)` window —
    /// the surface that held it longest. Overlap is `span.end > from &&
    /// span.start < to`; the winner is the largest *full-span* duration
    /// (not the clipped overlap), matching the historical rule. Ties resolve
    /// toward the earliest start: callers pass spans ordered by start, and
    /// `max(by:)` keeps the first of several equal maxima.
    ///
    /// The selection lives here, once, so both the per-session fetch and the
    /// batch contradiction pass (which fetches the whole scan horizon in one
    /// query and reuses this against each session's window) pick identically.
    public static func dominant(among spans: [FocusSpan], from: Date, to: Date) -> FocusSpan? {
        spans.lazy
            // Evidence rows never win a session's identity — this is the one
            // choke point that defends both teaching and contradiction
            // refile against away-observed noise.
            .filter { !$0.observedWhileAway }
            .filter { $0.end > from && $0.start < to }
            .max { $0.end.timeIntervalSince($0.start) < $1.end.timeIntervalSince($1.start) }
    }
}

/// A closed, journalled stretch of tracked time on one task.
/// WHO or what decided a slice's task — recorded at flush (2026-07-10,
/// why-panel follow-up) so the Evidence Card can tell the original story
/// verbatim instead of demoting today's re-derivation to "would say".
public struct SessionProvenance: Equatable, Hashable, Codable, Sendable {
    /// An `AttributionExplanation.Source` rawValue ("pin", "emailRule", …)
    /// or a tracker/controller verb ("userAssigned", "aiApplied", "resumed",
    /// "retro"). Kept as the raw string so a future case rename can never
    /// wipe or mis-read old journals — consumers map leniently and show
    /// unknown values as a plain "decided earlier".
    public var sourceRaw: String
    /// The matched rule/key when one existed ("✉ client@…", the remembered
    /// surface, the live-adjacency reasoning) — display verbatim.
    public var detail: String?

    public init(sourceRaw: String, detail: String? = nil) {
        self.sourceRaw = sourceRaw
        self.detail = detail
    }

    public init(source: AttributionExplanation.Source, detail: String? = nil) {
        self.init(sourceRaw: source.rawValue, detail: detail)
    }

    /// The typed source when the raw string still maps to one.
    public var source: AttributionExplanation.Source? {
        AttributionExplanation.Source(rawValue: sourceRaw)
    }

    /// The user picked/corrected this themselves (popover, drawer, timeline).
    public static let userAssigned = SessionProvenance(sourceRaw: "userAssigned")
    /// An AI Assist response the user applied.
    public static let aiApplied = SessionProvenance(sourceRaw: "aiApplied")
    /// Auto-resumed onto the pre-idle task after an idle stop.
    public static let resumed = SessionProvenance(sourceRaw: "resumed")
    /// The retro-acceptance pass lifted it once confidence reached the bar.
    public static let retro = SessionProvenance(sourceRaw: "retro")
}

public struct Session: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var task: TaskRef
    public var start: Date
    public var end: Date
    public var certainty: Double
    public var pushedToOP: Bool
    public var comment: String?
    /// The backend time entry this session became, so timeline edits can
    /// PATCH (or delete) the remote entry. WIDENED 2026-07-02 from Int to
    /// String (OP ids are ints, Xero's are GUIDs); the JSON key keeps its
    /// historic name and legacy Int rows decode via the custom init below.
    public var opTimeEntryID: RemoteEntryID?
    /// What decided `task` (see SessionProvenance) — nil on rows journalled
    /// before 2026-07-10. Reassignments overwrite it: provenance describes
    /// the decision that STANDS; the displaced story is the Evidence Card's
    /// history line, not the journal's.
    public var provenance: SessionProvenance?
    /// Per-entry billable mark, set from the Timeline (nil on rows journalled
    /// before 2026-07-11 and on unmarked entries = inherit the task/project
    /// resolution). An explicit mark beats the task and project flags in BOTH
    /// directions — see `BillableRules.effectiveBillable`.
    public var billableOverride: Bool?

    public init(id: UUID = UUID(), task: TaskRef, start: Date, end: Date,
                certainty: Double, pushedToOP: Bool = false, comment: String? = nil,
                opTimeEntryID: RemoteEntryID? = nil,
                provenance: SessionProvenance? = nil,
                billableOverride: Bool? = nil) {
        self.id = id
        self.task = task
        self.start = start
        self.end = end
        self.certainty = certainty
        self.pushedToOP = pushedToOP
        self.comment = comment
        self.opTimeEntryID = opTimeEntryID
        self.provenance = provenance
        self.billableOverride = billableOverride
    }

    /// Custom decode ONLY for the widened entry id: journalled rows written
    /// before 2026-07-02 hold an Int. Everything else is standard; encoding
    /// stays synthesized (always writes the String form).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        task = try c.decode(TaskRef.self, forKey: .task)
        start = try c.decode(Date.self, forKey: .start)
        end = try c.decode(Date.self, forKey: .end)
        certainty = try c.decode(Double.self, forKey: .certainty)
        pushedToOP = try c.decode(Bool.self, forKey: .pushedToOP)
        comment = try c.decodeIfPresent(String.self, forKey: .comment)
        if let s = try? c.decodeIfPresent(String.self, forKey: .opTimeEntryID) {
            opTimeEntryID = s
        } else {
            opTimeEntryID = ((try? c.decodeIfPresent(Int.self, forKey: .opTimeEntryID)) ?? nil)
                .map(String.init)
        }
        // Absent on pre-2026-07-10 rows; a malformed value must not sink the
        // whole session either (provenance is annotation, never identity).
        provenance = (try? c.decodeIfPresent(SessionProvenance.self, forKey: .provenance)) ?? nil
        // Absent on pre-2026-07-11 rows (= inherit); same leniency as above.
        billableOverride = (try? c.decodeIfPresent(Bool.self, forKey: .billableOverride)) ?? nil
    }
}

/// One coalesced row in the review queue (low-certainty time awaiting assignment).
public struct ReviewSegment: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var app: String
    public var windowTitle: String?
    public var tabURL: String?
    /// Email evidence the originating signal carried at queue time (see
    /// `ActivitySignal.correspondents`/`emailSubject`), so the drawer's
    /// post-assign grain footer can offer correspondent/domain/subject rules
    /// instead of falling back to the whole mail system. Optional so rows
    /// journalled before these keys existed still decode (nil — synthesized
    /// Codable decodes optionals with `decodeIfPresent`, the same leniency
    /// `ActivitySignal` itself relies on).
    public var correspondents: [String]?
    public var emailSubject: String?
    public var start: Date
    public var end: Date
    public var assigned: Target?

    public init(id: UUID = UUID(), app: String, windowTitle: String? = nil,
                tabURL: String? = nil, correspondents: [String]? = nil,
                emailSubject: String? = nil, start: Date, end: Date,
                assigned: Target? = nil) {
        self.id = id
        self.app = app
        self.windowTitle = windowTitle
        self.tabURL = tabURL
        self.correspondents = correspondents
        self.emailSubject = emailSubject
        self.start = start
        self.end = end
        self.assigned = assigned
    }

    /// The synthetic `ActivitySignal` a review row reconstructs — what the
    /// assign path teaches the attributor from and the grain footer builds
    /// its `ContextIdentity` from. ONE construction point, so no consumer can
    /// silently drop the stored email evidence and regress the footer to
    /// system-level offers.
    public var signal: ActivitySignal {
        ActivitySignal(app: app, windowTitle: windowTitle, tabURL: tabURL,
                       timestamp: start, correspondents: correspondents,
                       emailSubject: emailSubject)
    }

    /// Fold a same-surface extension's evidence into this row —
    /// `ActivitySignal.mergeEmailEvidence`'s rule (correspondent union,
    /// first non-empty subject), applied to the stored fields.
    public mutating func mergeEmailEvidence(from signal: ActivitySignal) {
        var merged = self.signal
        merged.mergeEmailEvidence(correspondents: signal.correspondents,
                                  subject: signal.emailSubject)
        correspondents = merged.correspondents
        emailSubject = merged.emailSubject
    }
}

package extension Array where Element == ReviewSegment {
    /// One synthetic signal per DISTINCT surface among the segments whose ids
    /// are in `ids`, in queue order — what a multi-select review assign
    /// teaches the attributor from. Every covered surface teaches (the old
    /// glue taught only the FIRST selected row — approvals-drawer spec §1
    /// side-bug — so a 40-row assign threw away 39 rows of evidence), while
    /// rows repeating one surface (same app|title|URL) teach once. A repeat's
    /// EMAIL evidence still counts, though: a later slice may have captured
    /// correspondents the first missed (the capture races focus changes), so
    /// each surface's signal carries the union of its rows' evidence — the
    /// same merge rule `SessionTracker.queueReview` applies at queue time.
    func teachingSignals(for ids: Set<UUID>) -> [ActivitySignal] {
        var indexOf: [String: Int] = [:]
        var out: [ActivitySignal] = []
        for s in self where ids.contains(s.id) {
            let key = "\(s.app)|\(s.windowTitle ?? "")|\(s.tabURL ?? "")"
            if let i = indexOf[key] {
                out[i].mergeEmailEvidence(correspondents: s.correspondents,
                                          subject: s.emailSubject)
            } else {
                indexOf[key] = out.count
                out.append(s.signal)
            }
        }
        return out
    }
}
