import Foundation
import SQLite3
import timeandeyeCore
import timeandeyeMac

// MARK: - PostingMachineChecks: the bounded model-check harness
//
// This suite is the harness the posting state-machine spec
// (docs/superpowers/specs/2026-07-12-posting-state-machine.md) calls for: a
// deterministic scenario runner that (a) sets up sessions + ledger cells, (b)
// executes a SEQUENCE of transitions — real `SyncEngine.pushEligible` passes
// and store-level user mutations, with scripted `FakeBackend` responses
// (success / transient failure / permanent rejection / entry-missing) — and
// (c) re-asserts the always-true invariant set after EVERY step via
// `Machine.step`. Each M-scenario layers its own targeted assertions on top.
//
// WHAT IT CAN EXPLORE: any ordering the seams already expose — pre-seeding a
// ledger cell into `.inflight`/`.posted`/`.stuck`/`.diverged`/unknown before a
// pass (the "a mutation raced ahead of / behind the pass" orderings), scripted
// per-call backend outcomes (failNextCreates/failNextLists/permanentlyRejects/
// frozenIDs/recreateOnUpdate/invoiced/held), crash-window intent rows, and
// overlap-resolution coverage lifts. WHAT IT CANNOT: pause a single
// `pushEligible` mid-`await` to land a mutation between its network call and
// its ledger write — `pushEligible` is one un-interruptible async call with no
// injection seam. True mid-await interleaving is therefore APPROXIMATED by the
// discrete orderings above (pre-place the raced state, then run the pass),
// exactly as the requarantine/atomic-CAS checks in ResolvedPostingChecks do.
// Where that approximation is all today's seams allow, the scenario says so.
//
// This wave (W1) pins the invariants that ALREADY hold (M1, M5-first-clause,
// M6, M7, M8). The three known holes — lock-blind user edits, delete-failure
// clears, finance-rows-on-session-delete (M2/M3/M4) — are W2's, red-first
// against this harness; no check here is allowed to be red today.
func postingMachineChecks(_ c: Checks) async {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func makeStore() throws -> SQLiteJournalStore {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("andeyett-machine-\(UUID().uuidString).sqlite").path
        return try SQLiteJournalStore(path: path)
    }
    var nowMillis: Int64 = 1_750_000_000_000
    func makeClock() -> HLCClock {
        HLCClock(deviceID: "mac") { Date(timeIntervalSince1970: Double(nowMillis) / 1000) }
    }
    let primaryPM = OPBackend.stableID   // the primary-pm ledger key the mirror twins

    // MARK: The runner
    //
    // Holds the store, the fan-out engine, the backends by ledger id, and the
    // tracked (session → its UNIQUE backendTaskID) map that lets `assertCore`
    // attribute a backend's held entries to one cell. `step` runs a transition
    // then re-asserts `assertCore`; a violation names the step that produced it.
    final class Machine {
        let store: any JournalStore
        let engine: SyncEngine
        let backendByID: [String: FakeBackend]
        var tracked: [(id: UUID, taskID: String)] = []
        init(store: any JournalStore, backends: [(id: String, cls: BackendClass, be: FakeBackend)]) {
            self.store = store
            self.engine = SyncEngine(journal: store,
                backends: backends.map { RegisteredBackend(id: $0.id, class: $0.cls, backend: $0.be) })
            self.backendByID = Dictionary(uniqueKeysWithValues: backends.map { ($0.id, $0.be) })
        }
        func track(_ s: Session) { tracked.append((s.id, s.task.backendTaskID ?? "?")) }

        /// M1's structural core, true after EVERY step: no cell (one
        /// session, one backend) ever backs two live remote entries. With a
        /// unique task per tracked session, a backend's held entries for that
        /// task ARE that cell's live entries — more than one is a double-post.
        func assertCore(_ label: String) throws {
            for (_, taskID) in tracked {
                for (bid, fake) in backendByID {
                    let live = fake.held.filter { $0.taskID == taskID }.count
                    if live > 1 {
                        throw CheckFailure(description:
                            "\(label): M1 violated — task \(taskID) has \(live) live entries at \(bid)")
                    }
                }
            }
        }

        @discardableResult
        func pass(_ label: String, now: Date,
                  financeEligible: @escaping (Session) -> Bool = { _ in false },
                  financePostFloor: Date? = nil) async throws -> [SyncEngine.BackendReport] {
            let reports = await engine.pushEligible(
                threshold: 0.8, includeComments: false,
                financeEligible: financeEligible, financePostFloor: financePostFloor, now: now)
            try assertCore("after pass: \(label)")
            return reports
        }

        /// A store-level user mutation (there is no AppController in checks —
        /// it is @MainActor and its wire calls live there; controller
        /// mechanics are replayed against the real store + engine, the house
        /// pattern MultiBackendSyncChecks/ResolvedPostingChecks use).
        func mutate(_ label: String, _ body: () async throws -> Void) async throws {
            try await body()
            try assertCore("after mutation: \(label)")
        }

        func cell(_ s: UUID, _ backendID: String) -> PostingRecord? {
            (try? store.postingRecord(session: s, backendID: backendID)) ?? nil
        }
    }

    func session(_ ref: TaskRef, _ from: TimeInterval, _ to: TimeInterval,
                 certainty: Double = 0.95) -> Session {
        Session(task: ref, start: t(from), end: t(to), certainty: certainty)
    }

    // ===================================================================
    // M1 — one live entry: a cell never has two live remote entries; creates
    // happen only from ∅/failed/stuck and always via inflight first.
    // ===================================================================

    await c.check("M1: creates fire only from ∅/failed/stuck; a terminal row is never re-created") {
        let store = try makeStore()
        store.clock = makeClock()
        let pm = FakeBackend(owns: .op)
        let m = Machine(store: store, backends: [(primaryPM, .pm, pm)])

        // Three cells, three starting states the queue treats differently.
        let fromEmpty = session(.op(1), 0, 3600)          // ∅   → eligible
        let fromFailed = session(.op(2), 3600, 7200)      // failed → eligible (retry)
        let fromPosted = session(.op(3), 7200, 10800)     // posted → terminal, never re-created
        for s in [fromEmpty, fromFailed, fromPosted] { try store.save(s); m.track(s) }
        try await m.mutate("seed failed + terminal-posted rows") {
            try store.setPostingRecord(PostingRecord(sessionID: fromFailed.id,
                backendID: primaryPM, state: .failed, attempts: 1, updatedAt: t(0)))
            // A pre-existing posted row WITH a live backend entry: a create
            // from here would be the classic double-post M1 forbids.
            let e = try await pm.createTimeEntry(taskID: "3", start: fromPosted.start,
                duration: 3600, activityID: nil, comment: nil)
            try store.setPostingRecord(PostingRecord(sessionID: fromPosted.id,
                backendID: primaryPM, state: .posted, entryID: e, updatedAt: t(0)))
        }
        let before = pm.created.count
        try await m.pass("first fan-out", now: t(20000))
        // ∅ and failed posted exactly once each; the terminal posted did not.
        try expectEq(m.cell(fromEmpty.id, primaryPM)?.state, .posted)
        try expectEq(m.cell(fromFailed.id, primaryPM)?.state, .posted)
        try expectEq(pm.created.count - before, 2, "only ∅ and failed created — 2 new entries")
        try expectEq(pm.held.filter { $0.taskID == "3" }.count, 1,
                     "the terminal posted cell still backs exactly one entry (no re-create)")

        // A stuck cell is eligible again only once its row is cleared (the
        // retry gesture); until then it does not create.
        try await m.mutate("quarantine op(1) as stuck, then re-run") {
            try store.setPostingRecord(PostingRecord(sessionID: fromEmpty.id,
                backendID: primaryPM, state: .stuck, attempts: 30, updatedAt: t(0)))
        }
        let afterFirst = pm.created.count
        try await m.pass("stuck holds", now: t(20100))
        try expectEq(pm.created.count, afterFirst, "a .stuck cell does not re-create until cleared")
    }

    await c.check("M1: crash-reconcile ADOPTS an orphan via the inflight row — never a second create") {
        // The intent-before-wire law: the process died between createTimeEntry
        // returning and the .posted write, leaving only the .inflight row + a
        // live backend entry. reconcileInflight must adopt that entry, not
        // create a rival — keeping M1 across the crash window.
        let store = try makeStore()
        store.clock = makeClock()
        let pm = FakeBackend(owns: .op)
        let m = Machine(store: store, backends: [(primaryPM, .pm, pm)])
        let s = session(.op(1), 0, 3600)
        try store.save(s); m.track(s)
        try await m.mutate("plant orphan entry + dangling inflight intent") {
            let orphan = try await pm.createTimeEntry(taskID: "1", start: s.start,
                duration: 3600, activityID: nil, comment: nil)
            try store.setPostingRecord(PostingRecord(sessionID: s.id, backendID: primaryPM,
                state: .inflight, updatedAt: t(0),
                postedStart: s.start, postedDuration: 3600,
                sessionStamp: try store.sessionStamp(s.id)))
            _ = orphan
        }
        // Past the settle floor so reconcile trusts the backend list.
        try await m.pass("reconcile adopts", now: t(20000))
        let cell = m.cell(s.id, primaryPM)
        try expectEq(cell?.state, .posted, "the inflight intent settled to posted")
        try expectEq(pm.created.count, 1, "exactly one entry ever created — the orphan was adopted")
        try expectEq(pm.held.filter { $0.taskID == "1" }.count, 1, "one live entry (M1 held)")
    }

    // ===================================================================
    // M6 — sub-minute split: raw-short ⇒ terminal .skipped; trimmed-short ⇒
    // no row, re-billable once the covering slice is restored.
    // ===================================================================

    await c.check("M6: a RAW sub-minute session gets a terminal .skipped row (not re-billable)") {
        let store = try makeStore()
        store.clock = makeClock()
        let pm = FakeBackend(owns: .op)
        let m = Machine(store: store, backends: [(primaryPM, .pm, pm)])
        let tiny = session(.op(1), 0, 30)   // raw 30 s < 60 s
        try store.save(tiny); m.track(tiny)
        try await m.pass("sub-minute close-out", now: t(20000))
        try expectEq(m.cell(tiny.id, primaryPM)?.state, .skipped, "raw-short ⇒ terminal skipped")
        try expectEq(pm.created.count, 0, "nothing posted")
        // Terminal: a second pass never revisits it.
        try await m.pass("skip is terminal", now: t(20100))
        try expectEq(pm.created.count, 0)
        try expect(try store.sessions(needingPostTo: primaryPM, atOrAbove: 0.8).isEmpty,
                   "a terminal skip never re-enters the queue")
    }

    await c.check("M6: an OVERLAP-TRIMMED sub-minute session gets NO row and re-bills when coverage lifts") {
        let store = try makeStore()
        store.clock = makeClock()
        let pm = FakeBackend(owns: .op)
        let m = Machine(store: store, backends: [(primaryPM, .pm, pm)])
        // Raw span is a healthy hour, but a higher-authority synced slice
        // covers all but the last 30 s — the resolved contribution is < 60 s.
        let auto = session(.op(1), 0, 3600)
        try store.save(auto); m.track(auto)
        // The SAME covering slice id is applied then tombstoned — a fresh id
        // each time would leave the original cover in place and never restore.
        let cover = Session(id: UUID(), task: .op(2), start: t(0), end: t(3570), certainty: 1)
        try await m.mutate("higher-priority slice trims contribution to 30 s") {
            nowMillis += 10
            try store.applyRemote(SessionRevision(
                session: cover,
                hlc: HLC(physicalMillis: nowMillis, counter: 0, deviceID: "phone"),
                origin: .edited))
        }
        let contribution = try store.resolvedContribution(sessionID: auto.id)
        try expect((contribution?.seconds ?? 999) < 60, "the trimmed contribution really is sub-minute")
        try await m.pass("trimmed-short leaves no row", now: t(20000))
        try expectEq(pm.created.filter { $0.taskID == "1" }.count, 0, "trimmed-short posts nothing")
        try expectNil(m.cell(auto.id, primaryPM),
                      "trimmed-short ⇒ NO row (pending, releasable) — never a terminal skip")

        // Restore the covering slice's absence (tombstone the SAME id): the
        // full hour returns to op(1)'s contribution.
        try await m.mutate("covering slice deleted — contribution restored") {
            nowMillis += 10
            try store.applyRemote(SessionRevision(
                session: cover,
                hlc: HLC(physicalMillis: nowMillis, counter: 0, deviceID: "phone"),
                origin: .edited, deleted: true))
        }
        try await m.pass("restored contribution re-bills", now: t(20200))
        try expectEq(pm.created.filter { $0.taskID == "1" }.count, 1,
                     "the trimmed-short session finally bills once — re-billable, never stranded")
    }

    // ===================================================================
    // M7 — fail-closed: an unknown persisted state decodes as .posted AND
    // blocks SQL eligibility; a migration failure pauses the pass.
    // ===================================================================

    await c.check("M7: an unknown persisted state decodes .posted AND is fail-closed against re-posting") {
        // A newer build (or a synced-in row from one) writes a state string
        // this build doesn't know. Two directions must AGREE: the decoder
        // biases unknown → .posted (never-double-post), and the eligibility
        // SQL must equally treat it as blocking, or this build re-posts into
        // possibly-invoiced books. Only raw SQL can write an unknown state.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("andeyett-machine-unknown-\(UUID().uuidString).sqlite").path
        let store = try SQLiteJournalStore(path: path)
        store.clock = makeClock()
        let pm = FakeBackend(owns: .op)
        let m = Machine(store: store, backends: [(primaryPM, .pm, pm)])
        let s = session(.op(1), 0, 3600)
        try store.save(s); m.track(s)
        try await m.mutate("seed posted, then rewrite its state to an unknown future value") {
            try store.setPostingRecord(PostingRecord(sessionID: s.id, backendID: primaryPM,
                state: .posted, updatedAt: t(100)))
            var db: OpaquePointer?
            defer { sqlite3_close(db) }
            guard sqlite3_open(path, &db) == SQLITE_OK,
                  sqlite3_exec(db, "UPDATE posting_ledger SET state = 'some-future-state'",
                               nil, nil, nil) == SQLITE_OK else {
                throw CheckFailure(description: "raw state rewrite failed")
            }
        }
        try expectEq(m.cell(s.id, primaryPM)?.state, .posted, "decoder reads unknown → posted")
        try expectEq(try store.sessions(needingPostTo: primaryPM, atOrAbove: 0.8).count, 0,
                     "eligibility SQL blocks the unknown state, matching the decoder")
        try await m.pass("no re-post of an unknown-state cell", now: t(20000))
        try expectEq(pm.created.count, 0, "an unknown state never re-posts")
    }

    await c.check("M7: a migration failure PAUSES the whole pass — no truth, no posting") {
        // migrateSingleSlotPostings is re-asserted before every pass; if it
        // throws (disk-full at controller init left the launch-time migration
        // half-done, e.g.) the pass must return empty reports and post
        // NOTHING rather than run against a ledger it couldn't reconcile with
        // the legacy pushed flags. Driven with a store double whose migrate
        // throws; everything else forwards to a real in-memory journal.
        let inner = InMemoryJournalStore()
        let store = ThrowingMigrationStore(inner: inner)
        let pm = FakeBackend(owns: .op)
        let m = Machine(store: store, backends: [(primaryPM, .pm, pm)])
        // A perfectly eligible session that WOULD post if the pass ran.
        let s = session(.op(1), 0, 3600)
        try store.save(s); m.track(s)
        store.throwOnMigrate = true
        let reports = try await m.pass("migration throws", now: t(20000))
        // The pass short-circuits to a zeroed report per backend (no
        // reconcile/verify/amend/queue ran) — pausing, not half-running.
        try expect(reports.allSatisfy { $0.posted == 0 && $0.error == nil },
                   "a paused pass posts nothing and reports no per-backend work")
        try expectEq(pm.created.count, 0, "nothing posted while the migration cannot be asserted")
        try expectNil(m.cell(s.id, primaryPM), "no ledger truth was written")
        // Heal the migration: the very next pass runs normally and posts once.
        store.throwOnMigrate = false
        let ok = try await m.pass("migration heals", now: t(20100))
        try expectEq(ok.first?.posted, 1, "the paused work resumes cleanly once migration succeeds")
        try expectEq(pm.created.count, 1)
    }

    // ===================================================================
    // M8 — backend independence: one backend's cell never gates another's
    // eligibility; a session's pm and finance rows evolve independently.
    // ===================================================================

    await c.check("M8: a posted pm cell does not gate finance eligibility, and vice versa") {
        let journal = InMemoryJournalStore()
        let pm = FakeBackend(owns: .op)
        let finance = FakeBackend(owns: .nothing)   // finance routes by eligibility, not owns()
        let m = Machine(store: journal, backends: [(primaryPM, .pm, pm), ("fin-b", .finance, finance)])
        let s = session(.op(1), 0, 1800)
        try journal.save(s); m.track(s)

        // Pass 1: pm eligible, finance NOT (ineligible) — pm posts, finance is
        // pending with no row. The pm posted row must not hide the session
        // from finance later.
        try await m.pass("pm posts; finance ineligible", now: t(20000),
                         financeEligible: { _ in false })
        try expectEq(m.cell(s.id, primaryPM)?.state, .posted, "pm posted")
        try expectNil(m.cell(s.id, "fin-b"), "finance pending (no row) — not skipped, not blocked")

        // Pass 2: finance becomes eligible. The already-posted pm cell must
        // NOT gate it — finance posts independently, one row per backend.
        try await m.pass("finance now eligible; pm untouched", now: t(20100),
                         financeEligible: { _ in true })
        try expectEq(m.cell(s.id, "fin-b")?.state, .posted, "finance posted despite pm already posted")
        try expectEq(pm.created.count, 1, "the pm cell was not re-touched — idempotent, independent")
        try expectEq(finance.created.count, 1)
        try expectEq(pm.held.count, 1)
        try expectEq(finance.held.count, 1, "one live entry per backend — the cells are independent")

        // And the reverse direction, with a fresh session so finance can fail
        // its FIRST attempt (a real .failed cell, no live entry) while pm
        // posts cleanly: one backend's failure never gates or churns the other.
        let s2 = session(.op(2), 1800, 3600)
        try journal.save(s2); m.track(s2)
        try await m.mutate("finance will fail its first create") { finance.failNextCreates = 1 }
        try await m.pass("finance fails; pm posts independently", now: t(20200),
                         financeEligible: { _ in true })
        try expectEq(m.cell(s2.id, primaryPM)?.state, .posted, "pm posted despite finance failing")
        try expectEq(m.cell(s2.id, "fin-b")?.state, .failed, "finance cell failed — no entry, retryable")
        try expectEq(finance.held.filter { $0.taskID == "2" }.count, 0, "no live finance entry to double")
        // Finance heals next pass — posts exactly once; pm's cells never re-touched.
        let pmCreatesBefore = pm.created.count
        try await m.pass("finance heals; pm untouched", now: t(20300),
                         financeEligible: { _ in true })
        try expectEq(m.cell(s2.id, "fin-b")?.state, .posted, "finance retry healed")
        try expectEq(pm.created.count, pmCreatesBefore, "the finance retry never re-posted any pm cell")
    }

    // ===================================================================
    // M5 — mirror coherence (FIRST CLAUSE ONLY): after a normal successful
    // pass, the legacy pushedToOP/opTimeEntryID mirror equals the primary-pm
    // cell. The failed-mirror re-assert clause ("a best-effort mirror write
    // that failed is re-asserted by the next pass") is W2's — it needs a
    // markPushed-failure seam this harness does not yet have.
    // ===================================================================

    await c.check("M5 (first clause): after a normal pass the pushedToOP mirror equals the primary-pm cell") {
        let store = InMemoryJournalStore()
        let pm = FakeBackend(owns: .op)
        let m = Machine(store: store, backends: [(primaryPM, .pm, pm)])
        let s = session(.op(1), 0, 3600)
        try store.save(s); m.track(s)
        try await m.pass("normal successful pm pass", now: t(20000))
        let cell = try unwrap(m.cell(s.id, primaryPM))
        try expectEq(cell.state, .posted, "the cell posted")
        let mirrored = try unwrap(try store.session(id: s.id))
        // pushedToOP ⟺ posted, and opTimeEntryID == entryID.
        try expectEq(mirrored.pushedToOP, true, "mirror pushedToOP set ⟺ cell .posted")
        try expectEq(mirrored.opTimeEntryID, cell.entryID,
                     "mirror opTimeEntryID equals the cell's entry id")
        // Idempotent: a quiet second pass leaves the mirror in step.
        try await m.pass("quiet re-pass keeps the mirror coherent", now: t(20100))
        let again = try unwrap(try store.session(id: s.id))
        try expectEq(again.opTimeEntryID, m.cell(s.id, primaryPM)?.entryID)
    }
}

/// A JournalStore double whose `migrateSingleSlotPostings` can be made to
/// throw on demand (the only behaviour M7's migration-pause pin needs to
/// drive); every other call forwards to a real in-memory journal. Test-only —
/// it lives in the check module, not the production seam.
private final class ThrowingMigrationStore: JournalStore {
    struct MigrationFailure: Error {}
    let inner: InMemoryJournalStore
    var throwOnMigrate = false
    init(inner: InMemoryJournalStore) { self.inner = inner }

    func migrateSingleSlotPostings(to backendID: String, excluding: Set<UUID>) throws -> Int {
        if throwOnMigrate { throw MigrationFailure() }
        return try inner.migrateSingleSlotPostings(to: backendID, excluding: excluding)
    }

    // Straight forwarders.
    func save(_ session: Session) throws { try inner.save(session) }
    func allSessions() throws -> [Session] { try inner.allSessions() }
    func session(id: UUID) throws -> Session? { try inner.session(id: id) }
    func sessionCount() throws -> Int { try inner.sessionCount() }
    func pushedCount() throws -> Int { try inner.pushedCount() }
    func journalFootprint() throws -> (syncedBytes: Int, localDetailBytes: Int) { try inner.journalFootprint() }
    func sessions(from: Date, to: Date) throws -> [Session] { try inner.sessions(from: from, to: to) }
    func latestEndByTask(excluding: Set<UUID>) throws -> [TaskRef: Date] { try inner.latestEndByTask(excluding: excluding) }
    func sessions(needingPushAtOrAbove threshold: Double) throws -> [Session] { try inner.sessions(needingPushAtOrAbove: threshold) }
    func markPushed(_ id: UUID, opTimeEntryID: RemoteEntryID?) throws { try inner.markPushed(id, opTimeEntryID: opTimeEntryID) }
    func postingRecords(session: UUID) throws -> [PostingRecord] { try inner.postingRecords(session: session) }
    func postingRecord(session: UUID, backendID: String) throws -> PostingRecord? { try inner.postingRecord(session: session, backendID: backendID) }
    func setPostingRecord(_ record: PostingRecord) throws { try inner.setPostingRecord(record) }
    func clearPostingRecord(session: UUID, backendID: String) throws { try inner.clearPostingRecord(session: session, backendID: backendID) }
    func postingRecords(state: PostingState, backendID: String) throws -> [PostingRecord] { try inner.postingRecords(state: state, backendID: backendID) }
    func sessions(needingPostTo backendID: String, atOrAbove threshold: Double) throws -> [Session] { try inner.sessions(needingPostTo: backendID, atOrAbove: threshold) }
    func resolvedSessions(from: Date, to: Date) throws -> [Session] { try inner.resolvedSessions(from: from, to: to) }
    func resolvedContribution(sessionID: UUID) throws -> (start: Date, seconds: TimeInterval)? { try inner.resolvedContribution(sessionID: sessionID) }
    func sessionStamp(_ id: UUID) throws -> String? { try inner.sessionStamp(id) }
    func update(_ session: Session) throws { try inner.update(session) }
    func deleteSession(_ id: UUID) throws { try inner.deleteSession(id) }
    func escalateOrigin(_ id: UUID, to origin: SliceOrigin) throws { try inner.escalateOrigin(id, to: origin) }
    func save(_ segment: ReviewSegment) throws { try inner.save(segment) }
    func pendingReview() throws -> [ReviewSegment] { try inner.pendingReview() }
    func assign(_ segmentIDs: [UUID], to target: Target?) throws { try inner.assign(segmentIDs, to: target) }
    func reviewSegments(assignedTo target: Target) throws -> [ReviewSegment] { try inner.reviewSegments(assignedTo: target) }
    func save(_ span: FocusSpan) throws { try inner.save(span) }
    func spans(from: Date, to: Date) throws -> [FocusSpan] { try inner.spans(from: from, to: to) }
    func saveTaskComment(_ ref: TaskRef, text: String, at date: Date) throws { try inner.saveTaskComment(ref, text: text, at: date) }
    func taskComments(for ref: TaskRef) throws -> [(date: Date, text: String)] { try inner.taskComments(for: ref) }
    func unlockedInvoiceRefs(backendID: String) throws -> Set<String> { try inner.unlockedInvoiceRefs(backendID: backendID) }
    func addUnlockedInvoiceRef(_ ref: String, backendID: String) throws { try inner.addUnlockedInvoiceRef(ref, backendID: backendID) }
    func removeUnlockedInvoiceRef(_ ref: String, backendID: String) throws { try inner.removeUnlockedInvoiceRef(ref, backendID: backendID) }
    func saveRetroDigest(_ digest: RetroDigest) throws { try inner.saveRetroDigest(digest) }
    func retroDigests(limit: Int) throws -> [RetroDigest] { try inner.retroDigests(limit: limit) }
    func deleteRetroDigest(_ id: UUID) throws { try inner.deleteRetroDigest(id) }
}
