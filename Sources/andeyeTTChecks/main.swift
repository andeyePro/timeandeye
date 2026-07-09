import Foundation
import andeyeTTCore
import andeyeTTMac

// Suites register here as they are implemented (plan task order).

func checkpointRecoveryChecks(_ c: Checks) {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    func slice(_ task: TaskRef, _ from: TimeInterval, _ to: TimeInterval) -> Session {
        Session(task: task, start: t0.addingTimeInterval(from),
                end: t0.addingTimeInterval(to), certainty: 0.9)
    }

    c.check("nil stale -> nil") {
        try expectNil(CheckpointRecovery.recover(stale: nil, floor: 60, alreadyJournalled: []))
    }

    c.check("stale shorter than floor -> nil") {
        let stale = slice(.op(1), 0, 30)   // 30 s < 60 s floor
        try expectNil(CheckpointRecovery.recover(
            stale: stale, floor: 60, alreadyJournalled: []))
    }

    c.check("stale already covered by a same-task journalled slice -> nil") {
        // The switch flushed the old task's slice; the checkpoint still pointed
        // at the same span. Promoting it would duplicate the time + OP entry.
        let stale = slice(.op(1), 0, 600)
        let flushed = slice(.op(1), 0, 600)
        try expectNil(CheckpointRecovery.recover(
            stale: stale, floor: 60, alreadyJournalled: [flushed]))
    }

    c.check("PARTIAL same-task overlap -> only the un-journalled remainder is promoted (C18)") {
        // A flush covered the first 400s; the crash lost only 400..600. The
        // old rule promoted the WHOLE span (double-counting 0..400).
        let stale = slice(.op(1), 0, 600)
        let flushed = slice(.op(1), 0, 400)
        let recovered = CheckpointRecovery.recover(
            stale: stale, floor: 60, alreadyJournalled: [flushed])
        try expectEq(recovered?.start, t0.addingTimeInterval(400))
        try expectEq(recovered?.end, t0.addingTimeInterval(600))
        // Sub-floor remainder: nothing worth promoting.
        let mostlyFlushed = slice(.op(1), 0, 570)
        try expectNil(CheckpointRecovery.recover(
            stale: stale, floor: 60, alreadyJournalled: [mostlyFlushed]))
        // A middle overlap keeps the LARGEST remainder.
        let middle = slice(.op(1), 200, 260)
        let split = CheckpointRecovery.recover(
            stale: stale, floor: 60, alreadyJournalled: [middle])
        try expectEq(split?.start, t0.addingTimeInterval(260))
        try expectEq(split?.end, t0.addingTimeInterval(600))
    }

    c.check("genuine orphan >= floor, no overlap -> recovered") {
        let stale = slice(.op(1), 0, 600)
        let elsewhere = slice(.op(2), 1000, 1600)   // different task + time
        try expectEq(CheckpointRecovery.recover(
            stale: stale, floor: 60, alreadyJournalled: [elsewhere]), stale)
    }

    c.check("same span but DIFFERENT task -> recovered (not a duplicate)") {
        let stale = slice(.op(1), 0, 600)
        let other = slice(.op(2), 0, 600)
        try expectEq(CheckpointRecovery.recover(
            stale: stale, floor: 60, alreadyJournalled: [other]), stale)
    }
}
let suites: [(String, (Checks) -> Void)] = [
    ("Models", modelsChecks),
    ("OPURLParser", opURLParserChecks),
    ("LearningStore", learningStoreChecks),
    ("TaskRanker", taskRankerChecks),
    ("PinScope", pinScopeChecks),
    ("Predicate", predicateChecks),
    ("PredicateParser", predicateParserChecks),
    ("Attributor", attributorChecks),
    ("MinuteResolver", minuteResolverChecks),
    ("CheckpointRecovery", checkpointRecoveryChecks),
    ("SessionTracker", sessionTrackerChecks),
    ("EmailCapture", emailCaptureChecks),
    ("TimelineMath", timelineMathChecks),
    ("SpanAllocation", spanAllocationChecks),
    ("AndeyeLogo", andeyeLogoChecks),
    ("CommentRouting", commentRoutingChecks),
    ("FuzzyMatch", fuzzyMatchChecks),
    ("TimeAggregator", timeAggregatorChecks),
    ("JournalStore[InMemory]", inMemoryJournalChecks),
    ("JournalStore[SQLite]", sqliteJournalChecks),
    ("MenuTitle", menuTitleChecks),
    ("SupportDir", supportDirChecks),
    ("AIAssist", aiAssistChecks),
    ("Settings", settingsChecks),
    ("DuplicateReconcile", duplicateReconcileChecks),
    ("TimePeriod", timePeriodChecks),
    ("PieGeometry", pieGeometryChecks),
    ("SessionSticky", sessionStickyChecks),
    ("ContextIdentity", contextIdentityChecks),
    ("PinGrainMapping", pinGrainChecks),
    ("EmailRuleMetadata", emailRuleMetadataChecks),
    ("SurfaceFragment", surfaceFragmentChecks),
    ("CorrespondentFeatures", correspondentFeatureChecks),
    ("Forget", forgetChecks),
    ("CardDefaultGrain", cardDefaultGrainChecks),
    ("EmailGrainCommitMapping", emailGrainCommitMappingChecks),
    ("MultiCorrespondent", multiCorrespondentChecks),
    ("RulesLedger", rulesLedgerChecks),
    ("RulesLedgerExport", rulesLedgerExportChecks),
    ("CorrectionHistory", correctionHistoryChecks),
    ("TimesheetExport", timesheetExportChecks),
    ("JournalPrune", journalPruneChecks),
    ("HLC", hlcChecks),
    ("SessionSync", sessionSyncChecks),
    ("RevisionStore[InMemory]", { c in
        revisionStoreConformanceChecks(c, name: "InMemory") { InMemoryRevisionStore() }
    }),
    ("RevisionStore[SQLite]", { c in
        revisionStoreConformanceChecks(c, name: "SQLite") {
            let path = FileManager.default.temporaryDirectory
                .appendingPathComponent("andeyett-revs-\(UUID().uuidString).sqlite").path
            let store = try! SQLiteJournalStore(path: path)
            store.clock = HLCClock(deviceID: "mac")
            return store
        }
    }),
    ("SQLiteSyncStamping", sqliteSyncStampingChecks),
    ("License", licenseChecks),
    ("Billing", billingChecks),
    ("ColourEngine", colourEngineChecks),
    ("ReviewStack", reviewStackChecks),
    ("RetroAcceptance", retroAcceptanceChecks),
    ("ApprovalsDrawerAcceptance", approvalsDrawerAcceptanceChecks),
    ("UnknownTaskCategory", unknownSweepChecks),
    ("ReviewFloor", reviewFloorChecks),
    ("CalendarMatch", calendarMatchChecks),
    ("CalendarRankerTerm", calendarRankerTermChecks),
    ("CalendarPrecedence", calendarPrecedenceChecks),
    ("CalendarAlerts", calendarAlertChecks),
]
let asyncSuites: [(String, (Checks) async -> Void)] = [
    ("UndoStack", undoStackChecks),
    ("PhoneController", phoneControllerChecks),
    ("SyncEngineOwnership", syncEngineOwnershipChecks),
    ("JournalSyncer", journalSyncerChecks),
    ("OPClient", opClientChecks),
    ("SyncEngine", syncEngineChecks),
    ("SyncIdempotency", syncIdempotencyChecks),
    ("MultiBackendSync", multiBackendSyncChecks),
    ("ResolvedPosting", resolvedPostingChecks),
    ("EndToEnd", endToEndChecks),
]

var totalPassed = 0
var totalFailed = 0

for (name, suite) in suites {
    let c = Checks(name)
    suite(c)
    let (p, f) = c.finish()
    totalPassed += p
    totalFailed += f
}

// Top-level await (SE-0343) instead of a semaphore-blocked Task: blocking
// the main thread deadlocks any check that hops to the MainActor (the
// PhoneController suite does — its subject is @MainActor).
for (name, suite) in asyncSuites {
    let c = Checks(name)
    await suite(c)
    let (p, f) = c.finish()
    totalPassed += p
    totalFailed += f
}

print("TOTAL: \(totalPassed) passed, \(totalFailed) failed")
exit(totalFailed == 0 ? 0 : 1)
