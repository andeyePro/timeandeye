import Foundation

/// D6 — finance task mapping: the CONNECTOR owns translation, this store
/// owns the table. The `SyncEngine`/`TaskBackend` seam stays id-agnostic
/// (it is the cross-repo lockstep surface — frozen); a finance connector
/// receives this store at registration and translates the source task id
/// it is handed into ITS OWN task internally. An unmapped task throws
/// `PermanentPostError` with `noMappingReason` → the row closes `.skipped`
/// with a visible "map me" prompt and the queue proceeds (D5) — never a
/// stalled queue, never a `.failed` retry storm.
public struct FinanceMapping: Codable, Equatable, Sendable {
    /// The finance backend's task all of the source project's time bills to
    /// (Xero requires a task on every entry; per-task fidelity is not a
    /// finance concept — the invoice line is project-level). The task id
    /// alone identifies the target: the CONNECTOR resolves the task's
    /// project from its own cache, which keeps this type — and the Settings
    /// editor that writes it — buildable from the seam's fetchTasks()
    /// without leaking backend project ids through the frozen seam.
    public var backendTaskID: String

    public init(backendTaskID: String) {
        self.backendTaskID = backendTaskID
    }
}

/// Core-owned, Settings-edited, connector-consumed. Keyed by the same
/// source PROJECT KEYS billing rules use (`BillableRules` project keys), so
/// the flag that makes time billable and the mapping that routes it name
/// the project identically.
///
/// Thread-shape: the CONNECTOR reads (`mapping(forSourceTask:)`,
/// `projectKey(forSourceTask:)`) from the sync engine's async context while
/// Settings writes on the main thread — every access takes the lock, and
/// the source-task→project-key RESOLUTION is a snapshot TABLE the owner
/// refreshes when its task cache changes, not a live closure back into
/// main-actor state.
public final class FinanceMappingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var mappingsStorage: [String: FinanceMapping]
    private var projectKeysStorage: [String: String]
    /// Fires on every `set` with the project key that changed — the ONLY
    /// sane trigger for re-opening `.skipped` no-mapping rows (criterion
    /// 10): a generic reason-code re-test has no change signal to key on.
    /// Called on whichever thread `set` runs on (Settings: main).
    public var onChange: (String) -> Void = { _ in }

    public init(mappings: [String: FinanceMapping] = [:],
                projectKeys: [String: String] = [:]) {
        self.mappingsStorage = mappings
        self.projectKeysStorage = projectKeys
    }

    /// sourceProjectKey → mapping, as currently stored.
    public var mappings: [String: FinanceMapping] {
        lock.lock(); defer { lock.unlock() }
        return mappingsStorage
    }

    /// Refresh the source-task→project-key snapshot (the owner knows
    /// task→project via its task cache; this store and the connector
    /// deliberately do not).
    public func setProjectKeys(_ table: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        projectKeysStorage = table
    }

    public func set(_ mapping: FinanceMapping?, forProjectKey key: String) {
        lock.lock()
        if let mapping { mappingsStorage[key] = mapping } else { mappingsStorage[key] = nil }
        lock.unlock()
        onChange(key)
    }

    /// The source project key for a SOURCE task id, or nil (unknown task).
    public func projectKey(forSourceTask taskID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return projectKeysStorage[taskID]
    }

    /// The connector's one call: the mapping for a SOURCE task id, or nil
    /// (unmapped project, or a task the snapshot doesn't know).
    public func mapping(forSourceTask taskID: String) -> FinanceMapping? {
        lock.lock(); defer { lock.unlock() }
        guard let key = projectKeysStorage[taskID] else { return nil }
        return mappingsStorage[key]
    }

    /// The exact `.skipped` reason for an unmapped project. STABLE FORMAT:
    /// the criterion-10 reopen matches rows on this string, so the reason
    /// doubles as the machine-readable marker — change it and skipped rows
    /// written by older builds stop re-opening.
    public static func noMappingReason(projectKey: String) -> String {
        "no finance mapping for \(projectKey) — map the project in Settings to bill its time"
    }
}
