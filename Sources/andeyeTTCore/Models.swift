import Foundation

public enum Andeye {
    public static let version = "0.1.0"
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
    /// Sweeping to the built-in Unknown task (Unknown task category,
    /// 2026-07-09) is an explicit "don't know", not a correction — it must
    /// never teach the attributor (that would let an admission of
    /// uncertainty masquerade as learned evidence). Every other target — a
    /// real task or `.doNotTrack` — teaches normally.
    var teachesAttributor: Bool {
        self != .task(WorkTask.unknown.ref)
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
}

/// Everything the platform sensor layer can tell Core. Sensors emit these;
/// Core tests emit them from scripts.
public enum SensorEvent: Equatable, Sendable {
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
public struct WindowFrame: Codable, Equatable, Sendable {
    public var bundleID: String
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    /// Best-effort window title at capture time, used to match a specific window
    /// back to its frame on restore when an app has several. Often empty (the
    /// title needs the screen-recording grant to read), so restore also falls
    /// back to capture order. Optional for back-compat with layouts saved before
    /// this field existed.
    public var title: String

    public init(bundleID: String, x: Double, y: Double, w: Double, h: Double,
                title: String = "") {
        self.bundleID = bundleID
        self.x = x; self.y = y; self.w = w; self.h = h
        self.title = title
    }

    public init(from decoder: Decoder) throws {
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
public struct Surface: Hashable, Codable, Sendable {
    public var app: String
    public var detail: String

    public init(app: String, detail: String) {
        self.app = app
        self.detail = detail
    }

    public init(signal: ActivitySignal) {
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

    public init(target: Target, certainty: Double, signal: ActivitySignal,
                start: Date, end: Date) {
        self.target = target
        self.certainty = certainty
        self.signal = signal
        self.start = start
        self.end = end
    }
}

/// A closed, journalled stretch of tracked time on one task.
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

    public init(id: UUID = UUID(), task: TaskRef, start: Date, end: Date,
                certainty: Double, pushedToOP: Bool = false, comment: String? = nil,
                opTimeEntryID: RemoteEntryID? = nil) {
        self.id = id
        self.task = task
        self.start = start
        self.end = end
        self.certainty = certainty
        self.pushedToOP = pushedToOP
        self.comment = comment
        self.opTimeEntryID = opTimeEntryID
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
    }
}

/// One coalesced row in the review queue (low-certainty time awaiting assignment).
public struct ReviewSegment: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var app: String
    public var windowTitle: String?
    public var tabURL: String?
    public var start: Date
    public var end: Date
    public var assigned: Target?

    public init(id: UUID = UUID(), app: String, windowTitle: String? = nil,
                tabURL: String? = nil, start: Date, end: Date, assigned: Target? = nil) {
        self.id = id
        self.app = app
        self.windowTitle = windowTitle
        self.tabURL = tabURL
        self.start = start
        self.end = end
        self.assigned = assigned
    }
}

public extension Array where Element == ReviewSegment {
    /// One synthetic signal per DISTINCT surface among the segments whose ids
    /// are in `ids`, in queue order — what a multi-select review assign
    /// teaches the attributor from. Every covered surface teaches (the old
    /// glue taught only the FIRST selected row — approvals-drawer spec §1
    /// side-bug — so a 40-row assign threw away 39 rows of evidence), while
    /// rows repeating one surface (same app|title|URL) teach once.
    func teachingSignals(for ids: Set<UUID>) -> [ActivitySignal] {
        var seen = Set<String>()
        var out: [ActivitySignal] = []
        for s in self where ids.contains(s.id) {
            let key = "\(s.app)|\(s.windowTitle ?? "")|\(s.tabURL ?? "")"
            guard seen.insert(key).inserted else { continue }
            out.append(ActivitySignal(app: s.app, windowTitle: s.windowTitle,
                                      tabURL: s.tabURL, timestamp: s.start))
        }
        return out
    }
}
