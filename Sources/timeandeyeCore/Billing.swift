import Foundation

/// Task-level billable override. `inherit` (the default) defers to the
/// project flag; the other two pin the task regardless of its project.
public enum BillableState: String, Codable, Sendable, CaseIterable {
    case inherit, billable, nonBillable
}

/// The user's billable flags: a project-level Bool plus per-task tri-state
/// overrides. Persisted as its own user-ownable JSON file (`billing.json`
/// beside settings), like the other correction/rule stores.
///
/// DEFAULT NON-BILLABLE: an unflagged project can never be invoiced — the
/// failure mode of the opposite default is invoicing a client for internal
/// time, so absence always resolves to non-billable.
///
/// Keys are STABLE, backend-scoped project identifiers (`projectKey`),
/// never bare titles, so renaming a project in the backend keeps its flag.
/// Task overrides key by `TaskRef.storageKey`. Each flag carries `since` —
/// the moment it last became what it is — because flips are PROSPECTIVE
/// ONLY: a finance backend receives sessions started after the deciding
/// flag turned billable, never earlier history (see `financeEligible`).
public struct BillableRules: Codable, Equatable, Sendable {
    public struct ProjectFlag: Codable, Equatable, Sendable {
        public var billable: Bool
        public var since: Date
        public init(billable: Bool, since: Date) {
            self.billable = billable
            self.since = since
        }
    }

    public struct TaskFlag: Codable, Equatable, Sendable {
        /// Only `.billable` / `.nonBillable` are stored; setting `.inherit`
        /// removes the entry (absence == inherit).
        public var state: BillableState
        public var since: Date
        public init(state: BillableState, since: Date) {
            self.state = state
            self.since = since
        }
    }

    /// Stable project key → flag. See the key builders below.
    public var projects: [String: ProjectFlag]
    /// `TaskRef.storageKey` → override.
    public var tasks: [String: TaskFlag]

    public init(projects: [String: ProjectFlag] = [:], tasks: [String: TaskFlag] = [:]) {
        self.projects = projects
        self.tasks = tasks
    }

    // MARK: - Stable project keys

    /// Backend-scoped, id-based key — the durable form ("op/id:14" style).
    public static func projectKey(backendID: String, projectID: String) -> String {
        "\(backendID)/id:\(projectID)"
    }

    /// Title-keyed FALLBACK for tasks whose backend project id has not been
    /// captured yet (a cache written before the id capture existed). Migrated
    /// to the id form as soon as the id is known — see `migrateProjectKeys`.
    public static func titleProjectKey(backendID: String, title: String) -> String {
        "\(backendID)/title:\(title)"
    }

    /// Local (personal) projects have no backend; they key by name. They can
    /// carry a flag for display symmetry, but `.local` tasks never reach ANY
    /// backend regardless of it — personal always wins.
    public static func localProjectKey(_ name: String) -> String {
        "local/name:\(name)"
    }

    // MARK: - Resolution

    public func projectBillable(_ key: String?) -> Bool {
        guard let key else { return false }
        return projects[key]?.billable ?? false
    }

    public func taskState(_ ref: TaskRef) -> BillableState {
        tasks[ref.storageKey]?.state ?? .inherit
    }

    /// Effective resolution: an explicit ENTRY mark (the Timeline's per-slice
    /// override, `Session.billableOverride`) beats everything in BOTH
    /// directions; else task override if manually set, else the project flag,
    /// else DEFAULT NON-BILLABLE. Absence (nil) inherits.
    public func effectiveBillable(entryOverride: Bool? = nil,
                                  task ref: TaskRef, projectKey: String?) -> Bool {
        if let entryOverride { return entryOverride }
        switch taskState(ref) {
        case .billable: return true
        case .nonBillable: return false
        case .inherit: return projectBillable(projectKey)
        }
    }

    /// Finance-class eligibility for a session, evaluated at POST time:
    /// effectively billable AND the session started at/after the DECIDING
    /// flag last turned billable. The `since` gate is what makes flips
    /// prospective-only — flipping a project billable never floods a finance
    /// backend with earlier history (that stranded time is warned about at
    /// flip time; the catch-up invoice is a future feature).
    public func financeEligible(entryOverride: Bool? = nil,
                                task ref: TaskRef, projectKey: String?,
                                sessionStart: Date) -> Bool {
        // Personal tasks never leave the Mac, whatever any flag says.
        guard ref.isRemote else { return false }
        // An explicit entry mark carries NO `since` gate: the user pointed at
        // THIS entry, which is exactly the consent the prospective-only gate
        // exists to collect for flag flips. Both directions are final for
        // this entry — billable posts, non-billable never does.
        if let entryOverride { return entryOverride }
        switch taskState(ref) {
        case .nonBillable:
            return false
        case .billable:
            guard let flag = tasks[ref.storageKey] else { return false }
            return sessionStart >= flag.since
        case .inherit:
            guard let key = projectKey, let flag = projects[key], flag.billable else {
                return false
            }
            return sessionStart >= flag.since
        }
    }

    // MARK: - Mutation

    /// Flip a project's flag. `since` only advances when the VALUE changes, so
    /// re-saving the same state never re-gates history.
    public mutating func setProject(_ key: String, billable: Bool, at date: Date = Date()) {
        if let existing = projects[key], existing.billable == billable { return }
        projects[key] = ProjectFlag(billable: billable, since: date)
    }

    /// Set a task override; `.inherit` clears it (absence == inherit).
    public mutating func setTask(_ ref: TaskRef, state: BillableState, at date: Date = Date()) {
        if state == .inherit {
            tasks[ref.storageKey] = nil
            return
        }
        if let existing = tasks[ref.storageKey], existing.state == state { return }
        tasks[ref.storageKey] = TaskFlag(state: state, since: date)
    }

    /// The tasks a project toggle leaves untouched — those with a manual
    /// override. Toggling a project cascades to INHERITING tasks only (which
    /// needs no per-task writes: inheritance is resolved at read time); these
    /// are surfaced in the same gesture ("N tasks kept their manual setting").
    public func manuallySetTasks(in projectTasks: [WorkTask]) -> [WorkTask] {
        projectTasks.filter { taskState($0.ref) != .inherit }
    }

    /// One-time title-key → id-key migration: `mapping` pairs each known
    /// title-based key with its id-based key. Flags move preserving their
    /// value and `since`; an already-populated id key wins (never clobbered).
    /// Idempotent — migrated keys simply stop appearing in `projects`.
    /// Returns how many flags moved.
    @discardableResult
    public mutating func migrateProjectKeys(_ mapping: [String: String]) -> Int {
        var moved = 0
        for (titleKey, idKey) in mapping {
            guard let flag = projects[titleKey] else { continue }
            if projects[idKey] == nil { projects[idKey] = flag; moved += 1 }
            projects[titleKey] = nil
        }
        return moved
    }
}

/// Pure billing arithmetic shared by the controller and the checks.
public enum Billing {
    /// Seconds of confirmed time in `sessions` (on `tasks`) that no finance
    /// backend holds — the "stranded uninvoiced time" a billability flip
    /// warns about. Counts sessions that WOULD reach a finance backend on
    /// merit (remote task, certainty at/above the auto-push threshold, at
    /// least a minute long) minus those already posted (`postedSessionIDs`,
    /// the ids with a `.posted` finance ledger row — posted history is never
    /// clawed back, so it is not stranded). Entry-marked sessions
    /// (`billableOverride` set either way) are excluded: their posting is
    /// decided by their own mark, so a task/project flip neither strands
    /// nor releases them.
    public static func strandedSeconds(sessions: [Session], tasks: Set<TaskRef>,
                                       threshold: Double,
                                       postedSessionIDs: Set<UUID>) -> TimeInterval {
        sessions.reduce(0) { total, s in
            guard tasks.contains(s.task), s.task.isRemote,
                  s.billableOverride == nil,
                  s.certainty >= threshold,
                  !postedSessionIDs.contains(s.id) else { return total }
            let duration = s.end.timeIntervalSince(s.start)
            guard duration >= 60 else { return total }
            return total + duration
        }
    }
}

/// What a billability flip did — the data surface behind the UI alert.
public struct BillableFlipReport: Identifiable, Sendable {
    public let id = UUID()
    /// The project (or task) name the alert headlines.
    public let name: String
    /// The state just applied.
    public let billable: Bool
    /// Manually-set tasks the cascade left exactly as they were.
    public let leftBehind: [WorkTask]
    /// Confirmed, uninvoiced seconds this flip strands (0 = nothing to warn).
    public let strandedSeconds: TimeInterval

    public init(name: String, billable: Bool, leftBehind: [WorkTask],
                strandedSeconds: TimeInterval) {
        self.name = name
        self.billable = billable
        self.leftBehind = leftBehind
        self.strandedSeconds = strandedSeconds
    }
}

/// Currency symbol default: the user's locale, overridable by ONE Settings
/// field (`AndeyeSettings.currencySymbolOverride`) — no settings sprawl.
public enum CurrencyDefault {
    /// The locale's currency symbol ("£" for en_GB); "¤" (the generic
    /// currency sign) when the locale defines none.
    public static func symbol(for locale: Locale = .current) -> String {
        locale.currencySymbol ?? "¤"
    }
}
