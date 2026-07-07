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
        /// Sessions closed off this pass because the backend rejected them
        /// PERMANENTLY (PermanentPostError) — surfaced, never retried.
        public var permanentlySkipped = 0
        public var error: String?

        public init(backendID: String, posted: Int = 0,
                    permanentlySkipped: Int = 0, error: String? = nil) {
            self.backendID = backendID
            self.posted = posted
            self.permanentlySkipped = permanentlySkipped
            self.error = error
        }
    }

    /// After this many failed attempts a row is quarantined `.stuck` and the
    /// queue proceeds past it — one persistently-failing session must not
    /// block a backend forever. Generous on purpose: at one pass a minute a
    /// genuinely transient outage heals long before the cap.
    public static let transientAttemptsCap = 30

    /// How old an unresolved `.inflight` row must be before the reconcile
    /// sweep trusts the backend's list to answer "did the create land?".
    /// Xero's list index lags writes by seconds (live-verified 2026-07-06);
    /// a row younger than this waits for the next pass rather than adopting
    /// a false "no match".
    public static let inflightSettleFloor: TimeInterval = 60

    /// Resolve `.inflight` rows a dead process left behind (crashed between
    /// createTimeEntry returning and the ledger write): VERIFY against the
    /// backend instead of blind re-creating. A match (same task, start,
    /// duration) adopts the entry's id → `.posted`; a confirmed miss demotes
    /// to `.failed` so the session retries cleanly THIS pass; a list failure
    /// leaves the row `.inflight` for the next pass — never a second create
    /// while intent is unresolved. (F12/D3.)
    private func reconcileInflight(_ entry: RegisteredBackend, now: Date) async {
        let rows = ((try? journal.postingRecords(state: .inflight,
                                                 backendID: entry.id)) ?? [])
        for row in rows where now.timeIntervalSince(row.updatedAt) >= Self.inflightSettleFloor {
            guard let session = ((try? journal.session(id: row.sessionID)) ?? nil),
                  let taskID = session.task.backendTaskID else {
                // The session vanished while its create was in flight: close
                // the row off; there is nothing to adopt it for.
                var closed = row
                closed.state = .skipped
                closed.lastError = "session deleted while a create was in flight"
                closed.updatedAt = now
                try? journal.setPostingRecord(closed)
                continue
            }
            // Match what actually went on the wire: the intent row's resolved
            // snapshot when present (D1 — the posted span can be a trimmed
            // contribution, not the raw span); raw span for pre-snapshot rows.
            let sentStart = row.postedStart ?? session.start
            let sentDuration = row.postedDuration
                ?? session.end.timeIntervalSince(session.start)
            do {
                let candidates = try await entry.backend.listTimeEntries(
                    from: sentStart.addingTimeInterval(-3600),
                    to: sentStart.addingTimeInterval(sentDuration + 3600))
                let match = candidates.first { candidate in
                    guard candidate.taskID == taskID,
                          abs(candidate.durationSeconds - sentDuration) <= 90 else { return false }
                    // Day-granular backends (hasStart false) can only match
                    // to the day; minute-true ones match tight.
                    return candidate.hasStart
                        ? abs(candidate.start.timeIntervalSince(sentStart)) <= 90
                        : abs(candidate.start.timeIntervalSince(sentStart)) <= 86_400
                }
                var resolved = row
                if let match {
                    resolved.state = .posted
                    resolved.entryID = match.id
                    resolved.lastError = nil
                    onDebug("inflight adopt: \(entry.id) already held \(match.id)")
                } else {
                    resolved.state = .failed   // confirmed miss: clean retry
                    resolved.lastError = "in-flight create not found at the backend — retrying"
                }
                resolved.updatedAt = now
                try? journal.setPostingRecord(resolved)
            } catch {
                onDebug("inflight verify failed for \(row.sessionID): \(error)")
                // Leave .inflight: unresolved intent must block re-creates.
            }
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
            // Crash recovery FIRST: rows left `.inflight` by a dead process
            // are verified-and-adopted (or demoted to a clean retry) before
            // the queue is read, so a demoted session re-enters THIS pass.
            await reconcileInflight(entry, now: now)
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
                // What we BILL is the session's overlap-RESOLVED contribution
                // (D1): with sync on, higher-priority cross-device slices may
                // have claimed part (or all) of this span — posting the raw
                // span would double-bill the claimed minutes. Sync off, this
                // IS the stored span. A fully-covered session contributes 0
                // and falls into the sub-minute skip below.
                let contribution = ((try? journal.resolvedContribution(sessionID: session.id))
                    ?? nil) ?? (session.start, 0)
                let postStart = contribution.0
                let duration = contribution.1
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
                // INTENT before the wire (F12/D3): if the process dies inside
                // the create window, this row is the evidence — the next
                // pass's reconcile verifies the backend instead of blindly
                // re-creating. If even the intent can't be written, do NOT
                // create (no truth, no posting — same stance as the
                // migration guard above).
                let prior = ((try? journal.postingRecord(
                    session: session.id, backendID: entry.id)) ?? nil)
                do {
                    try journal.setPostingRecord(PostingRecord(
                        sessionID: session.id, backendID: entry.id,
                        state: .inflight, lastError: prior?.lastError,
                        attempts: prior?.attempts ?? 0, updatedAt: now,
                        postedStart: postStart, postedDuration: duration))
                } catch {
                    report.error = "ledger write failed: \(error)"
                    break sessionLoop
                }
                do {
                    let entryID = try await entry.backend.createTimeEntry(
                        taskID: taskID, start: postStart, duration: duration,
                        activityID: activity, comment: comment)
                    // The create succeeded; the backend now holds the entry.
                    // If writing the `.posted` row fails, the row STAYS
                    // `.inflight` — excluded from eligibility, resolved by
                    // the next pass's verify-then-adopt. (The old code
                    // best-effort DELETED the fresh entry here; leaving the
                    // intent row and adopting later is strictly safer — no
                    // orphan risk when the delete itself failed.)
                    do {
                        try journal.setPostingRecord(PostingRecord(
                            sessionID: session.id, backendID: entry.id,
                            state: .posted, entryID: entryID,
                            attempts: prior?.attempts ?? 0, updatedAt: now,
                            postedStart: postStart, postedDuration: duration))
                    } catch {
                        onDebug("posted-row write failed for \(session.id); left .inflight for adopt: \(error)")
                        report.error = "ledger write failed: \(error)"
                        break sessionLoop
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
                } catch let permanent as PermanentPostError {
                    // The backend says this can NEVER succeed (task gone,
                    // entry frozen, no mapping): close the row with the
                    // reason and let the queue PROCEED — a permanent
                    // rejection at the head must not dam every session
                    // behind it forever.
                    let prior = ((try? journal.postingRecord(
                        session: session.id, backendID: entry.id)) ?? nil)
                    try? journal.setPostingRecord(PostingRecord(
                        sessionID: session.id, backendID: entry.id,
                        state: .skipped, lastError: permanent.reason,
                        attempts: (prior?.attempts ?? 0) + 1, updatedAt: now))
                    report.permanentlySkipped += 1
                    continue
                } catch {
                    // Transient (or unclassified) failure: record it on this
                    // row, end THIS backend's pass (later sessions stay
                    // queued for a clean retry, as the single-backend engine
                    // always behaved), and carry on to the next backend —
                    // UNLESS this row has hit the attempts cap, in which
                    // case it is quarantined `.stuck` (excluded from
                    // eligibility, surfaced; clearing the row retries) and
                    // the queue proceeds past it.
                    let prior = ((try? journal.postingRecord(
                        session: session.id, backendID: entry.id)) ?? nil)
                    let attempts = (prior?.attempts ?? 0) + 1
                    let quarantined = attempts >= Self.transientAttemptsCap
                    try? journal.setPostingRecord(PostingRecord(
                        sessionID: session.id, backendID: entry.id,
                        state: quarantined ? .stuck : .failed, lastError: "\(error)",
                        attempts: attempts, updatedAt: now))
                    // A quarantine names itself in the surfaced error, so a
                    // pass that also made progress doesn't read as a plain
                    // "push failed".
                    report.error = quarantined
                        ? "one entry quarantined after \(attempts) attempts: \(error)"
                        : "\(error)"
                    if quarantined { continue }
                    break sessionLoop
                }
            }
            reports.append(report)
        }
        return reports
    }
}
