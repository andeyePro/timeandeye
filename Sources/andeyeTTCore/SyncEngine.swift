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
/// Holds the per-backend "when did we last poll invoice status" times
/// ACROSS engine instances — see SyncEngine.invoicePollClock.
public final class InvoicePollClock {
    fileprivate var last: [String: Date] = [:]
    public init() {}
}

public final class SyncEngine {
    /// Per-backend outcome of one pass. `error` nil = clean pass.
    public struct BackendReport: Sendable {
        public let backendID: String
        public var posted = 0
        /// Sessions closed off this pass because the backend rejected them
        /// PERMANENTLY (PermanentPostError) — surfaced, never retried.
        public var permanentlySkipped = 0
        /// Posted entries whose journal-side change was PROPAGATED this pass
        /// (updated in place, or deleted+recreated for a cross-project move).
        public var amended = 0
        /// Backend entries DELETED because their journal side went away
        /// (session deleted / fully covered).
        public var retracted = 0
        /// Posted entries that STILL disagree with the journal after this
        /// pass: frozen at the backend (terminal, needs a human) or not yet
        /// reachable (amendment errored / capped this pass).
        public var diverged = 0
        /// Rows under an invoice lock this pass — billed time the amendment
        /// loop deliberately leaves alone (surfaced, not a problem per se).
        public var locked = 0
        public var error: String?

        public init(backendID: String, posted: Int = 0,
                    permanentlySkipped: Int = 0, amended: Int = 0,
                    retracted: Int = 0, diverged: Int = 0,
                    locked: Int = 0, error: String? = nil) {
            self.backendID = backendID
            self.posted = posted
            self.permanentlySkipped = permanentlySkipped
            self.amended = amended
            self.retracted = retracted
            self.diverged = diverged
            self.locked = locked
            self.error = error
        }
    }

    /// Amendments per pass are capped so a mass edit (a prune, a big
    /// multi-select reassign) drains over a few passes instead of firing an
    /// unbounded burst at a rate-limited backend.
    public static let amendmentsPerPass = 20

    /// Journal-vs-posted drift beyond this is a divergence (a minute — the
    /// same floor posting itself uses; sub-minute wobble never re-bills).
    public static let divergenceTolerance: TimeInterval = 60

    /// Whether the session's record changed since this row last saw it — a
    /// pure REVISION-STAMP comparison (reviewer A4: comparing a remote HLC's
    /// physical time against this device's wall clock broke under skew in
    /// both directions). nil stamps (sync off) never read as touched.
    private func stampChanged(_ row: PostingRecord) -> Bool {
        guard let current = ((try? journal.sessionStamp(row.sessionID)) ?? nil) else {
            return false
        }
        return current != row.sessionStamp
    }

    /// The reconcile/verify matcher: does `candidates` hold the entry this
    /// row claims? Id match is authoritative when we have one; otherwise the
    /// FULL signature — task + start (day-granular when hasStart is false) +
    /// duration (reviewer A6: a duration-only fallback adopted neighbours).
    private static func holds(_ candidates: [RemoteTimeEntry], entryID: RemoteEntryID?,
                              taskID: String, start: Date, duration: TimeInterval) -> Bool {
        if let entryID { return candidates.contains { $0.id == entryID } }
        return candidates.contains { candidate in
            guard candidate.taskID == taskID,
                  abs(candidate.durationSeconds - duration) <= 90 else { return false }
            return candidate.hasStart
                ? abs(candidate.start.timeIntervalSince(start)) <= 90
                : abs(candidate.start.timeIntervalSince(start)) <= 86_400
        }
    }

    /// F13: a `.posted` row whose session REVISION changed since the row was
    /// written may be a resurrection — device A tombstoned the session and
    /// deleted the backend entry; a newer edit resurrected it via sync; this
    /// replica's row still claims `.posted` for an entry that no longer
    /// exists (journal says billed, backend holds nothing — the invisible
    /// inverse of a double-post). Verify ONLY changed rows at the backend:
    /// present ⇒ re-stamp the row (quiet until it changes again); missing ⇒
    /// DEMOTE to `.failed` so THIS pass re-posts exactly once. Demote, never
    /// clear (reviewer A1): a cleared row plus the session's synced
    /// `pushed=1` mirror lets the every-pass single-slot migration resurrect
    /// a stale `.posted` row with the DEAD entry id — permanently cancelling
    /// the re-post; a `.failed` row survives the migration's NOT-EXISTS
    /// guard. A list failure leaves the row untouched.
    private func verifyTouchedPosted(_ entry: RegisteredBackend, now: Date) async {
        let rows = ((try? journal.postingRecords(state: .posted,
                                                 backendID: entry.id)) ?? [])
        for row in rows {
            // Invoice-locked rows are exempt: demoting one to `.failed`
            // would re-post — a duplicate of already-billed time. Their
            // journal-vs-books disagreement surfaces in amendDiverged's
            // locked branch instead.
            guard row.lockedInvoiceRef == nil else { continue }
            guard stampChanged(row),
                  let taskID = ((try? journal.session(id: row.sessionID)) ?? nil)?
                      .task.backendTaskID,
                  let contribution = ((try? journal.resolvedContribution(sessionID: row.sessionID)) ?? nil)
            else { continue }   // unchanged, or retract-case (D4 counts it)
            let sentStart = row.postedStart ?? contribution.start
            let sentDuration = row.postedDuration ?? contribution.seconds
            do {
                let candidates = try await entry.backend.listTimeEntries(
                    from: sentStart.addingTimeInterval(-3600),
                    to: sentStart.addingTimeInterval(sentDuration + 3600))
                var updated = row
                if Self.holds(candidates, entryID: row.entryID, taskID: taskID,
                              start: sentStart, duration: sentDuration) {
                    updated.updatedAt = now
                    updated.sessionStamp = ((try? journal.sessionStamp(row.sessionID)) ?? nil)
                    try? journal.setPostingRecord(updated)
                } else {
                    onDebug("posted entry missing at \(entry.id) for \(row.sessionID) — demoting for re-post (resurrection)")
                    updated.state = .failed
                    updated.lastError = "backend entry vanished (deleted on another device) — re-posting"
                    updated.updatedAt = now
                    try? journal.setPostingRecord(updated)
                }
            } catch {
                onDebug("posted-verify list failed at \(entry.id): \(error)")
            }
        }
    }

    /// Rows whose postedStart is older than this only diverge via their own
    /// record changing (claims are time-local; nobody edits last quarter's
    /// overlaps) — so old rows are scanned only when their stamp changes,
    /// keeping the every-pass scan bounded instead of growing with all
    /// posted history forever (reviewer A7).
    public static let divergenceScanHorizon: TimeInterval = 45 * 86_400

    // MARK: Invoice locks (Martin's invoice-lock proposal, adopted 2026-07-08)

    /// Invoices are human-cadence events; polling the backend's invoice
    /// status every sync pass would burn Xero's 5,000/day tenant budget for
    /// nothing. Half-hourly keeps worst-case daily calls in the tens.
    public static let invoicePollInterval: TimeInterval = 1800
    /// Ids per poll, newest first — bounds one poll's API cost after a long
    /// offline gap; the remainder locks on later polls.
    public static let invoicePollBatch = 40

    /// Ask the backend which recent posted entries a SENT invoice now covers,
    /// and stamp the lock (ref) onto their ledger rows. Refs the user
    /// explicitly unlocked are never re-applied (same invoice; a NEW ref
    /// locks as normal). Locks only ever SET here — clearing is the human's
    /// per-invoice unlock, so a voided invoice can't silently re-open billed
    /// time. A poll failure changes nothing (fail closed = stay unlocked and
    /// let the amendment path's frozen handling catch any write refusal).
    private func pollInvoiceLocks(_ entry: RegisteredBackend, now: Date) async {
        if let last = invoicePollClock.last[entry.id],
           now.timeIntervalSince(last) < Self.invoicePollInterval { return }
        invoicePollClock.last[entry.id] = now
        let candidates = ((try? journal.postingRecords(state: .posted,
                                                       backendID: entry.id)) ?? [])
            .filter { $0.lockedInvoiceRef == nil && $0.entryID != nil }
            .filter { ($0.postedStart ?? .distantPast) > now.addingTimeInterval(-Self.divergenceScanHorizon) }
            .sorted { ($0.postedStart ?? .distantPast) > ($1.postedStart ?? .distantPast) }
            .prefix(Self.invoicePollBatch)
        guard !candidates.isEmpty else { return }
        guard let locks = try? await entry.backend.invoiceLocks(
            for: candidates.compactMap(\.entryID)) else { return }
        guard !locks.isEmpty else { return }
        let suppressed = ((try? journal.unlockedInvoiceRefs(backendID: entry.id)) ?? [])
        for row in candidates {
            guard let entryID = row.entryID, let ref = locks[entryID],
                  !suppressed.contains(ref) else { continue }
            var updated = row
            updated.lockedInvoiceRef = ref
            updated.updatedAt = now
            try? journal.setPostingRecord(updated)
            onDebug("invoice lock applied at \(entry.id) for \(row.sessionID): \(ref)")
        }
    }

    /// The per-invoice UNLOCK: lifts the app-side guard on every row locked
    /// under `ref`, un-parks any that diverged WHILE locked (back to
    /// `.posted`; the stamp mismatch re-arms amendment on the next pass),
    /// and remembers the ref so polling never re-applies the same invoice.
    /// The backend side (credit-note/void) stays the accountant's act —
    /// entries still frozen at the backend park again via frozen handling.
    public func unlockInvoice(ref: String, backendID: String, now: Date = Date()) {
        try? journal.addUnlockedInvoiceRef(ref, backendID: backendID)
        for state in [PostingState.posted, .diverged] {
            for row in ((try? journal.postingRecords(state: state, backendID: backendID)) ?? [])
            where row.lockedInvoiceRef == ref {
                var updated = row
                updated.lockedInvoiceRef = nil
                updated.lastError = nil
                if state == .diverged { updated.state = .posted }
                updated.updatedAt = now
                try? journal.setPostingRecord(updated)
            }
        }
    }

    /// D4 — the CONVERGENCE loop. Every `.posted` row with a snapshot is
    /// compared against the CURRENT resolved journal; where the journal has
    /// moved, the backend FOLLOWS:
    /// - drift (duration/start) → updateTimeEntry in place; a backend that
    ///   can't move the entry (AmendmentError.mustRecreate — Xero across
    ///   projects) gets delete + recreate with a fresh id;
    /// - session deleted / fully covered / moved to a personal task →
    ///   deleteTimeEntry, row `.retracted` (re-opens for a clean re-post if
    ///   the journal side later returns);
    /// - frozen at the backend (AmendmentError.frozen: invoiced/locked) →
    ///   row `.diverged`, terminal and surfaced — a human must reconcile;
    /// - any OTHER error → row untouched, counted diverged, retried next
    ///   pass (no data-destroying guesses on unknown failures).
    /// Returns (amended, retracted, still-diverged) for the pass report.
    private func amendDiverged(_ entry: RegisteredBackend, now: Date,
                               defaultActivityID: Int?,
                               activityOverrides: [TaskRef: Int],
                               includeComments: Bool) async
        -> (amended: Int, retracted: Int, diverged: Int, locked: Int) {
        var amended = 0, retracted = 0, diverged = 0, locked = 0
        var budget = Self.amendmentsPerPass

        // Re-open retractions whose journal side came back.
        for row in ((try? journal.postingRecords(state: .retracted,
                                                 backendID: entry.id)) ?? []) {
            guard stampChanged(row),
                  ((try? journal.resolvedContribution(sessionID: row.sessionID)) ?? nil) != nil
            else { continue }
            var reopened = row
            reopened.state = .failed
            reopened.entryID = nil
            reopened.lastError = "journal side restored — re-posting"
            reopened.updatedAt = now
            try? journal.setPostingRecord(reopened)
        }

        let rows = ((try? journal.postingRecords(state: .posted,
                                                 backendID: entry.id)) ?? [])
        for row in rows {
            // INVOICE LOCK: billed time is untouchable through this loop.
            // If the journal has since moved (drift or the session gone),
            // surface the disagreement ONCE on the row — never amend, never
            // retract; the human unlocks the invoice to reconcile. Checked
            // by CONTENT (the same drift math as below), not by stamp:
            // single-device stores have no stamps and their edits must
            // surface too.
            if let ref = row.lockedInvoiceRef {
                locked += 1
                if row.lastError == nil, let sentDuration = row.postedDuration {
                    let contribution = ((try? journal.resolvedContribution(sessionID: row.sessionID)) ?? nil)
                    let moved: Bool
                    if let contribution {
                        moved = abs(contribution.seconds - sentDuration) > Self.divergenceTolerance
                            || (row.postedStart.map {
                                    abs(contribution.start.timeIntervalSince($0)) > Self.divergenceTolerance
                                } ?? false)
                    } else {
                        moved = true   // journal side gone entirely: definitely moved
                    }
                    if moved {
                        var updated = row
                        updated.lastError = "locked by invoice \(ref) — the journal moved but this time is billed; unlock the invoice to reconcile"
                        updated.updatedAt = now
                        try? journal.setPostingRecord(updated)
                    }
                }
                continue
            }
            guard let sentDuration = row.postedDuration else { continue }   // pre-snapshot row
            let recent = (row.postedStart ?? .distantPast) > now.addingTimeInterval(-Self.divergenceScanHorizon)
            guard recent || stampChanged(row) else { continue }
            let session = ((try? journal.session(id: row.sessionID)) ?? nil)
            let contribution = ((try? journal.resolvedContribution(sessionID: row.sessionID)) ?? nil)
            let taskID = session?.task.backendTaskID

            // RETRACT: nothing in the journal supports this entry any more.
            guard let contribution, let taskID else {
                guard budget > 0 else { diverged += 1; continue }
                budget -= 1
                do {
                    if let entryID = row.entryID {
                        try await entry.backend.deleteTimeEntry(id: entryID)
                    }
                    var updated = row
                    updated.state = .retracted
                    updated.lastError = "journal side removed — entry deleted at the backend"
                    updated.sessionStamp = ((try? journal.sessionStamp(row.sessionID)) ?? nil)
                    updated.updatedAt = now
                    try? journal.setPostingRecord(updated)
                    retracted += 1
                } catch let amendment as AmendmentError where amendment != .mustRecreate {
                    parkFrozen(row, entry: entry, now: now)
                    diverged += 1
                } catch {
                    onDebug("retract failed at \(entry.id) for \(row.sessionID): \(error)")
                    diverged += 1   // untouched; retried next pass
                }
                continue
            }

            // DRIFT: does the entry still match what the journal says?
            let durationDrift = abs(contribution.seconds - sentDuration) > Self.divergenceTolerance
            let startDrift = row.postedStart.map {
                abs(contribution.start.timeIntervalSince($0)) > Self.divergenceTolerance
            } ?? false
            guard durationDrift || startDrift else { continue }
            guard budget > 0, let entryID = row.entryID else {
                diverged += 1
                continue
            }
            budget -= 1
            let activity = session.map { activityOverrides[$0.task] ?? defaultActivityID }
                ?? defaultActivityID
            let comment = includeComments ? session?.comment : nil
            do {
                do {
                    try await entry.backend.updateTimeEntry(
                        id: entryID, taskID: taskID, start: contribution.start,
                        duration: contribution.seconds, activityID: activity,
                        comment: comment)
                    finishAmend(row, entry: entry, entryID: entryID,
                                contribution: contribution, now: now)
                    amended += 1
                } catch AmendmentError.mustRecreate {
                    // The backend can't move it in place: replace the entry.
                    try await entry.backend.deleteTimeEntry(id: entryID)
                    let newID = try await entry.backend.createTimeEntry(
                        taskID: taskID, start: contribution.start,
                        duration: contribution.seconds, activityID: activity,
                        comment: comment)
                    finishAmend(row, entry: entry, entryID: newID,
                                contribution: contribution, now: now)
                    amended += 1
                }
            } catch let amendment as AmendmentError where amendment != .mustRecreate {
                parkFrozen(row, entry: entry, now: now)
                diverged += 1
            } catch {
                onDebug("amend failed at \(entry.id) for \(row.sessionID): \(error)")
                diverged += 1   // untouched; retried next pass
            }
        }
        return (amended, retracted, diverged, locked)
    }

    /// Amendment landed: refresh the snapshot to what the backend NOW holds,
    /// re-stamp, and keep the pm mirror honest.
    private func finishAmend(_ row: PostingRecord, entry: RegisteredBackend,
                             entryID: RemoteEntryID?,
                             contribution: (start: Date, seconds: TimeInterval),
                             now: Date) {
        var updated = row
        updated.entryID = entryID
        updated.postedStart = contribution.start
        updated.postedDuration = contribution.seconds
        updated.lastError = nil
        updated.sessionStamp = ((try? journal.sessionStamp(row.sessionID)) ?? nil)
        updated.updatedAt = now
        try? journal.setPostingRecord(updated)
        if entry.backendClass == .pm {
            try? journal.markPushed(row.sessionID, opTimeEntryID: entryID)
        }
    }

    /// Frozen at the backend: park terminally, surfaced in Posting health.
    private func parkFrozen(_ row: PostingRecord, entry: RegisteredBackend, now: Date) {
        var updated = row
        updated.state = .diverged
        updated.lastError = "entry is invoiced/locked at the backend — journal and books disagree; unlock or credit-note to reconcile"
        updated.updatedAt = now
        try? journal.setPostingRecord(updated)
        onDebug("frozen divergence parked at \(entry.id) for \(row.sessionID)")
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
                    resolved.sessionStamp = ((try? journal.sessionStamp(row.sessionID)) ?? nil)
                    onDebug("inflight adopt: \(entry.id) already held \(match.id)")
                    // Legacy pm mirror, same as the normal posted path
                    // (reviewer A5): without it the adopted session keeps
                    // pushedToOP=false/opTimeEntryID=nil, so timeline
                    // edit/delete never PATCHes/DELETEs the entry — a
                    // permanent orphan nothing detects.
                    if entry.backendClass == .pm {
                        try? journal.markPushed(row.sessionID, opTimeEntryID: match.id)
                    }
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
    /// The invoice-poll throttle OUTLIVES the engine (the controller builds
    /// a fresh engine every pass): the owner holds one clock and hands it to
    /// each engine, else every pass would re-poll and burn the API budget.
    /// The default (a fresh clock) polls on first pass — right for checks
    /// and single-shot engines.
    private let invoicePollClock: InvoicePollClock

    public init(journal: any JournalStore, backends: [RegisteredBackend],
                invoicePollClock: InvoicePollClock = InvoicePollClock()) {
        self.journal = journal
        self.backends = backends
        self.invoicePollClock = invoicePollClock
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
                             financePostFloor: Date? = nil,
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
            // Then F13: touched posted rows are verified at the backend —
            // a resurrection whose entry device A already deleted re-queues
            // HERE so this same pass re-posts it.
            await verifyTouchedPosted(entry, now: now)
            // Invoice locks next (throttled inside): entries a SENT invoice
            // covers get their lock stamped BEFORE the convergence loop, so
            // billed time is off-limits the moment the backend reports it.
            await pollInvoiceLocks(entry, now: now)
            // Then the D4 CONVERGENCE loop: the backend follows the journal
            // (update / delete+recreate / retract); frozen entries park
            // `.diverged` for a human; unknown failures retry next pass.
            let amendment = await amendDiverged(entry, now: now,
                                                defaultActivityID: defaultActivityID,
                                                activityOverrides: activityOverrides,
                                                includeComments: includeComments)
            report.amended = amendment.amended
            report.retracted = amendment.retracted
            report.diverged = amendment.diverged
            report.locked = amendment.locked
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
                    // Billability FIRST (its else-branch closes off failed
                    // rows on a flip — reviewer A8: the floor's `continue`
                    // used to starve that close-out for old rows), THEN the
                    // backfill age gate (F15): after a long-idle reconnect
                    // the accumulated backlog stays VISIBLY PENDING (no row —
                    // deliberate release posts it later), never flooding the
                    // books in one pass.
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
                    if let financePostFloor, session.start < financePostFloor {
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
                // IS the stored span.
                let contribution = ((try? journal.resolvedContribution(sessionID: session.id))
                    ?? nil) ?? (session.start, 0)
                let postStart = contribution.0
                let duration = contribution.1
                let rawDuration = session.end.timeIntervalSince(session.start)
                if duration < 60 {
                    // Two very different sub-minute cases (reviewer A3):
                    // - the RAW session is short: genuinely too small for a
                    //   backend entry, close it off terminally as ever;
                    // - the raw session is fine but OVERLAP TRIMS shrank it:
                    //   leave it PENDING (no row) — deleting/trimming the
                    //   covering slice later restores its contribution and
                    //   it posts then; a terminal skip would silently strand
                    //   hours of billable time forever.
                    if rawDuration < 60 {
                        try? journal.setPostingRecord(PostingRecord(
                            sessionID: session.id, backendID: entry.id,
                            state: .skipped, updatedAt: now))
                        if entry.backendClass == .pm {
                            try? journal.markPushed(session.id, opTimeEntryID: nil)
                        }
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
                let stamp = ((try? journal.sessionStamp(session.id)) ?? nil)
                do {
                    try journal.setPostingRecord(PostingRecord(
                        sessionID: session.id, backendID: entry.id,
                        state: .inflight, lastError: prior?.lastError,
                        attempts: prior?.attempts ?? 0, updatedAt: now,
                        postedStart: postStart, postedDuration: duration,
                        sessionStamp: stamp))
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
                            postedStart: postStart, postedDuration: duration,
                            sessionStamp: stamp))
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
