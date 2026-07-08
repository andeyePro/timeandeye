import Foundation

/// D6 — finance task mapping: the CONNECTOR owns translation, this store
/// owns the table. The `SyncEngine`/`TaskBackend` seam stays id-agnostic
/// (it is the cross-repo lockstep surface — frozen); a finance connector
/// receives this store at registration and translates the source task id
/// it is handed into ITS project + task internally. An unmapped task throws
/// `PermanentPostError` with `noMappingReason` → the row closes `.skipped`
/// with a visible "map me" prompt and the queue proceeds (D5) — never a
/// stalled queue, never a `.failed` retry storm.
public struct FinanceMapping: Codable, Equatable, Sendable {
    /// The finance backend's project id (Xero: the project GUID).
    public var backendProjectID: String
    /// The task inside that project all of the source project's time bills
    /// to (Xero requires a task on every entry; per-task fidelity is not a
    /// finance concept — the invoice line is project-level).
    public var backendTaskID: String

    public init(backendProjectID: String, backendTaskID: String) {
        self.backendProjectID = backendProjectID
        self.backendTaskID = backendTaskID
    }
}

/// Core-owned, Settings-edited, connector-consumed. Keyed by the same
/// source PROJECT KEYS billing rules use (`BillableRules` project keys), so
/// the flag that makes time billable and the mapping that routes it name
/// the project identically.
public final class FinanceMappingStore {
    /// sourceProjectKey → mapping. Assign wholesale (Settings load) or via
    /// `set` (fires the change handler — the criterion-10 reopen trigger).
    public private(set) var mappings: [String: FinanceMapping]
    /// Source task id → source project key, injected by the owner (the
    /// controller knows task→project via its task cache; this store and the
    /// connector deliberately do not).
    public var projectKey: (String) -> String?
    /// Fires on every `set` with the project key that changed — the ONLY
    /// sane trigger for re-opening `.skipped` no-mapping rows (criterion
    /// 10): a generic reason-code re-test has no change signal to key on.
    public var onChange: (String) -> Void = { _ in }

    public init(mappings: [String: FinanceMapping] = [:],
                projectKey: @escaping (String) -> String? = { _ in nil }) {
        self.mappings = mappings
        self.projectKey = projectKey
    }

    public func set(_ mapping: FinanceMapping?, forProjectKey key: String) {
        if let mapping { mappings[key] = mapping } else { mappings[key] = nil }
        onChange(key)
    }

    /// The connector's one call: the mapping for a SOURCE task id, or nil
    /// (unmapped project, or a task the resolver doesn't know).
    public func mapping(forSourceTask taskID: String) -> FinanceMapping? {
        guard let key = projectKey(taskID) else { return nil }
        return mappings[key]
    }

    /// The exact `.skipped` reason for an unmapped project. STABLE FORMAT:
    /// the criterion-10 reopen matches rows on this string, so the reason
    /// doubles as the machine-readable marker — change it and skipped rows
    /// written by older builds stop re-opening.
    public static func noMappingReason(projectKey: String) -> String {
        "no finance mapping for \(projectKey) — map the project in Settings to bill its time"
    }
}
