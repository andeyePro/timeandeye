import Foundation

// Suites register here as they are implemented (plan task order).
let suites: [(String, (Checks) -> Void)] = [
    ("Models", modelsChecks),
    ("OPURLParser", opURLParserChecks),
    ("LearningStore", learningStoreChecks),
    ("TaskRanker", taskRankerChecks),
    ("PinScope", pinScopeChecks),
    ("Predicate", predicateChecks),
    ("Attributor", attributorChecks),
    ("MinuteResolver", minuteResolverChecks),
    ("SessionTracker", sessionTrackerChecks),
    ("TimelineMath", timelineMathChecks),
    ("CommentRouting", commentRoutingChecks),
    ("FuzzyMatch", fuzzyMatchChecks),
    ("TimeAggregator", timeAggregatorChecks),
    ("JournalStore[InMemory]", inMemoryJournalChecks),
    ("JournalStore[SQLite]", sqliteJournalChecks),
    ("MenuTitle", menuTitleChecks),
    ("AIAssist", aiAssistChecks),
    ("Settings", settingsChecks),
]
let asyncSuites: [(String, (Checks) async -> Void)] = [
    ("OPClient", opClientChecks),
    ("SyncEngine", syncEngineChecks),
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

let semaphore = DispatchSemaphore(value: 0)
Task {
    for (name, suite) in asyncSuites {
        let c = Checks(name)
        await suite(c)
        let (p, f) = c.finish()
        totalPassed += p
        totalFailed += f
    }
    semaphore.signal()
}
semaphore.wait()

print("TOTAL: \(totalPassed) passed, \(totalFailed) failed")
exit(totalFailed == 0 ? 0 : 1)
