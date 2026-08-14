import Foundation
import timeandeyeCore
import timeandeyePhone

// Each controller gets its own temp data home and a settable clock.
private final class PhoneClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_750_000_000)
}

@MainActor
private func makeController(dir: URL? = nil,
                            backend: (any TaskBackend)? = nil) -> (PhoneController, PhoneClock, URL) {
    let clock = PhoneClock()
    let dataDir = dir ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("andeye-phone-\(UUID().uuidString)")
    let pc = PhoneController(dataDir: dataDir, now: { clock.now }, backend: backend)
    return (pc, clock, dataDir)
}

/// Manufactures a slice that already lived through a successful `stop()`
/// push: journalled, `pushedToOP`/`opTimeEntryID` mirroring a `.posted`
/// ledger row, and the entry present at `fake` — the starting point every
/// banked-slice repair check needs, without driving the real sync engine.
@MainActor
@discardableResult
private func makePushedSession(_ pc: PhoneController, task: TaskRef, entryID: RemoteEntryID,
                               start: Date, minutes: Double = 30,
                               fake: FakeBackend) throws -> Session {
    let s = Session(task: task, start: start, end: start.addingTimeInterval(minutes * 60),
                    certainty: 1.0, pushedToOP: true, comment: nil,
                    opTimeEntryID: entryID, provenance: .userAssigned)
    try pc.journal.save(s)
    try pc.journal.setPostingRecord(PostingRecord(
        sessionID: s.id, backendID: OPBackend.stableID, state: .posted, entryID: entryID,
        postedStart: s.start, postedDuration: minutes * 60))
    fake.held.append(RemoteTimeEntry(id: entryID, taskID: task.backendTaskID ?? "",
                                     start: s.start, durationSeconds: minutes * 60))
    return s
}

func phoneControllerChecks(_ c: Checks) async {

    await c.check("start→stop under 30s is a tap, not a slice (nothing journalled)") {
        let (pc, clock, _) = await MainActor.run { makeController() }
        await MainActor.run {
            let ref = pc.addLocalTask(name: "Errand")
            pc.start(ref)
            clock.now += 10
            pc.stop()
        }
        let saved = try await MainActor.run {
            try pc.journal.sessions(from: clock.now - 3600, to: clock.now + 3600)
        }
        try expectEq(saved.count, 0, "10-second taps are discarded")
    }

    await c.check("start→stop over 30s journals a manual slice") {
        let (pc, clock, _) = await MainActor.run { makeController() }
        let ref = await MainActor.run { pc.addLocalTask(name: "Site visit") }
        await MainActor.run { pc.start(ref) }
        await MainActor.run { clock.now += 600; pc.stop() }
        let saved = try await MainActor.run {
            try pc.journal.sessions(from: clock.now - 3600, to: clock.now + 3600)
        }
        try expectEq(saved.count, 1)
        try expectEq(saved[0].task, ref)
        try expectEq(saved[0].end.timeIntervalSince(saved[0].start), 600)
        // origin=.manual lives in the sync-revision layer (escalateOrigin is a
        // no-op on non-replica stores), so it isn't asserted here.
    }

    await c.check("a live slice survives app death and resumes on relaunch") {
        let (pc, clock, dir) = await MainActor.run { makeController() }
        let ref = await MainActor.run { pc.addLocalTask(name: "Long call") }
        await MainActor.run {
            pc.start(ref)
            clock.now += 300
            pc.appLifecycleTick()   // background hook refreshed the checkpoint
        }
        // App dies here (no stop). A NEW controller on the same data home:
        let (pc2, _, _) = await MainActor.run { makeController(dir: dir) }
        let tracking = await MainActor.run { pc2.tracking }
        let resumed = try unwrap(tracking, "relaunch resumes the live slice")
        try expectEq(resumed.task, ref)
    }

    await c.check("switching tasks is stop + start (first slice banked)") {
        let (pc, clock, _) = await MainActor.run { makeController() }
        let a = await MainActor.run { pc.addLocalTask(name: "Task A") }
        let b = await MainActor.run { pc.addLocalTask(name: "Task B") }
        await MainActor.run { pc.start(a) }
        await MainActor.run { clock.now += 120; pc.start(b) }
        let (saved, tracking) = try await MainActor.run {
            (try pc.journal.sessions(from: clock.now - 3600, to: clock.now + 3600)
                .filter { $0.id != PhoneController.liveCheckpointID },   // B's live checkpoint
             pc.tracking)
        }
        try expectEq(saved.count, 1, "the A slice banked when B started")
        try expectEq(saved[0].task, a)
        try expectEq(try unwrap(tracking).task, b)
    }

    await c.check("tapping the tracked task is a no-op (same slice keeps running)") {
        let (pc, clock, _) = await MainActor.run { makeController() }
        let ref = await MainActor.run { pc.addLocalTask(name: "Deep work") }
        let started = await MainActor.run { pc.start(ref); return pc.tracking?.since }
        await MainActor.run { clock.now += 120; pc.start(ref) }
        let (tracking, banked) = try await MainActor.run {
            (pc.tracking,
             try pc.journal.sessions(from: clock.now - 3600, to: clock.now + 3600)
                .filter { $0.id != PhoneController.liveCheckpointID })
        }
        try expectEq(try unwrap(tracking).since, try unwrap(started),
                     "the running slice keeps its original start")
        try expectEq(banked.count, 0, "no slice banked, no restart")
    }

    await c.check("relabelCurrent moves the running slice, keeping its start") {
        let (pc, clock, _) = await MainActor.run { makeController() }
        let a = await MainActor.run { pc.addLocalTask(name: "Task A") }
        let b = await MainActor.run { pc.addLocalTask(name: "Task B") }
        let started = clock.now
        await MainActor.run { pc.start(a) }
        await MainActor.run { clock.now += 300; pc.relabelCurrent(to: b) }
        let (tracking, checkpoint, banked) = try await MainActor.run {
            (pc.tracking,
             try pc.journal.session(id: PhoneController.liveCheckpointID),
             try pc.journal.sessions(from: clock.now - 3600, to: clock.now + 3600)
                .filter { $0.id != PhoneController.liveCheckpointID })
        }
        let live = try unwrap(tracking, "still tracking after relabel")
        try expectEq(live.task, b)
        try expectEq(live.since, started, "start time preserved")
        let cp = try unwrap(checkpoint, "checkpoint row exists")
        try expectEq(cp.task, b, "checkpoint follows the new label")
        try expectEq(cp.start, started)
        try expectEq(banked.count, 0, "relabel banks nothing")
        // The whole span lands on B when the slice eventually stops.
        await MainActor.run { clock.now += 300; pc.stop() }
        let saved = try await MainActor.run {
            try pc.journal.sessions(from: started - 1, to: clock.now + 1)
        }
        try expectEq(saved.count, 1)
        try expectEq(saved[0].task, b)
        try expectEq(saved[0].end.timeIntervalSince(saved[0].start), 600)
    }

    await c.check("relabelCurrent with nothing running is a no-op") {
        let (pc, _, _) = await MainActor.run { makeController() }
        let a = await MainActor.run { pc.addLocalTask(name: "Task A") }
        await MainActor.run { pc.relabelCurrent(to: a) }
        let (tracking, checkpoint) = try await MainActor.run {
            (pc.tracking, try pc.journal.session(id: PhoneController.liveCheckpointID))
        }
        try expectNil(tracking)
        try expectNil(checkpoint, "no checkpoint row minted")
    }

    await c.check("spentNodes: banked + live under the local project, checkpoint excluded") {
        let (pc, clock, _) = await MainActor.run { makeController() }
        let a = await MainActor.run { pc.addLocalTask(name: "Task A") }
        let b = await MainActor.run { pc.addLocalTask(name: "Task B") }
        await MainActor.run { pc.start(a) }
        await MainActor.run { clock.now += 600; pc.stop() }     // banked 600
        await MainActor.run { pc.start(b); clock.now += 60 }    // live 60
        let nodes = await MainActor.run {
            pc.spentNodes(from: clock.now - 3600, to: clock.now + 1)
        }
        try expectEq(nodes.count, 1, "local tasks group under one project")
        try expectEq(nodes[0].label, "Personal")
        try expectEq(nodes[0].seconds, 660, "banked + live, no checkpoint double-count")
        try expectEq(nodes[0].children.count, 2)
        try expectEq(nodes[0].children[0].label, "Task A")   // sorted by seconds
        try expectEq(nodes[0].children[1].seconds, 60)
    }

    await c.check("bankedSessions: start-ordered, live checkpoint excluded") {
        let (pc, clock, _) = await MainActor.run { makeController() }
        let a = await MainActor.run { pc.addLocalTask(name: "Task A") }
        await MainActor.run { pc.start(a) }
        await MainActor.run { clock.now += 600; pc.stop() }
        await MainActor.run { pc.start(a); pc.appLifecycleTick() }   // live checkpoint exists
        let sessions = await MainActor.run {
            pc.bankedSessions(from: clock.now - 3600, to: clock.now + 3600)
        }
        try expectEq(sessions.count, 1, "only the banked slice")
        try expectEq(sessions[0].task, a)
    }

    await c.check("addLocalTask dedupes case-insensitively") {
        let (pc, _, _) = await MainActor.run { makeController() }
        let first = await MainActor.run { pc.addLocalTask(name: "Admin") }
        let second = await MainActor.run { pc.addLocalTask(name: "  admin ") }
        try expectEq(first, second, "same task, not a duplicate")
        let count = await MainActor.run { pc.settings.localTasks.count }
        try expectEq(count, 1)
    }

    await c.check("pickList filters fuzzily and includes local tasks") {
        let (pc, _, _) = await MainActor.run { makeController() }
        _ = await MainActor.run { pc.addLocalTask(name: "Greenhouse build") }
        _ = await MainActor.run { pc.addLocalTask(name: "Accounts") }
        let all = await MainActor.run { pc.pickList() }
        try expectEq(all.count, 2)
        let filtered = await MainActor.run { pc.pickList(filter: "grn") }
        try expectEq(filtered.count, 1)
        try expectEq(filtered[0].subject, "Greenhouse build")
    }

    await c.check("todaysTotal = banked slices + the live slice, checkpoint excluded") {
        let (pc, clock, _) = await MainActor.run { makeController() }
        let ref = await MainActor.run { pc.addLocalTask(name: "Work") }
        await MainActor.run { pc.start(ref) }
        await MainActor.run { clock.now += 600; pc.stop() }        // banked 600
        await MainActor.run { pc.start(ref); clock.now += 60 }     // live 60
        let total = await MainActor.run { pc.todaysTotal() }
        try expectEq(total, 660)
    }

    await c.check("timesheetCSV exports the week with task names, no checkpoint row") {
        let (pc, clock, _) = await MainActor.run { makeController() }
        let ref = await MainActor.run { pc.addLocalTask(name: "Client visit") }
        await MainActor.run { pc.start(ref) }
        await MainActor.run { clock.now += 3600; pc.stop() }
        await MainActor.run { pc.start(ref); pc.appLifecycleTick() }   // live checkpoint exists
        let csv = await MainActor.run { pc.timesheetCSV() }
        try expect(csv.contains("Client visit"), "task name resolved in the export")
        let dataRows = csv.split(separator: "\n").dropFirst()
        try expectEq(dataRows.count, 1, "one banked slice; the live checkpoint is excluded")
    }

    // MARK: - Banked-slice repair (reassign / adjust / delete)

    await c.check("reassign with no backend rewrites task/certainty/provenance and unlinks") {
        let (pc, clock, _) = await MainActor.run { makeController() }
        let a = TaskRef.op(1)
        let b = TaskRef.op(2)
        let original = Session(task: a, start: clock.now, end: clock.now.addingTimeInterval(1_800),
                               certainty: 0.4, provenance: SessionProvenance(sourceRaw: "opTaskTitle"))
        try await MainActor.run { try pc.journal.save(original) }
        await pc.reassign(sessionID: original.id, to: b)
        let saved = try await MainActor.run { try unwrap(try pc.journal.session(id: original.id)) }
        try expectEq(saved.task, b, "task rewritten")
        try expectEq(saved.certainty, Attributor.humanWord, "human-word certainty")
        try expectEq(saved.provenance, SessionProvenance.userAssigned)
        try expectNil(saved.opTimeEntryID, "unlinked — nothing was ever pushed")
        try expectEq(saved.pushedToOP, false)
    }

    await c.check("reassign of a pushed slice retracts the OLD entry and the next push creates under the new task") {
        let fake = FakeBackend(owns: .op)
        let (pc, clock, _) = await MainActor.run { makeController(backend: fake) }
        let a = TaskRef.op(1)
        let b = TaskRef.op(2)
        let s = try await MainActor.run {
            try makePushedSession(pc, task: a, entryID: "old-1", start: clock.now, fake: fake)
        }
        await pc.reassign(sessionID: s.id, to: b)
        try expectEq(fake.deleted, ["old-1"], "exactly one delete, for the OLD entry")
        try expectEq(fake.created.count, 1, "the next push created one entry")
        try expectEq(fake.created[0].taskID, "2", "created under the new task")
    }

    await c.check("an invoice-locked cell makes zero remote calls on reassign/adjust/delete and parks .diverged") {
        // WHY three slices in one check: the criterion is one law (the lock
        // law) proven across all three repair paths — splitting it into
        // three checks would triple the setup for the same assertion shape.
        let fake = FakeBackend(owns: .op)
        let (pc, clock, _) = await MainActor.run { makeController(backend: fake) }
        let a = TaskRef.op(1)
        let b = TaskRef.op(2)

        func lock(_ sessionID: UUID, ref: String) async throws {
            try await MainActor.run {
                var row = try unwrap(try pc.journal.postingRecord(session: sessionID, backendID: OPBackend.stableID))
                row.lockedInvoiceRef = ref
                try pc.journal.setPostingRecord(row)
            }
        }
        func cellState(_ sessionID: UUID) async throws -> PostingState {
            try await MainActor.run {
                try unwrap(try pc.journal.postingRecord(session: sessionID, backendID: OPBackend.stableID)).state
            }
        }

        let sr = try await MainActor.run {
            try makePushedSession(pc, task: a, entryID: "locked-r", start: clock.now, fake: fake)
        }
        try await lock(sr.id, ref: "INV-1")
        await pc.reassign(sessionID: sr.id, to: b)
        let savedR = try await MainActor.run { try unwrap(try pc.journal.session(id: sr.id)) }
        try expectEq(savedR.task, b, "local reassign stands even though billed")
        try expectEq(try await cellState(sr.id), .diverged)

        let sa = try await MainActor.run {
            try makePushedSession(pc, task: a, entryID: "locked-a", start: clock.now, fake: fake)
        }
        try await lock(sa.id, ref: "INV-2")
        let newEnd = sa.end.addingTimeInterval(600)
        await pc.adjust(sessionID: sa.id, start: sa.start, end: newEnd)
        let savedA = try await MainActor.run { try unwrap(try pc.journal.session(id: sa.id)) }
        try expectEq(savedA.end, newEnd, "local resize stands even though billed")
        try expectEq(try await cellState(sa.id), .diverged)

        let sd = try await MainActor.run {
            try makePushedSession(pc, task: a, entryID: "locked-d", start: clock.now, fake: fake)
        }
        try await lock(sd.id, ref: "INV-3")
        await pc.deleteSlice(sessionID: sd.id)
        let savedD = try await MainActor.run { try pc.journal.session(id: sd.id) }
        try expectNil(savedD, "local delete stands even though billed")
        try expectEq(try await cellState(sd.id), .diverged)

        try expectEq(fake.created.count, 0, "zero remote creates")
        try expectEq(fake.updated.count, 0, "zero remote updates")
        try expectEq(fake.deleted.count, 0, "zero remote deletes")
    }

    await c.check("a failing remote delete leaves the entryID intact and marks the row .failed") {
        let fake = FakeBackend(owns: .op)
        let (pc, clock, _) = await MainActor.run { makeController(backend: fake) }
        let a = TaskRef.op(1)
        let s = try await MainActor.run {
            try makePushedSession(pc, task: a, entryID: "flaky-1", start: clock.now, fake: fake)
        }
        fake.failNextDeletes = 1
        await pc.deleteSlice(sessionID: s.id)
        let cell = try await MainActor.run {
            try pc.journal.postingRecord(session: s.id, backendID: OPBackend.stableID)
        }
        let row = try unwrap(cell, "the row survives a failed delete")
        try expectEq(row.state, .failed)
        try expectEq(row.entryID, "flaky-1", "entryID retained — never orphan the live entry")
        try expectEq(row.lastError, PostingSever.retractIntentReason)
        let savedSession = try await MainActor.run { try pc.journal.session(id: s.id) }
        try expectNil(savedSession, "the local delete still stands")
    }

    await c.check("adjust issues exactly one updateTimeEntry with the new start and duration") {
        let fake = FakeBackend(owns: .op)
        let (pc, clock, _) = await MainActor.run { makeController(backend: fake) }
        let a = TaskRef.op(1)
        let s = try await MainActor.run {
            try makePushedSession(pc, task: a, entryID: "adj-1", start: clock.now, fake: fake)
        }
        let newStart = s.start.addingTimeInterval(600)
        let newEnd = s.end.addingTimeInterval(1_200)
        await pc.adjust(sessionID: s.id, start: newStart, end: newEnd)
        try expectEq(fake.updated.count, 1)
        let call = try unwrap(fake.updated.first)
        try expectEq(call.id, "adj-1")
        try expectEq(call.start, newStart)
        try expectEq(call.duration, newEnd.timeIntervalSince(newStart))
        let saved = try await MainActor.run { try unwrap(try pc.journal.session(id: s.id)) }
        try expectEq(saved.start, newStart)
        try expectEq(saved.end, newEnd)
    }

    await c.check("a sub-minute handled slice grown past 60s re-enters the push queue") {
        let fake = FakeBackend(owns: .op)
        let (pc, clock, _) = await MainActor.run { makeController(backend: fake) }
        let a = TaskRef.op(1)
        // Handled-without-an-entry: pushedToOP true, no opTimeEntryID, a
        // .skipped ledger row (the sub-minute posting-floor shape).
        let s = Session(task: a, start: clock.now, end: clock.now.addingTimeInterval(40),
                        certainty: 1.0, pushedToOP: true)
        try await MainActor.run {
            try pc.journal.save(s)
            try pc.journal.setPostingRecord(PostingRecord(sessionID: s.id, backendID: OPBackend.stableID,
                                                           state: .skipped))
        }
        await pc.adjust(sessionID: s.id, start: s.start, end: s.start.addingTimeInterval(90))
        let saved = try await MainActor.run { try unwrap(try pc.journal.session(id: s.id)) }
        try expectEq(saved.pushedToOP, false, "re-enters the queue")
        let eligible = try await MainActor.run {
            try pc.journal.sessions(needingPostTo: OPBackend.stableID, atOrAbove: 0.8)
        }
        try expect(eligible.contains { $0.id == s.id }, "the grown slice is eligible again")
        let cell = try await MainActor.run {
            try pc.journal.postingRecord(session: s.id, backendID: OPBackend.stableID)
        }
        try expectNil(cell, "the skipped ledger row was dropped")
    }

    await c.check("reassign/adjust/deleteSlice are no-ops on the live checkpoint id") {
        let fake = FakeBackend(owns: .op)
        let (pc, clock, _) = await MainActor.run { makeController(backend: fake) }
        let ref = await MainActor.run { pc.addLocalTask(name: "Live task") }
        await MainActor.run { pc.start(ref) }
        let before = try await MainActor.run {
            try unwrap(try pc.journal.session(id: PhoneController.liveCheckpointID))
        }
        await pc.reassign(sessionID: PhoneController.liveCheckpointID, to: .op(9))
        await pc.adjust(sessionID: PhoneController.liveCheckpointID, start: clock.now,
                        end: clock.now.addingTimeInterval(120))
        await pc.deleteSlice(sessionID: PhoneController.liveCheckpointID)
        let after = try await MainActor.run { try pc.journal.session(id: PhoneController.liveCheckpointID) }
        let stillThere = try unwrap(after, "checkpoint row survives — deleteSlice was a no-op, not a crash")
        try expectEq(stillThere.task, before.task)
        try expectEq(stillThere.start, before.start)
        try expectEq(fake.created.count, 0)
        try expectEq(fake.updated.count, 0)
        try expectEq(fake.deleted.count, 0)
    }

    await c.check("deleteSlice removes the row from bankedSessions, spentNodes and todaysTotal") {
        let (pc, clock, _) = await MainActor.run { makeController() }
        let ref = await MainActor.run { pc.addLocalTask(name: "Vanishing task") }
        await MainActor.run { pc.start(ref) }
        await MainActor.run { clock.now += 600; pc.stop() }
        let saved = try await MainActor.run {
            try pc.journal.sessions(from: clock.now - 3_600, to: clock.now + 3_600)
                .filter { $0.id != PhoneController.liveCheckpointID }
        }
        let s = try unwrap(saved.first)
        await pc.deleteSlice(sessionID: s.id)
        let (banked, nodes, total) = await MainActor.run {
            (pc.bankedSessions(from: clock.now - 3_600, to: clock.now + 3_600),
             pc.spentNodes(from: clock.now - 3_600, to: clock.now + 3_600),
             pc.todaysTotal())
        }
        try expectEq(banked.count, 0, "gone from bankedSessions")
        try expectEq(nodes.count, 0, "gone from spentNodes")
        try expectEq(total, 0, "gone from todaysTotal")
    }

    await c.check("a failed save holds the slice; retry lands it, then releases the checkpoint") {
        // Save-before-clear (post-flip TODO item, built 2026-08-14): a hard
        // SQLite failure at stop() must lose NOTHING — the slice re-stages
        // for retry and the crash checkpoint (the only durable copy) stays
        // until the save has genuinely landed.
        let clock = PhoneClock()
        let store = InMemoryJournalStore()
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("andeye-phone-\(UUID().uuidString)")
        let pc = await MainActor.run {
            PhoneController(dataDir: dataDir, now: { clock.now }, journal: store)
        }
        let checkpointID = await MainActor.run { PhoneController.liveCheckpointID }
        let ref = await MainActor.run { pc.addLocalTask(name: "Client day") }
        await MainActor.run {
            pc.start(ref)
            clock.now += 3_600
            store.failNextSaves = 1
            pc.stop()
        }
        let after = try store.sessions(from: clock.now - 7_200, to: clock.now + 60)
            .filter { $0.id != checkpointID }
        try expectEq(after.count, 0, "the save genuinely failed")
        try expect(try store.session(id: checkpointID) != nil,
                   "checkpoint must survive a failed save")
        await MainActor.run { pc.appLifecycleTick() }   // store healed → retry lands
        let landed = try store.sessions(from: clock.now - 7_200, to: clock.now + 60)
            .filter { $0.id != checkpointID }
        try expectEq(landed.count, 1, "the held slice lands on retry")
        try expectEq(landed.first?.task, ref)
        try expectNil(try store.session(id: checkpointID),
                      "checkpoint releases only after the slice landed")
    }
}
