import Foundation

/// Pushes journalled sessions to every registered backend once they clear the
/// user's certainty threshold, one ledger row per (session, backend). The
/// journal stays the source of truth; a failed post leaves its ledger row
/// `.failed` and retries next pass. Backend-agnostic: connector quirks (OP's
/// startTime 422 fallback etc.) live in the conformers, and in standalone
/// mode no SyncEngine exists at all (see TaskBackend).
///
/// Routing per class (see BackendClass):
/// - pm backends receive sessions they OWN (`owns()`) — the whole confirmed
///   record, exactly the pre-registry behaviour when one pm is registered.
/// - finance backends receive sessions the `financeEligible` closure accepts
///   (effective billability + prospective-only gate), deliberately WITHOUT an
///   `owns()` check: ownership routes pm posting, billability routes finance
///   posting. For now every finance backend receives ALL billable time;
///   per-project finance routing is a named TODO.
/// - `.local` (personal) sessions reach NO backend of any class: the
///   eligibility queries exclude them and the `backendTaskID` guard below is
///   the belt-and-braces second lock.
///
/// Failure isolation: each backend's pass is independent — one backend
/// erroring (recorded on its ledger row, surfaced in its report) never blocks
/// the others, and never throws out of this engine.
public final class SyncEngine {
    /// Per-backend outcome of one pass. `error` nil = clean pass.
    public struct BackendReport: Sendable {
        public let backendID: String
        public var posted = 0
        public var error: String?

        public init(backendID: String, posted: Int = 0, error: String? = nil) {
            self.backendID = backendID
            self.posted = posted
            self.error = error
        }
    }

    private let journal: any JournalStore
    private let backends: [RegisteredBackend]
    /// Sessions the engine must never touch (the live crash-checkpoint
    /// sentinel rows, which are internal state, not tracked time).
    public var excludedSessionIDs: Set<UUID> = []
    public var onDebug: (String) -> Void = { _ in }

    public init(journal: any JournalStore, backends: [RegisteredBackend]) {
        self.journal = journal
        self.backends = backends
    }

    /// Single-backend convenience (iOS engine, checks, integration harness).
    /// `id` keys the ledger — pass the connection's stable id.
    public convenience init(journal: any JournalStore, backend: any TaskBackend,
                            id: String, class backendClass: BackendClass = .pm) {
        self.init(journal: journal,
                  backends: [RegisteredBackend(id: id, class: backendClass, backend: backend)])
    }

    /// One fan-out pass. Never throws: each backend's first failure ends ITS
    /// pass (later sessions stay queued for a clean retry, as before) and is
    /// reported per backend, while every other backend proceeds.
    @discardableResult
    public func pushEligible(threshold: Double, defaultActivityID: Int? = nil,
                             activityOverrides: [TaskRef: Int] = [:],
                             includeComments: Bool,
                             financeEligible: (Session) -> Bool = { _ in false },
                             now: Date = Date()) async -> [BackendReport] {
        // Re-assert the single-slot migration before every pass. It is
        // per-row idempotent (NOT EXISTS guard), so this is near-free - and
        // it closes the window where a failed launch-time migration (try?
        // at controller init, e.g. disk-full) would otherwise leave legacy
        // pushed rows invisible to the ledger and re-post the entire
        // history to the pm backend. A migration failure here PAUSES the
        // pass entirely: no ledger truth, no posting.
        if let pm = backends.first(where: { $0.backendClass == .pm }) {
            do {
                _ = try journal.migrateSingleSlotPostings(to: pm.id,
                                                          excluding: excludedSessionIDs)
            } catch {
                onDebug("sync paused: single-slot migration failed: \(error)")
                return backends.map { BackendReport(backendID: $0.id) }
            }
        }
        var reports: [BackendReport] = []
        for entry in backends {
            var report = BackendReport(backendID: entry.id)
            let queue = ((try? journal.sessions(needingPostTo: entry.id,
                                                atOrAbove: threshold)) ?? [])
                .filter { !excludedSessionIDs.contains($0.id) }
            sessionLoop: for session in queue {
                // Class routing. Unknown classes receive nothing (safe until
                // a routing rule for them exists).
                switch entry.backendClass {
                case .pm:
                    // Ownership guard: an .op session must never post to a
                    // different pm backend. Un-owned sessions stay queued for
                    // THEIR backend — skipped silently, never marked.
                    guard entry.backend.owns(session.task) else { continue }
                case .finance:
                    guard financeEligible(session) else {
                        // A retryable failure whose session is no longer
                        // billable is closed off: the flip stops future
                        // postings; posted history is never clawed back.
                        if let row = ((try? journal.postingRecord(
                                session: session.id, backendID: entry.id)) ?? nil),
                           row.state == .failed {
                            var closed = row
                            closed.state = .skipped
                            closed.updatedAt = now
                            try? journal.setPostingRecord(closed)
                        }
                        continue
                    }
                default:
                    continue
                }
                // Personal (.local) tasks have no backend id and must never
                // leave the Mac — for ANY backend class, whatever any flag says.
                guard let taskID = session.task.backendTaskID else { continue }
                let duration = session.end.timeIntervalSince(session.start)
                if duration < 60 {
                    // Too short for a backend entry (OP would round it to
                    // PT0H0M); close THIS backend's row so it never clogs the
                    // queue. Mirrored to the legacy flag for pm so the
                    // journal summary arithmetic is unchanged.
                    try? journal.setPostingRecord(PostingRecord(
                        sessionID: session.id, backendID: entry.id,
                        state: .skipped, updatedAt: now))
                    if entry.backendClass == .pm {
                        try? journal.markPushed(session.id, opTimeEntryID: nil)
                    }
                    continue
                }
                let activity = activityOverrides[session.task] ?? defaultActivityID
                let comment = includeComments ? session.comment : nil
                do {
                    let entryID = try await entry.backend.createTimeEntry(
                        taskID: taskID, start: session.start, duration: duration,
                        activityID: activity, comment: comment)
                    // The create succeeded; the backend now holds the entry.
                    // If writing the ledger row fails, the next pass would
                    // re-POST it = duplicate. Roll the backend back to match
                    // the journal: best-effort delete the just-created entry,
                    // then record the failure so the session retries clean.
                    let prior = ((try? journal.postingRecord(
                        session: session.id, backendID: entry.id)) ?? nil)
                    do {
                        try journal.setPostingRecord(PostingRecord(
                            sessionID: session.id, backendID: entry.id,
                            state: .posted, entryID: entryID,
                            attempts: prior?.attempts ?? 0, updatedAt: now))
                    } catch {
                        if let entryID {
                            do { try await entry.backend.deleteTimeEntry(id: entryID) }
                            catch { onDebug("orphan cleanup failed for entry \(entryID): \(error)") }
                        }
                        throw error
                    }
                    if entry.backendClass == .pm {
                        // Legacy single-slot mirror: keeps timeline PATCH /
                        // delete and the summary reading the fields they
                        // always did. Best-effort — the ledger row above is
                        // what gates eligibility, so a mirror failure can
                        // never double-post.
                        do { try journal.markPushed(session.id, opTimeEntryID: entryID) }
                        catch { onDebug("legacy pushed-mirror failed for \(session.id): \(error)") }
                    }
                    report.posted += 1
                } catch {
                    // Failure isolation: record it on this row, end THIS
                    // backend's pass (later sessions stay queued, as the
                    // single-backend engine always behaved), and carry on to
                    // the next backend.
                    let prior = ((try? journal.postingRecord(
                        session: session.id, backendID: entry.id)) ?? nil)
                    try? journal.setPostingRecord(PostingRecord(
                        sessionID: session.id, backendID: entry.id,
                        state: .failed, lastError: "\(error)",
                        attempts: (prior?.attempts ?? 0) + 1, updatedAt: now))
                    report.error = "\(error)"
                    break sessionLoop
                }
            }
            reports.append(report)
        }
        return reports
    }
}
