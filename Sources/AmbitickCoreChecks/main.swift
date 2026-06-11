import Foundation

// Suites register here as they are implemented (plan task order).
let suites: [(String, (Checks) -> Void)] = [
    ("Models", modelsChecks),
    ("OPURLParser", opURLParserChecks),
    ("LearningStore", learningStoreChecks),
    ("TaskRanker", taskRankerChecks),
]
let asyncSuites: [(String, (Checks) async -> Void)] = []

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
