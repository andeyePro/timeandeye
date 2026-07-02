import Foundation
import AmbitickCore
import AmbitickPhone

// Each controller gets its own temp data home and a settable clock.
private final class PhoneClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_750_000_000)
}

@MainActor
private func makeController(dir: URL? = nil) -> (PhoneController, PhoneClock, URL) {
    let clock = PhoneClock()
    let dataDir = dir ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("andeye-phone-\(UUID().uuidString)")
    let pc = PhoneController(dataDir: dataDir) { clock.now }
    return (pc, clock, dataDir)
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
}
