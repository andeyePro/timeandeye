import Foundation
import andeyeTTCore

// MARK: - Billable rules (project Bool + task tri-state, default non-billable)

func billingChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let projectKey = BillableRules.projectKey(backendID: "openproject", projectID: "14")

    c.check("DEFAULT NON-BILLABLE: an unflagged project can never be invoiced") {
        let rules = BillableRules()
        try expect(!rules.effectiveBillable(task: .op(1), projectKey: projectKey))
        try expect(!rules.effectiveBillable(task: .op(1), projectKey: nil),
                   "no project at all is non-billable too")
        try expect(!rules.financeEligible(task: .op(1), projectKey: projectKey,
                                          sessionStart: t0))
    }

    c.check("effective resolution: task override else project else non-billable") {
        var rules = BillableRules()
        rules.setProject(projectKey, billable: true, at: t0)
        try expect(rules.effectiveBillable(task: .op(1), projectKey: projectKey),
                   "inherit follows the project")
        rules.setTask(.op(1), state: .nonBillable, at: t0)
        try expect(!rules.effectiveBillable(task: .op(1), projectKey: projectKey),
                   "a manual non-billable override beats a billable project")
        rules.setTask(.op(2), state: .billable, at: t0)
        try expect(rules.effectiveBillable(task: .op(2), projectKey: nil),
                   "a manual billable override needs no project flag")
        rules.setTask(.op(1), state: .inherit, at: t0)
        try expectEq(rules.taskState(.op(1)), .inherit, "inherit clears the entry")
        try expect(rules.effectiveBillable(task: .op(1), projectKey: projectKey))
    }

    c.check("flips are prospective-only: sessions from before the billable flip never qualify") {
        var rules = BillableRules()
        rules.setProject(projectKey, billable: true, at: t0)
        try expect(!rules.financeEligible(task: .op(1), projectKey: projectKey,
                                          sessionStart: t0.addingTimeInterval(-600)),
                   "history behind a now-billable flag stays stranded")
        try expect(rules.financeEligible(task: .op(1), projectKey: projectKey,
                                         sessionStart: t0.addingTimeInterval(600)),
                   "time tracked after the flip posts")
        // Re-saving the same value must NOT re-gate history.
        rules.setProject(projectKey, billable: true, at: t0.addingTimeInterval(9_999))
        try expect(rules.financeEligible(task: .op(1), projectKey: projectKey,
                                         sessionStart: t0.addingTimeInterval(600)),
                   "same-value re-save keeps the original since")
        // Task-level override gates by its OWN since.
        rules.setTask(.op(9), state: .billable, at: t0.addingTimeInterval(1_000))
        try expect(!rules.financeEligible(task: .op(9), projectKey: nil,
                                          sessionStart: t0))
        try expect(rules.financeEligible(task: .op(9), projectKey: nil,
                                         sessionStart: t0.addingTimeInterval(2_000)))
    }

    c.check("personal tasks are excluded whatever the flags say — personal always wins") {
        var rules = BillableRules()
        let personal = TaskRef.local(UUID())
        rules.setTask(personal, state: .billable, at: t0)
        rules.setProject(BillableRules.localProjectKey("Personal"), billable: true, at: t0)
        try expect(!rules.financeEligible(task: personal,
                                          projectKey: BillableRules.localProjectKey("Personal"),
                                          sessionStart: t0.addingTimeInterval(600)),
                   ".local never reaches ANY backend, flags or no flags")
    }

    c.check("cascade left-behind: manually-set tasks are reported, never clobbered") {
        var rules = BillableRules()
        let tasks = [
            WorkTask(ref: .op(1), subject: "Inheriting A", project: "Alpha", status: "Now"),
            WorkTask(ref: .op(2), subject: "Manual billable", project: "Alpha", status: "Now"),
            WorkTask(ref: .op(3), subject: "Manual non-billable", project: "Alpha", status: "Open"),
        ]
        rules.setTask(.op(2), state: .billable, at: t0)
        rules.setTask(.op(3), state: .nonBillable, at: t0)
        // The toggle itself writes NO task rows — inheritance resolves at
        // read time, so the flag flip IS the cascade for inheriting tasks.
        rules.setProject(projectKey, billable: true, at: t0)
        let left = rules.manuallySetTasks(in: tasks)
        try expectEq(left.map(\.ref), [.op(2), .op(3)],
                     "count + list of tasks that kept their manual setting")
        try expect(rules.effectiveBillable(task: .op(1), projectKey: projectKey),
                   "inheriting task followed the project")
        try expect(!rules.effectiveBillable(task: .op(3), projectKey: projectKey),
                   "manual setting survived the cascade")
        try expectEq(rules.taskState(.op(2)), .billable, "overrides untouched")
    }

    c.check("title-keyed flags migrate to id keys once, preserving value and since; id key wins") {
        var rules = BillableRules()
        let titleKey = BillableRules.titleProjectKey(backendID: "openproject", title: "Alpha")
        rules.setProject(titleKey, billable: true, at: t0)
        let moved = rules.migrateProjectKeys([titleKey: projectKey])
        try expectEq(moved, 1)
        try expectNil(rules.projects[titleKey], "the title key is gone")
        try expectEq(rules.projects[projectKey]?.billable, true)
        try expectEq(rules.projects[projectKey]?.since, t0, "since survives (rename ≠ flip)")
        try expectEq(rules.migrateProjectKeys([titleKey: projectKey]), 0, "idempotent")
        // A populated id key is never clobbered by a stale title key.
        var clash = BillableRules()
        clash.setProject(titleKey, billable: true, at: t0)
        clash.setProject(projectKey, billable: false, at: t0.addingTimeInterval(60))
        clash.migrateProjectKeys([titleKey: projectKey])
        try expectEq(clash.projects[projectKey]?.billable, false, "existing id key wins")
    }

    c.check("stranded-hours arithmetic: confirmed, unposted, project-scoped, personal/short excluded") {
        func s(_ ref: TaskRef, minutes: Double, certainty: Double = 0.95) -> Session {
            Session(task: ref, start: t0, end: t0.addingTimeInterval(minutes * 60),
                    certainty: certainty)
        }
        let posted = s(.op(1), minutes: 30)
        let sessions = [
            s(.op(1), minutes: 60),                     // counts
            posted,                                     // posted to finance: not stranded
            s(.op(1), minutes: 0.5),                    // sub-minute: never posts anywhere
            s(.op(1), minutes: 45, certainty: 0.5),     // unconfirmed: not eligible
            s(.op(2), minutes: 90),                     // other project: out of scope
            s(.local(UUID()), minutes: 120),            // personal: never invoiced
        ]
        let stranded = Billing.strandedSeconds(sessions: sessions, tasks: [.op(1)],
                                               threshold: 0.8,
                                               postedSessionIDs: [posted.id])
        try expectEq(stranded, 3600, "exactly the one confirmed unposted hour")
    }

    c.check("currency: locale default, generic-sign fallback shape, override wins") {
        try expectEq(CurrencyDefault.symbol(for: Locale(identifier: "en_GB")), "£")
        try expectEq(CurrencyDefault.symbol(for: Locale(identifier: "en_US")), "$")
        var settings = AndeyeSettings(opBaseURL: "")
        try expectEq(settings.effectiveCurrencySymbol, CurrencyDefault.symbol(),
                     "nil override = the locale default")
        settings.currencySymbolOverride = "kr"
        try expectEq(settings.effectiveCurrencySymbol, "kr", "the ONE override field wins")
        settings.currencySymbolOverride = "   "
        try expectEq(settings.effectiveCurrencySymbol, CurrencyDefault.symbol(),
                     "blank override falls back")
    }

    c.check("billing rules persist through JSONFileStore like other user rules") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("andeyett-billing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONFileStore<BillableRules>(url: dir.appendingPathComponent("billing.json"))
        var rules = BillableRules()
        rules.setProject(projectKey, billable: true, at: t0)
        rules.setTask(.op(3), state: .nonBillable, at: t0)
        try store.save(rules)
        try expectEq(try store.load(), rules)
    }
}

// MARK: - Multi-backend fan-out (fake backends, both classes concurrently)

/// Configurable fake connector for the fan-out checks: records creates,
/// throws on demand, owns whichever ref kind it is told to.
final class FakeBackend: TaskBackend {
    enum Owns { case op, remote, nothing }
    struct Fail: Error {}

    private let ownsKind: Owns
    var created: [(taskID: String, duration: TimeInterval)] = []
    var deleted: [RemoteEntryID] = []
    /// Throw on the next N createTimeEntry calls (heals afterwards).
    var failNextCreates = 0
    /// Task ids the backend rejects PERMANENTLY (a deleted task, a frozen
    /// entry) — throws PermanentPostError, never heals.
    var permanentlyRejects: Set<String> = []

    init(owns: Owns) { self.ownsKind = owns }

    var displayName: String { "Fake" }
    var pageRecognizer: BackendPageRecognizer { NoPageRecognizer() }
    var supportsActivities: Bool { false }
    var supportsTaskComments: Bool { false }

    func owns(_ ref: TaskRef) -> Bool {
        switch ownsKind {
        case .op: if case .op = ref { return true }; return false
        case .remote: if case .remote = ref { return true }; return false
        case .nothing: return false
        }
    }

    func fetchTasks() async throws -> [WorkTask] { [] }
    func fetchMe() async throws -> String { "" }
    func fetchActivities() async throws -> [TimeActivity] { [] }
    func taskURL(id: String) -> URL? { nil }

    /// What the backend "holds" — returned by listTimeEntries so the
    /// inflight verify-then-adopt flows can be exercised.
    var held: [RemoteTimeEntry] = []

    func createTimeEntry(taskID: String, start: Date, duration: TimeInterval,
                         activityID: Int?, comment: String?) async throws -> RemoteEntryID? {
        if permanentlyRejects.contains(taskID) {
            throw PermanentPostError(reason: "fake: task \(taskID) is gone")
        }
        if failNextCreates > 0 { failNextCreates -= 1; throw Fail() }
        created.append((taskID, duration))
        let id = "fake-\(created.count)"
        held.append(RemoteTimeEntry(id: id, taskID: taskID, start: start,
                                    durationSeconds: duration, comment: comment))
        return id
    }

    func updateTimeEntry(id: RemoteEntryID, taskID: String, start: Date,
                         duration: TimeInterval, activityID: Int?, comment: String?) async throws {}
    func updateEntryComment(id: RemoteEntryID, comment: String) async throws {}
    func deleteTimeEntry(id: RemoteEntryID) async throws {
        deleted.append(id)
        held.removeAll { $0.id == id }
    }
    func listTimeEntries(from: Date, to: Date) async throws -> [RemoteTimeEntry] {
        held.filter { $0.start >= from && $0.start <= to }
    }
    func addTaskComment(taskID: String, text: String) async throws {}
}

func multiBackendSyncChecks(_ c: Checks) async {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func session(_ ref: TaskRef, offset: TimeInterval = 0,
                 minutes: Double = 30, certainty: Double = 0.95) -> Session {
        Session(task: ref, start: t0.addingTimeInterval(offset),
                end: t0.addingTimeInterval(offset + minutes * 60), certainty: certainty)
    }

    /// Billability used across these checks: op(1) is billable (flag since
    /// long before t0), everything else inherits non-billable.
    func billableRules() -> BillableRules {
        var rules = BillableRules()
        rules.setProject("pm-a/id:7", billable: true, at: t0.addingTimeInterval(-86_400))
        return rules
    }
    let projectKeys: [TaskRef: String] = [.op(1): "pm-a/id:7"]   // op(2) unflagged

    await c.check("TWO backends of DIFFERENT classes concurrently: pm gets all owned confirmed time, finance only the billable subset") {
        let journal = InMemoryJournalStore()
        let pm = FakeBackend(owns: .op)
        // The finance fake owns NOTHING: it still receiving billable time is
        // the proof that finance routing bypasses owns() — a registry that
        // only ever held one backend could not pass this check.
        let finance = FakeBackend(owns: .nothing)
        let registry = BackendRegistry()
        registry.register(pm, id: "pm-a", class: .pm)
        registry.register(finance, id: "fin-b", class: .finance)

        let billable = session(.op(1))
        let nonBillable = session(.op(2), offset: 3_600)
        let personal = session(.local(UUID()), offset: 7_200)
        for s in [billable, nonBillable, personal] { try journal.save(s) }

        let rules = billableRules()
        let engine = SyncEngine(journal: journal, backends: registry.entries)
        let reports = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                                financeEligible: {
            rules.financeEligible(task: $0.task, projectKey: projectKeys[$0.task],
                                  sessionStart: $0.start)
        })

        try expectEq(reports.count, 2, "one report per registered backend")
        try expectEq(reports.first { $0.backendID == "pm-a" }?.posted, 2,
                     "pm receives ALL owned confirmed time, billable or not")
        try expectEq(reports.first { $0.backendID == "fin-b" }?.posted, 1,
                     "finance receives ONLY the billable subset")
        try expectEq(Set(pm.created.map(\.taskID)), Set(["1", "2"]))
        try expectEq(finance.created.map(\.taskID), ["1"],
                     "the non-billable project is invisible to finance")
        // Personal time reached NEITHER backend, billable flags or not:
        // 2 pm creates + 1 finance create account for every request made.
        try expectEq(pm.created.count + finance.created.count, 3)
        // The SAME session is posted to both — one ledger row per backend.
        try expectEq(((try? journal.postingRecord(session: billable.id, backendID: "pm-a")) ?? nil)?.state,
                     .posted)
        try expectEq(((try? journal.postingRecord(session: billable.id, backendID: "fin-b")) ?? nil)?.state,
                     .posted)
        // The non-billable session: posted to pm, PENDING (no row) for
        // finance — never skipped, so opting the project in later posts only
        // NEW time (the since gate), and the ledger stays truthful.
        try expectNil((try? journal.postingRecord(session: nonBillable.id, backendID: "fin-b")) ?? nil)
        // Personal: no rows anywhere.
        try expectEq(try journal.postingRecords(session: personal.id).count, 0)
    }

    await c.check("ledger idempotency: a second pass posts nothing again") {
        let journal = InMemoryJournalStore()
        let pm = FakeBackend(owns: .op)
        let finance = FakeBackend(owns: .nothing)
        let entries = [RegisteredBackend(id: "pm-a", class: .pm, backend: pm),
                       RegisteredBackend(id: "fin-b", class: .finance, backend: finance)]
        try journal.save(session(.op(1)))
        let rules = billableRules()
        let eligible: (Session) -> Bool = {
            rules.financeEligible(task: $0.task, projectKey: projectKeys[$0.task],
                                  sessionStart: $0.start)
        }
        let engine = SyncEngine(journal: journal, backends: entries)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                      financeEligible: eligible)
        let again = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                              financeEligible: eligible)
        try expectEq(pm.created.count, 1, "retries can only update their own row")
        try expectEq(finance.created.count, 1)
        try expectEq(again.map(\.posted), [0, 0])
    }

    await c.check("failure isolation: one backend failing never blocks the other; retry heals") {
        let journal = InMemoryJournalStore()
        let pm = FakeBackend(owns: .op)
        pm.failNextCreates = 1
        let finance = FakeBackend(owns: .nothing)
        let entries = [RegisteredBackend(id: "pm-a", class: .pm, backend: pm),
                       RegisteredBackend(id: "fin-b", class: .finance, backend: finance)]
        let s = session(.op(1))
        try journal.save(s)
        let rules = billableRules()
        let eligible: (Session) -> Bool = {
            rules.financeEligible(task: $0.task, projectKey: projectKeys[$0.task],
                                  sessionStart: $0.start)
        }
        let engine = SyncEngine(journal: journal, backends: entries)
        let first = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                              financeEligible: eligible)
        try expect(first.first { $0.backendID == "pm-a" }?.error != nil,
                   "the pm failure is reported")
        try expectEq(first.first { $0.backendID == "fin-b" }?.posted, 1,
                     "finance still posted — pm's outage never blocks it")
        let pmRow = try unwrap(((try? journal.postingRecord(session: s.id, backendID: "pm-a")) ?? nil))
        try expectEq(pmRow.state, .failed)
        try expectEq(pmRow.attempts, 1)
        // Next pass: pm healed → posts exactly once; finance untouched.
        let second = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                               financeEligible: eligible)
        try expectEq(second.first { $0.backendID == "pm-a" }?.posted, 1)
        try expectEq(pm.created.count, 1)
        try expectEq(finance.created.count, 1, "the posted finance row is terminal")
    }

    await c.check("migration end-to-end: upgraded single-slot rows never re-post to pm, yet DO post to a new finance backend") {
        // The highest-risk upgrade path: a journal whose sessions were pushed
        // by the single-slot code (pushedToOP + entry id), now running the
        // registry engine with the pm backend registered under the migration
        // target id AND a brand-new finance backend alongside.
        let journal = InMemoryJournalStore()
        var pushed = session(.op(1))
        pushed.pushedToOP = true
        pushed.opTimeEntryID = "977"
        try journal.save(pushed)
        _ = try journal.migrateSingleSlotPostings(to: "pm-a", excluding: [])

        let pm = FakeBackend(owns: .op)
        let finance = FakeBackend(owns: .nothing)
        let entries = [RegisteredBackend(id: "pm-a", class: .pm, backend: pm),
                       RegisteredBackend(id: "fin-b", class: .finance, backend: finance)]
        // Billable since BEFORE the session, so it is finance-eligible.
        let rules = billableRules()
        let engine = SyncEngine(journal: journal, backends: entries)
        let reports = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                                financeEligible: {
            rules.financeEligible(task: $0.task, projectKey: projectKeys[$0.task],
                                  sessionStart: $0.start)
        })
        try expectEq(pm.created.count, 0,
                     "NO double-post to the pm backend after the upgrade")
        try expectEq(reports.first { $0.backendID == "pm-a" }?.posted, 0)
        try expectEq(finance.created.count, 1,
                     "posted-to-pm and pending-to-finance coexisted, then finance caught up")
        try expectEq(((try? journal.postingRecord(session: pushed.id, backendID: "pm-a")) ?? nil)?.entryID,
                     "977", "the migrated row kept the original entry id")
    }

    await c.check("a flip to non-billable marks a pending (failed) finance row skipped and stops future postings") {
        let journal = InMemoryJournalStore()
        let finance = FakeBackend(owns: .nothing)
        finance.failNextCreates = 1
        let entries = [RegisteredBackend(id: "fin-b", class: .finance, backend: finance)]
        let s = session(.op(1))
        try journal.save(s)
        var rules = billableRules()
        let engine = SyncEngine(journal: journal, backends: entries)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                      financeEligible: {
            rules.financeEligible(task: $0.task, projectKey: projectKeys[$0.task],
                                  sessionStart: $0.start)
        })
        try expectEq(((try? journal.postingRecord(session: s.id, backendID: "fin-b")) ?? nil)?.state,
                     .failed, "first attempt failed and is retryable")
        // The user flips the project non-billable: the retryable row is
        // closed off; nothing ever posts. Posted history (none here) is
        // never clawed back — flips are prospective only.
        rules.setProject("pm-a/id:7", billable: false, at: t0.addingTimeInterval(86_400))
        let after = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                              financeEligible: {
            rules.financeEligible(task: $0.task, projectKey: projectKeys[$0.task],
                                  sessionStart: $0.start)
        })
        try expectEq(after.first?.posted, 0)
        try expectEq(finance.created.count, 0, "the flip stopped the posting")
        try expectEq(((try? journal.postingRecord(session: s.id, backendID: "fin-b")) ?? nil)?.state,
                     .skipped, "the pending finance row is marked skipped")
    }

    await c.check("a PERMANENT rejection skips with its reason and never dams the queue (F19)") {
        let journal = InMemoryJournalStore()
        let pm = FakeBackend(owns: .op)
        pm.permanentlyRejects = ["1"]                     // op(1) was deleted at the backend
        let entries = [RegisteredBackend(id: "pm-a", class: .pm, backend: pm)]
        let head = session(.op(1))                        // earliest start = head of the queue
        let behind = session(.op(2), offset: 3_600)
        for s in [head, behind] { try journal.save(s) }

        let engine = SyncEngine(journal: journal, backends: entries)
        let report = (await engine.pushEligible(threshold: 0.8, includeComments: false)).first

        // The old behaviour broke the pass at the head's failure: op(2)
        // would NEVER post while op(1) kept failing. Now the head is closed
        // off and the session behind it posts in the SAME pass.
        try expectEq(report?.permanentlySkipped, 1)
        try expectEq(report?.posted, 1, "the queue proceeded past the rejection")
        try expectEq(pm.created.map(\.taskID), ["2"])
        let headRow = ((try? journal.postingRecord(session: head.id, backendID: "pm-a")) ?? nil)
        try expectEq(headRow?.state, .skipped)
        try expect(headRow?.lastError?.contains("gone") == true,
                   "the reason travels for Settings/report copy")
        // Terminal: a second pass retries nothing.
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false)
        try expectEq(pm.created.count, 1)
    }

    await c.check("a transient failure at the attempts cap is quarantined .stuck; the queue drains past it (F19)") {
        let journal = InMemoryJournalStore()
        let pm = FakeBackend(owns: .op)
        // Fails transiently exactly `cap` times — each pre-cap pass consumes
        // one failure at the head and correctly breaks (transient ordering
        // preserved: op(2) stays queued behind it).
        pm.failNextCreates = SyncEngine.transientAttemptsCap
        let entries = [RegisteredBackend(id: "pm-a", class: .pm, backend: pm)]
        let head = session(.op(1))
        let behind = session(.op(2), offset: 3_600)
        for s in [head, behind] { try journal.save(s) }

        let engine = SyncEngine(journal: journal, backends: entries)
        for _ in 0..<SyncEngine.transientAttemptsCap {
            _ = await engine.pushEligible(threshold: 0.8, includeComments: false)
        }
        // On the cap-th pass the head hit the cap, was quarantined, and the
        // queue proceeded: op(2) posted in that same pass.
        let headRow = ((try? journal.postingRecord(session: head.id, backendID: "pm-a")) ?? nil)
        try expectEq(headRow?.state, .stuck)
        try expectEq(headRow?.attempts, SyncEngine.transientAttemptsCap)
        try expectEq(pm.created.map(\.taskID), ["2"],
                     "the session behind the quarantined head posted")
        // Quarantine holds: another pass retries nothing…
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false)
        try expectEq(pm.created.count, 1)
        // …until the row is explicitly cleared (the repair/retry gesture).
        try journal.clearPostingRecord(session: head.id, backendID: "pm-a")
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false)
        try expectEq(pm.created.map(\.taskID), ["2", "1"], "clearing the row retries it")
    }

    await c.check("F15 backfill gate: finance skips sessions older than the floor — pending, not terminal; pm unaffected") {
        let journal = InMemoryJournalStore()
        let pm = FakeBackend(owns: .op)
        let finance = FakeBackend(owns: .nothing)
        let entries = [RegisteredBackend(id: "pm-a", class: .pm, backend: pm),
                       RegisteredBackend(id: "fin-b", class: .finance, backend: finance)]
        let old = session(.op(1), offset: -40 * 86_400)      // 40 days back
        let recent = session(.op(1))
        for s in [old, recent] { try journal.save(s) }
        var rules = BillableRules()
        rules.setProject("pm-a/id:7", billable: true, at: t0.addingTimeInterval(-90 * 86_400))
        let eligible: (Session) -> Bool = {
            rules.financeEligible(task: $0.task, projectKey: projectKeys[$0.task],
                                  sessionStart: $0.start)
        }
        let engine = SyncEngine(journal: journal, backends: entries)
        let floor = t0.addingTimeInterval(-14 * 86_400)
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                      financeEligible: eligible, financePostFloor: floor)
        try expectEq(pm.created.count, 2, "pm posts EVERYTHING it owns — the gate is finance-only")
        try expectEq(finance.created.count, 1, "finance posts only the recent session")
        try expectNil((try? journal.postingRecord(session: old.id, backendID: "fin-b")) ?? nil,
                      "the old session is PENDING (no row) — releasable, never terminal")
        // Deliberate release: lift the floor and the backlog posts.
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                      financeEligible: eligible, financePostFloor: nil)
        try expectEq(finance.created.count, 2, "released backlog posts exactly once")
    }

    await c.check("crash window with the entry landed: reconcile ADOPTS it — never a second create (F12/D3)") {
        let journal = InMemoryJournalStore()
        let pm = FakeBackend(owns: .op)
        let entries = [RegisteredBackend(id: "pm-a", class: .pm, backend: pm)]
        let s = session(.op(1))
        try journal.save(s)
        // Simulate the crash: the create reached the backend…
        let orphanID = try await pm.createTimeEntry(taskID: "1", start: s.start,
                                                    duration: s.end.timeIntervalSince(s.start),
                                                    activityID: nil, comment: nil)
        // …but the process died before the .posted write; only intent remains.
        try journal.setPostingRecord(PostingRecord(
            sessionID: s.id, backendID: "pm-a", state: .inflight, updatedAt: t0))

        let engine = SyncEngine(journal: journal, backends: entries)
        let report = (await engine.pushEligible(threshold: 0.8, includeComments: false,
                                                now: t0.addingTimeInterval(120))).first
        let row = ((try? journal.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)
        try expectEq(row?.state, .posted, "the orphan was adopted")
        try expectEq(row?.entryID, orphanID, "…under the entry id the backend already holds")
        try expectEq(pm.created.count, 1, "NO second create — the F12 duplicate is dead")
        try expectEq(report?.posted, 0, "an adopt is not a new post")
    }

    await c.check("crash window with NO entry landed: demoted and posted exactly once, same pass (F12/D3)") {
        let journal = InMemoryJournalStore()
        let pm = FakeBackend(owns: .op)
        let entries = [RegisteredBackend(id: "pm-a", class: .pm, backend: pm)]
        let s = session(.op(1))
        try journal.save(s)
        // Intent written, process died BEFORE the create reached the wire.
        try journal.setPostingRecord(PostingRecord(
            sessionID: s.id, backendID: "pm-a", state: .inflight, updatedAt: t0))

        let engine = SyncEngine(journal: journal, backends: entries)
        // Within the settle floor: untouched (the backend's list may lag).
        _ = await engine.pushEligible(threshold: 0.8, includeComments: false,
                                      now: t0.addingTimeInterval(30))
        try expectEq(pm.created.count, 0)
        try expectEq(((try? journal.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)?.state,
                     .inflight, "younger than the floor: wait, don't guess")
        // Past the floor: the verify confirms the miss, demotes to a clean
        // retry, and the SAME pass posts it — exactly once.
        let report = (await engine.pushEligible(threshold: 0.8, includeComments: false,
                                                now: t0.addingTimeInterval(120))).first
        try expectEq(report?.posted, 1)
        try expectEq(pm.created.count, 1, "exactly one create, ever")
        try expectEq(((try? journal.postingRecord(session: s.id, backendID: "pm-a")) ?? nil)?.state,
                     .posted)
    }
}
