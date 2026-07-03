# Ambitick Core Implementation Plan

> Historical record: "Ambitick" was the working name — the app is now **andeyeTT** (user-facing brand "andeye"; see `docs/superpowers/specs/2026-07-02-andeye-rename-plan.md`). Module/file names below are the pre-rename ones (Ambitick* → AndeyeTT*).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `AmbitickCore` – the pure-Swift, platform-independent heart of Ambitick (models, attribution, learning, session tracking, journal, OpenProject client, sync, AI-assist, settings) – fully covered by `swift test`.

**Architecture:** Single SPM package, one library target `AmbitickCore` with zero non-Foundation dependencies, one test target. Sensors and UI are NOT in this plan (Plan 2: `2026-06-10-ambitick-macos-app.md`, written after Core lands). Storage is a `JournalStore` protocol with an in-memory implementation here; the GRDB/SQLite implementation arrives in Plan 2 on the Mac side and must pass the conformance test suite defined here.

**Tech Stack:** Swift 5.10+ (`// swift-tools-version:5.10`), Foundation only (+ FoundationNetworking on Linux), XCTest, GitHub Actions (`swift:6.1` container on `ubuntu-latest`).

**Verification model (read first):** This container has NO Swift toolchain and cannot install one (download.swift.org firewalled, apt blocked). Tests are still written FIRST in every task, but red/green runs happen remotely:
- After each task's commit, push and check CI: `git push && gh run watch --exit-status` (if `gh run` is blocked by PAT scope, ask Martin to check Actions, or to run `swift test` on his Mac).
- The `Run:` lines below give the command and expected result as they will appear on CI/Mac. Do not claim a task verified until a CI run (or Martin) has confirmed it.
- If the very first push of `.github/workflows/ci.yml` is rejected (`refusing to allow a Personal Access Token to create or update workflow`), hand the file to Martin to commit from his Mac, and keep pushing only source after that.

**Spec:** `docs/superpowers/specs/2026-06-10-ambitick-design.md`

---

## File structure

```
Package.swift
.github/workflows/ci.yml
README.md                              (stub; full setup docs in Plan 2)
Sources/AmbitickCore/
  Models.swift          TaskRef, Target, WorkTask, ActivitySignal, SensorEvent,
                        Surface, FocusSpan, Session, ReviewSegment
  OPURLParser.swift     task id extraction from OP URLs
  LearningStore.swift   feature extraction + naive-Bayes-style scoring
  TaskRanker.swift      status/recency/time-of-day ranking + pick lists
  Attributor.swift      signal → target scoring incl. OP task-priming
  MinuteResolver.swift  dominant-task-per-minute resolution
  SessionTracker.swift  the state machine: events in, sessions/review/prompts out
  JournalStore.swift    protocol + InMemoryJournalStore
  OPClient.swift        OpenProject v3 API client over an HTTPTransport protocol
  SyncEngine.swift      threshold-gated push of sessions to OP
  AIAssist.swift        classification prompt builder + strict JSON response parser
  Settings.swift        AmbitickSettings + generic JSONFileStore
Tests/AmbitickCoreTests/
  (one XXXTests.swift per source file, plus EndToEndTests.swift)
```

---

### Task 1: Package scaffold, CI, README stub

**Files:**
- Create: `Package.swift`
- Create: `Sources/AmbitickCore/Models.swift` (placeholder, replaced in Task 2)
- Create: `Tests/AmbitickCoreTests/ModelsTests.swift` (placeholder, replaced in Task 2)
- Create: `.github/workflows/ci.yml`
- Modify: `README.md`

- [ ] **Step 1: Create Package.swift**

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Ambitick",
    products: [
        .library(name: "AmbitickCore", targets: ["AmbitickCore"])
    ],
    targets: [
        .target(name: "AmbitickCore"),
        .testTarget(name: "AmbitickCoreTests", dependencies: ["AmbitickCore"]),
    ]
)
```

- [ ] **Step 2: Create placeholder source + smoke test**

`Sources/AmbitickCore/Models.swift`:

```swift
import Foundation

public enum Ambitick {
    public static let version = "0.1.0"
}
```

`Tests/AmbitickCoreTests/ModelsTests.swift`:

```swift
import XCTest
@testable import AmbitickCore

final class ModelsTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(Ambitick.version, "0.1.0")
    }
}
```

- [ ] **Step 3: Create CI workflow**

`.github/workflows/ci.yml`:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
jobs:
  linux-tests:
    runs-on: ubuntu-latest
    container: swift:6.1
    steps:
      - uses: actions/checkout@v4
      - run: swift test
```

- [ ] **Step 4: README stub**

Replace `README.md` content with:

```markdown
# Ambitick

Automatic time tracking for OpenProject. macOS menu-bar app; pure-Swift core.

Status: pre-alpha, core library under construction. Spec:
`docs/superpowers/specs/2026-06-10-ambitick-design.md`.

Full setup instructions land with the macOS app (Plan 2).
```

- [ ] **Step 5: Commit and push; verify CI**

```bash
git add Package.swift Sources Tests .github README.md
git commit -m "feat: SPM scaffold for AmbitickCore with Linux CI"
git push
```

Run: `gh run watch --exit-status` (or Martin checks Actions / runs `swift test`)
Expected: 1 test, PASS. If the workflow push is PAT-rejected, hand `.github/workflows/ci.yml` to Martin (see header).

---

### Task 2: Domain models

**Files:**
- Modify: `Sources/AmbitickCore/Models.swift` (replace placeholder, keep `Ambitick.version`)
- Modify: `Tests/AmbitickCoreTests/ModelsTests.swift`

- [ ] **Step 1: Write failing tests**

Replace `Tests/AmbitickCoreTests/ModelsTests.swift` with:

```swift
import XCTest
@testable import AmbitickCore

final class ModelsTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(Ambitick.version, "0.1.0")
    }

    func testLocalTasksAreLocalOnly() {
        let local = WorkTask(ref: .local(UUID()), subject: "Gaming", status: "Open")
        let op = WorkTask(ref: .op(42), subject: "Timesheets", status: "Closed")
        XCTAssertTrue(local.isLocalOnly)
        XCTAssertFalse(op.isLocalOnly)
    }

    func testSurfacePrefersURLOverTitle() {
        let withURL = ActivitySignal(app: "Chrome", windowTitle: "Inbox – Gmail",
                                     tabURL: "https://mail.google.com/mail/u/0/#inbox",
                                     timestamp: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(Surface(signal: withURL).detail, "mail.google.com/mail/u/0/")
        let titled = ActivitySignal(app: "Ghostty", windowTitle: "Ambitick",
                                    timestamp: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(Surface(signal: titled), Surface(app: "Ghostty", detail: "Ambitick"))
    }

    func testSessionRoundTripsThroughJSON() throws {
        let s = Session(task: .op(7), start: Date(timeIntervalSince1970: 100),
                        end: Date(timeIntervalSince1970: 700), certainty: 0.83)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Session.self, from: data)
        XCTAssertEqual(back, s)
    }
}
```

- [ ] **Step 2: Implement the models**

Replace `Sources/AmbitickCore/Models.swift` with:

```swift
import Foundation

public enum Ambitick {
    public static let version = "0.1.0"
}

/// Identity of a task. `.op` = OpenProject work package; `.local` = Ambitick-only
/// (leisure tracking etc.), never pushed to OP.
public enum TaskRef: Hashable, Codable, Sendable {
    case op(Int)
    case local(UUID)
}

/// What a stretch of time can be attributed to.
public enum Target: Hashable, Codable, Sendable {
    case task(TaskRef)
    case doNotTrack
}

public struct WorkTask: Equatable, Codable, Sendable {
    public var ref: TaskRef
    public var subject: String
    public var project: String?
    public var status: String
    public var lastConfirmedAt: Date?

    public var isLocalOnly: Bool {
        if case .local = ref { return true }
        return false
    }

    public init(ref: TaskRef, subject: String, project: String? = nil,
                status: String, lastConfirmedAt: Date? = nil) {
        self.ref = ref
        self.subject = subject
        self.project = project
        self.status = status
        self.lastConfirmedAt = lastConfirmedAt
    }
}

/// One observation from the sensors: what is focused right now.
public struct ActivitySignal: Equatable, Codable, Sendable {
    public var app: String
    public var windowTitle: String?
    public var tabURL: String?
    public var timestamp: Date

    public init(app: String, windowTitle: String? = nil, tabURL: String? = nil,
                timestamp: Date) {
        self.app = app
        self.windowTitle = windowTitle
        self.tabURL = tabURL
        self.timestamp = timestamp
    }
}

/// Everything the platform sensor layer can tell Core. Sensors (Plan 2) emit these;
/// Core tests emit them from scripts.
public enum SensorEvent: Equatable, Sendable {
    case focus(ActivitySignal)
    case input(Date)                     // keyboard/mouse seen at this time
    case willSleep(Date)
    case didWake(Date)
    case microphone(active: Bool, at: Date)
}

/// The stable identity of a window/tab for priming and learning:
/// URL host+path when there is a URL, else the window title.
public struct Surface: Hashable, Codable, Sendable {
    public var app: String
    public var detail: String

    public init(app: String, detail: String) {
        self.app = app
        self.detail = detail
    }

    public init(signal: ActivitySignal) {
        self.app = signal.app
        if let raw = signal.tabURL, let url = URL(string: raw), let host = url.host {
            self.detail = host + url.path
        } else {
            self.detail = signal.windowTitle ?? ""
        }
    }
}

/// A contiguous stretch of focus on one surface, attributed to one target.
public struct FocusSpan: Equatable, Sendable {
    public var target: Target
    public var certainty: Double
    public var signal: ActivitySignal
    public var start: Date
    public var end: Date

    public init(target: Target, certainty: Double, signal: ActivitySignal,
                start: Date, end: Date) {
        self.target = target
        self.certainty = certainty
        self.signal = signal
        self.start = start
        self.end = end
    }
}

/// A closed, journalled stretch of tracked time on one task.
public struct Session: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var task: TaskRef
    public var start: Date
    public var end: Date
    public var certainty: Double
    public var pushedToOP: Bool
    public var comment: String?

    public init(id: UUID = UUID(), task: TaskRef, start: Date, end: Date,
                certainty: Double, pushedToOP: Bool = false, comment: String? = nil) {
        self.id = id
        self.task = task
        self.start = start
        self.end = end
        self.certainty = certainty
        self.pushedToOP = pushedToOP
        self.comment = comment
    }
}

/// One coalesced row in the review queue (low-certainty time awaiting assignment).
public struct ReviewSegment: Equatable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var app: String
    public var windowTitle: String?
    public var tabURL: String?
    public var start: Date
    public var end: Date
    public var assigned: Target?

    public init(id: UUID = UUID(), app: String, windowTitle: String? = nil,
                tabURL: String? = nil, start: Date, end: Date, assigned: Target? = nil) {
        self.id = id
        self.app = app
        self.windowTitle = windowTitle
        self.tabURL = tabURL
        self.start = start
        self.end = end
        self.assigned = assigned
    }
}
```

- [ ] **Step 3: Run tests (CI/Mac)**

Run: `swift test --filter ModelsTests`
Expected: 4 tests, PASS. (Note `Surface.detail` for the Gmail URL is `mail.google.com/mail/u/0/` – URL fragments are not part of `path`.)

- [ ] **Step 4: Commit**

```bash
git add Sources/AmbitickCore/Models.swift Tests/AmbitickCoreTests/ModelsTests.swift
git commit -m "feat: AmbitickCore domain models"
```

---

### Task 3: OP URL parser

**Files:**
- Create: `Sources/AmbitickCore/OPURLParser.swift`
- Create: `Tests/AmbitickCoreTests/OPURLParserTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import AmbitickCore

final class OPURLParserTests: XCTestCase {
    let host = "op.example.com"

    func testExtractsIDFromWorkPackagePaths() {
        XCTAssertEqual(OPURLParser.taskID(in: "https://op.example.com/work_packages/842", instanceHost: host), 842)
        XCTAssertEqual(OPURLParser.taskID(in: "https://op.example.com/projects/amb/work_packages/91/activity", instanceHost: host), 91)
    }

    func testRejectsOtherHostsAndPaths() {
        XCTAssertNil(OPURLParser.taskID(in: "https://evil.example.com/work_packages/842", instanceHost: host))
        XCTAssertNil(OPURLParser.taskID(in: "https://op.example.com/projects/amb/overview", instanceHost: host))
        XCTAssertNil(OPURLParser.taskID(in: "https://op.example.com/work_packages/new", instanceHost: host))
        XCTAssertNil(OPURLParser.taskID(in: "not a url", instanceHost: host))
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public enum OPURLParser {
    /// Extracts a work-package id from a URL on the given OP instance host,
    /// matching `/work_packages/<id>` anywhere in the path.
    public static func taskID(in urlString: String, instanceHost: String) -> Int? {
        guard let url = URL(string: urlString), url.host == instanceHost else { return nil }
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "work_packages"), i + 1 < parts.count,
              let id = Int(parts[i + 1]) else { return nil }
        return id
    }
}
```

- [ ] **Step 3: Run tests (CI/Mac)**

Run: `swift test --filter OPURLParserTests`
Expected: 2 tests, PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/AmbitickCore/OPURLParser.swift Tests/AmbitickCoreTests/OPURLParserTests.swift
git commit -m "feat: OP work-package URL parser"
```

---

### Task 4: LearningStore

**Files:**
- Create: `Sources/AmbitickCore/LearningStore.swift`
- Create: `Tests/AmbitickCoreTests/LearningStoreTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import AmbitickCore

final class LearningStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    var ghostty: ActivitySignal { ActivitySignal(app: "Ghostty", windowTitle: "Ambitick", timestamp: t0) }
    var steam: ActivitySignal { ActivitySignal(app: "Steam", windowTitle: "Library", timestamp: t0) }
    let taskA = Target.task(.op(1))
    let taskB = Target.task(.op(2))

    func testFeatureExtraction() {
        let sig = ActivitySignal(app: "Chrome", windowTitle: "Q3 Invoice review",
                                 tabURL: "https://docs.google.com/document/d/abc",
                                 timestamp: t0)
        let feats = LearningStore.features(from: sig)
        XCTAssertTrue(feats.contains(Feature(.app, "chrome")))
        XCTAssertTrue(feats.contains(Feature(.titleToken, "invoice")))
        XCTAssertFalse(feats.contains(Feature(.titleToken, "q3")))   // < 3 chars dropped
        XCTAssertTrue(feats.contains(Feature(.urlHost, "docs.google.com")))
        XCTAssertTrue(feats.contains(Feature(.urlPath, "docs.google.com/document")))
    }

    func testLearnedSignalOutscoresUnlearned() {
        var store = LearningStore()
        store.learn(ghostty, target: taskA)
        store.learn(ghostty, target: taskA)
        let scores = store.scores(for: ghostty, among: [taskA, taskB])
        XCTAssertGreaterThan(scores[taskA]!, scores[taskB]!)
        XCTAssertEqual(scores.values.reduce(0, +), 1.0, accuracy: 0.001)
    }

    func testCorrectionMovesTheScore() {
        var store = LearningStore()
        store.learn(ghostty, target: taskA)
        store.correct(ghostty, from: taskA, to: taskB)
        let scores = store.scores(for: ghostty, among: [taskA, taskB])
        XCTAssertGreaterThan(scores[taskB]!, scores[taskA]!)
    }

    func testDoNotTrackIsLearnable() {
        var store = LearningStore()
        store.learn(steam, target: .doNotTrack, weight: 3)
        let scores = store.scores(for: steam, among: [taskA, .doNotTrack])
        XCTAssertGreaterThan(scores[.doNotTrack]!, scores[taskA]!)
    }

    func testRoundTripsThroughJSON() throws {
        var store = LearningStore()
        store.learn(ghostty, target: taskA)
        let back = try JSONDecoder().decode(LearningStore.self,
                                            from: JSONEncoder().encode(store))
        XCTAssertEqual(back.scores(for: ghostty, among: [taskA, taskB]),
                       store.scores(for: ghostty, among: [taskA, taskB]))
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public struct Feature: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case app, titleToken, urlHost, urlPath, hourOfDay
    }
    public var kind: Kind
    public var value: String
    public init(_ kind: Kind, _ value: String) {
        self.kind = kind
        self.value = value
    }
}

/// Naive-Bayes-style association store. Counts (feature, target) co-occurrences
/// from confirmations/corrections and scores signals against candidate targets.
/// Pure value type; persist with JSONFileStore (Task 13).
public struct LearningStore: Codable, Equatable, Sendable {
    private var counts: [Feature: [Target: Double]] = [:]
    private var totals: [Target: Double] = [:]

    public init() {}

    public var isEmpty: Bool { totals.isEmpty }

    public static func features(from signal: ActivitySignal,
                                calendar: Calendar = Calendar(identifier: .gregorian)) -> [Feature] {
        var out = [Feature(.app, signal.app.lowercased())]
        if let title = signal.windowTitle {
            let tokens = title.lowercased()
                .split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
                .filter { $0.count >= 3 }
            out += Set(tokens).sorted().map { Feature(.titleToken, $0) }
        }
        if let raw = signal.tabURL, let url = URL(string: raw), let host = url.host {
            out.append(Feature(.urlHost, host))
            if let first = url.pathComponents.dropFirst().first {
                out.append(Feature(.urlPath, host + "/" + first))
            }
        }
        out.append(Feature(.hourOfDay, String(calendar.component(.hour, from: signal.timestamp))))
        return out
    }

    public mutating func learn(_ signal: ActivitySignal, target: Target, weight: Double = 1) {
        for f in Self.features(from: signal) {
            counts[f, default: [:]][target, default: 0] += weight
        }
        totals[target, default: 0] += weight
    }

    /// A correction teaches harder than a confirmation: subtract from the wrong
    /// target, add double to the right one.
    public mutating func correct(_ signal: ActivitySignal, from old: Target, to new: Target) {
        learn(signal, target: old, weight: -1)
        learn(signal, target: new, weight: 2)
    }

    /// Softmax-normalised scores (sum to 1) over `candidates` for this signal.
    public func scores(for signal: ActivitySignal, among candidates: [Target]) -> [Target: Double] {
        guard !candidates.isEmpty else { return [:] }
        let feats = Self.features(from: signal)
        var raw: [Target: Double] = [:]
        for t in candidates {
            let total = max(totals[t] ?? 0, 0)
            var logp = log(total + 1)
            for f in feats {
                let c = max(counts[f]?[t] ?? 0, 0)
                logp += log((c + 0.1) / (total + 1))
            }
            raw[t] = logp
        }
        let maxV = raw.values.max()!
        var expd: [Target: Double] = [:]
        var sum = 0.0
        for (t, v) in raw {
            let e = exp(v - maxV)
            expd[t] = e
            sum += e
        }
        return expd.mapValues { $0 / sum }
    }

    /// Fraction of a target's confirmed weight that fell in this hour (time-of-day prior).
    public func hourAffinity(for target: Target, hour: Int) -> Double {
        let c = max(counts[Feature(.hourOfDay, String(hour))]?[target] ?? 0, 0)
        let total = max(totals[target] ?? 0, 0)
        return total > 0 ? c / total : 0
    }
}
```

- [ ] **Step 3: Run tests (CI/Mac)**

Run: `swift test --filter LearningStoreTests`
Expected: 5 tests, PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/AmbitickCore/LearningStore.swift Tests/AmbitickCoreTests/LearningStoreTests.swift
git commit -m "feat: learning store with feature extraction and Bayes-style scoring"
```

---

### Task 5: TaskRanker

**Files:**
- Create: `Sources/AmbitickCore/TaskRanker.swift`
- Create: `Tests/AmbitickCoreTests/TaskRankerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import AmbitickCore

final class TaskRankerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let ranker = TaskRanker()

    func task(_ id: Int, _ subject: String, _ status: String, confirmedDaysAgo: Double? = nil) -> WorkTask {
        WorkTask(ref: .op(id), subject: subject, status: status,
                 lastConfirmedAt: confirmedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
    }

    func testStatusOrderRanks() {
        let tasks = [task(1, "a", "Closed"), task(2, "b", "Now"), task(3, "c", "Open"), task(4, "d", "Next")]
        XCTAssertEqual(ranker.ranked(tasks, at: now).map(\.subject), ["b", "d", "c", "a"])
    }

    func testRecentlyConfirmedClosedOutranksDormantOpen() {
        // The Timesheets case from the spec: Closed but tracked yesterday
        // must beat an Open task never tracked.
        let timesheets = task(1, "Timesheets", "Closed", confirmedDaysAgo: 1)
        let dormant = task(2, "Dormant", "Open")
        XCTAssertEqual(ranker.ranked([dormant, timesheets], at: now).first?.subject, "Timesheets")
    }

    func testPickListIsRecentThenLikelyWithoutDuplicates() {
        let tasks = [
            task(1, "recent1", "Open", confirmedDaysAgo: 0.1),
            task(2, "recent2", "Closed", confirmedDaysAgo: 0.2),
            task(3, "likelyNow", "Now"),
            task(4, "likelyNext", "Next"),
            task(5, "tail", "Closed"),
        ]
        let picks = ranker.pickList(tasks, at: now, recentCount: 2, likelyCount: 2)
        XCTAssertEqual(picks.map(\.subject), ["recent1", "recent2", "likelyNow", "likelyNext"])
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public struct RankingConfig: Codable, Equatable, Sendable {
    public var statusOrder: [String]
    public var recencyHalfLifeDays: Double

    public init(statusOrder: [String] = ["Now", "Next", "Open", "Closed"],
                recencyHalfLifeDays: Double = 7) {
        self.statusOrder = statusOrder
        self.recencyHalfLifeDays = recencyHalfLifeDays
    }
}

public struct TaskRanker: Sendable {
    public var config: RankingConfig

    public init(config: RankingConfig = RankingConfig()) {
        self.config = config
    }

    /// Status prior + exponentially-decayed recency + time-of-day affinity.
    /// Recency carries double weight so an actively-tracked Closed task
    /// (e.g. Timesheets) outranks dormant Open tasks.
    public func score(_ task: WorkTask, at now: Date, learning: LearningStore? = nil,
                      calendar: Calendar = Calendar(identifier: .gregorian)) -> Double {
        var statusScore = 0.0
        if let idx = config.statusOrder.firstIndex(of: task.status) {
            statusScore = Double(config.statusOrder.count - idx) / Double(config.statusOrder.count)
        }
        var recencyScore = 0.0
        if let last = task.lastConfirmedAt {
            let days = max(now.timeIntervalSince(last), 0) / 86_400
            recencyScore = pow(0.5, days / config.recencyHalfLifeDays)
        }
        var todScore = 0.0
        if let learning {
            todScore = learning.hourAffinity(for: .task(task.ref),
                                             hour: calendar.component(.hour, from: now))
        }
        return statusScore + 2 * recencyScore + todScore
    }

    public func ranked(_ tasks: [WorkTask], at now: Date,
                       learning: LearningStore? = nil) -> [WorkTask] {
        tasks.sorted { score($0, at: now, learning: learning) > score($1, at: now, learning: learning) }
    }

    /// Every "pick a task" surface: N most recently confirmed, then M most
    /// likely of the rest. No duplicates.
    public func pickList(_ tasks: [WorkTask], at now: Date, recentCount: Int,
                         likelyCount: Int, learning: LearningStore? = nil) -> [WorkTask] {
        let recent = tasks
            .compactMap { t in t.lastConfirmedAt.map { (t, $0) } }
            .sorted { $0.1 > $1.1 }
            .prefix(recentCount)
            .map(\.0)
        let taken = Set(recent.map(\.ref))
        let likely = ranked(tasks.filter { !taken.contains($0.ref) }, at: now, learning: learning)
            .prefix(likelyCount)
        return recent + Array(likely)
    }
}
```

- [ ] **Step 3: Run tests (CI/Mac)**

Run: `swift test --filter TaskRankerTests`
Expected: 3 tests, PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/AmbitickCore/TaskRanker.swift Tests/AmbitickCoreTests/TaskRankerTests.swift
git commit -m "feat: task ranking with status order, recency and pick lists"
```

---

### Task 6: Attributor (incl. OP task-priming)

**Files:**
- Create: `Sources/AmbitickCore/Attributor.swift`
- Create: `Tests/AmbitickCoreTests/AttributorTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import AmbitickCore

final class AttributorTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let host = "op.example.com"
    var tasks: [WorkTask] {
        [WorkTask(ref: .op(1), subject: "Ambitick build", status: "Now"),
         WorkTask(ref: .op(2), subject: "Investment review", status: "Next")]
    }

    func opPage(_ id: Int) -> ActivitySignal {
        ActivitySignal(app: "Chrome", windowTitle: "WP \(id)",
                       tabURL: "https://op.example.com/work_packages/\(id)", timestamp: now)
    }
    var ghostty: ActivitySignal {
        ActivitySignal(app: "Ghostty", windowTitle: "Ambitick", timestamp: now)
    }

    func testOPTaskPageIsNearCertain() {
        let a = Attributor(instanceHost: host)
        let result = a.attribute(opPage(1), tasks: tasks, now: now)
        XCTAssertEqual(result.best?.target, .task(.op(1)))
        XCTAssertEqual(result.certainty, 0.99, accuracy: 0.001)
    }

    func testPrimingFlow() {
        let a = Attributor(instanceHost: host)
        // 1. open task 1 in OP, 2. dwell on Ghostty -> pending prime at 0.7
        _ = a.attribute(opPage(1), tasks: tasks, now: now)
        a.noteDwell(ghostty)
        let pending = a.attribute(ghostty, tasks: tasks, now: now)
        XCTAssertEqual(pending.best?.target, .task(.op(1)))
        XCTAssertEqual(pending.certainty, 0.7, accuracy: 0.001)
        // 3. user confirms -> primed at 0.95
        a.confirm(ghostty, task: .op(1))
        let primed = a.attribute(ghostty, tasks: tasks, now: now)
        XCTAssertEqual(primed.best?.target, .task(.op(1)))
        XCTAssertEqual(primed.certainty, 0.95, accuracy: 0.001)
    }

    func testPrimeIsConsumedByFirstDwellOnly() {
        let a = Attributor(instanceHost: host)
        _ = a.attribute(opPage(1), tasks: tasks, now: now)
        a.noteDwell(ghostty)            // consumes the prime
        let other = ActivitySignal(app: "Obsidian", windowTitle: "notes", timestamp: now)
        a.noteDwell(other)              // must NOT become pending for task 1
        let result = a.attribute(other, tasks: tasks, now: now)
        XCTAssertNotEqual(result.certainty, 0.7, accuracy: 0.001)
    }

    func testSurfaceFollowingDifferentOPTaskRebinds() {
        let a = Attributor(instanceHost: host)
        _ = a.attribute(opPage(1), tasks: tasks, now: now)
        a.noteDwell(ghostty)
        a.confirm(ghostty, task: .op(1))
        // later: open task 2, return to the same Ghostty window
        _ = a.attribute(opPage(2), tasks: tasks, now: now)
        a.noteDwell(ghostty)
        let result = a.attribute(ghostty, tasks: tasks, now: now)
        XCTAssertEqual(result.best?.target, .task(.op(2)), "pending rebind must outrank old prime")
        XCTAssertEqual(result.certainty, 0.7, accuracy: 0.001)
    }

    func testUnknownSignalIsUncertain() {
        let a = Attributor(instanceHost: host)
        let result = a.attribute(ghostty, tasks: tasks, now: now)
        XCTAssertLessThan(result.certainty, 0.6)
    }

    func testOPPageWithoutTaskIDFallsBackToTopRankedTask() {
        // Spec: time in OP itself without a task id goes to the most
        // appropriate task by ranking. (v0.1 simplification: ranking over all
        // tasks; matching the page's project slug to task projects is a TODO.)
        let a = Attributor(instanceHost: host)
        let sig = ActivitySignal(app: "Chrome", windowTitle: "Overview",
                                 tabURL: "https://op.example.com/projects/amb/overview",
                                 timestamp: now)
        let result = a.attribute(sig, tasks: tasks, now: now)
        XCTAssertEqual(result.best?.target, .task(.op(1)), "'Now' status ranks top")
        XCTAssertGreaterThanOrEqual(result.certainty, 0.6)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public struct Candidate: Equatable, Sendable {
    public var target: Target
    public var score: Double
    public init(target: Target, score: Double) {
        self.target = target
        self.score = score
    }
}

public struct Attribution: Equatable, Sendable {
    public var best: Candidate?
    public var ranked: [Candidate]
    public var certainty: Double { best?.score ?? 0 }
    public init(best: Candidate?, ranked: [Candidate]) {
        self.best = best
        self.ranked = ranked
    }
}

/// Turns one ActivitySignal into a ranked list of targets.
/// Source strength order (spec): OP task URL > primed surface > pending prime
/// > learned associations + priors.
public final class Attributor {
    public let instanceHost: String
    public private(set) var learning: LearningStore
    private let ranker: TaskRanker

    private var lastOpenedOPTask: TaskRef?
    private var pendingPrime: (surface: Surface, task: TaskRef)?
    private var primedSurfaces: [Surface: TaskRef] = [:]

    public init(instanceHost: String, learning: LearningStore = LearningStore(),
                ranker: TaskRanker = TaskRanker()) {
        self.instanceHost = instanceHost
        self.learning = learning
        self.ranker = ranker
    }

    public func attribute(_ signal: ActivitySignal, tasks: [WorkTask], now: Date) -> Attribution {
        if let url = signal.tabURL, let id = OPURLParser.taskID(in: url, instanceHost: instanceHost) {
            lastOpenedOPTask = .op(id)
            let c = Candidate(target: .task(.op(id)), score: 0.99)
            return Attribution(best: c, ranked: [c])
        }
        let surface = Surface(signal: signal)
        var ranked = scored(signal, tasks: tasks, now: now)
        if let pending = pendingPrime, pending.surface == surface {
            ranked.removeAll { $0.target == .task(pending.task) }
            ranked.insert(Candidate(target: .task(pending.task), score: 0.7), at: 0)
        } else if let primed = primedSurfaces[surface] {
            ranked.removeAll { $0.target == .task(primed) }
            ranked.insert(Candidate(target: .task(primed), score: 0.95), at: 0)
        }
        return Attribution(best: ranked.first, ranked: ranked)
    }

    /// SessionTracker calls this when a surface has held focus beyond the
    /// prime-dwell threshold. Consumes lastOpenedOPTask ("immediately following").
    public func noteDwell(_ signal: ActivitySignal) {
        if let url = signal.tabURL, OPURLParser.taskID(in: url, instanceHost: instanceHost) != nil {
            return
        }
        guard let task = lastOpenedOPTask else { return }
        lastOpenedOPTask = nil
        let surface = Surface(signal: signal)
        if primedSurfaces[surface] != task {
            pendingPrime = (surface, task)
        }
    }

    /// Explicit user confirmation (popover click + return, or any direct pick).
    public func confirm(_ signal: ActivitySignal, task: TaskRef) {
        let surface = Surface(signal: signal)
        primedSurfaces[surface] = task
        if pendingPrime?.surface == surface { pendingPrime = nil }
        learning.learn(signal, target: .task(task), weight: 2)
    }

    /// Review-window or prompt assignment, including "Do not track".
    public func assign(_ signal: ActivitySignal, target: Target) {
        let surface = Surface(signal: signal)
        if case .task(let t) = target {
            primedSurfaces[surface] = t
        } else {
            primedSurfaces[surface] = nil
        }
        if pendingPrime?.surface == surface { pendingPrime = nil }
        learning.learn(signal, target: target, weight: 2)
    }

    private func scored(_ signal: ActivitySignal, tasks: [WorkTask], now: Date) -> [Candidate] {
        let targets = tasks.map { Target.task($0.ref) } + [.doNotTrack]
        let learned = learning.isEmpty ? [:] : learning.scores(for: signal, among: targets)
        let priors = tasks.map { ranker.score($0, at: now, learning: learning) }
        let maxPrior = max(priors.max() ?? 1, 0.001)
        // On an OP page without a task id, trust the ranking outright (spec:
        // "most appropriate task by ranking"); elsewhere priors only nudge.
        let onOPHost = signal.tabURL.flatMap(URL.init(string:))?.host == instanceHost
        let priorWeight = onOPHost ? 0.65 : 0.2
        var out: [Candidate] = []
        for (task, prior) in zip(tasks, priors) {
            let l = learned[.task(task.ref)] ?? 0
            out.append(Candidate(target: .task(task.ref),
                                 score: min(0.9, 0.7 * l + priorWeight * prior / maxPrior)))
        }
        out.append(Candidate(target: .doNotTrack, score: 0.7 * (learned[.doNotTrack] ?? 0)))
        return out.sorted { $0.score > $1.score }
    }
}
```

- [ ] **Step 3: Run tests (CI/Mac)**

Run: `swift test --filter AttributorTests`
Expected: 6 tests, PASS. (In `testUnknownSignalIsUncertain` the learned map is empty and there is no URL, so scores come from priors at weight 0.2 < 0.6; in the OP-host fallback test the prior weight is 0.65, so the top-ranked task clears 0.6.)

- [ ] **Step 4: Commit**

```bash
git add Sources/AmbitickCore/Attributor.swift Tests/AmbitickCoreTests/AttributorTests.swift
git commit -m "feat: attributor with OP URL certainty and task-priming"
```

---

### Task 7: MinuteResolver

**Files:**
- Create: `Sources/AmbitickCore/MinuteResolver.swift`
- Create: `Tests/AmbitickCoreTests/MinuteResolverTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import AmbitickCore

final class MinuteResolverTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_750_000_020)  // NOT minute-aligned (xx:xx:20)
    let a = Target.task(.op(1))
    let b = Target.task(.op(2))
    var sig: ActivitySignal { ActivitySignal(app: "x", timestamp: Date(timeIntervalSince1970: 0)) }

    func span(_ t: Target, from: TimeInterval, to: TimeInterval) -> FocusSpan {
        FocusSpan(target: t, certainty: 1, signal: sig,
                  start: base.addingTimeInterval(from), end: base.addingTimeInterval(to))
    }

    func testDominantTargetWinsTheMinute() {
        // Minute containing base+0..40: A holds 30 s, B 10 s -> A wins it.
        let minutes = MinuteResolver.dominantPerMinute([
            span(a, from: 0, to: 30), span(b, from: 30, to: 40),
        ])
        XCTAssertEqual(minutes.count, 1)
        XCTAssertEqual(minutes[0].target, a)
        // minuteStart is the wall-clock minute boundary, not base
        XCTAssertEqual(minutes[0].minuteStart.timeIntervalSince1970.truncatingRemainder(dividingBy: 60), 0)
    }

    func testSpansSplitAcrossMinuteBoundaries() {
        // A 0-50 (40 s in minute 1, 10 s in minute 2), B 50-100 (50 s in minute 2)
        // base is at :20, so minute boundary is at +40.
        let minutes = MinuteResolver.dominantPerMinute([
            span(a, from: 0, to: 50), span(b, from: 50, to: 100),
        ])
        XCTAssertEqual(minutes.map(\.target), [a, b])
    }

    func testEmptyInput() {
        XCTAssertTrue(MinuteResolver.dominantPerMinute([]).isEmpty)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public enum MinuteResolver {
    public struct Minute: Equatable, Sendable {
        public var minuteStart: Date
        public var target: Target
    }

    /// Buckets spans into wall-clock minutes; each minute goes wholly to the
    /// target that held it longest (spec: "the dominant task wins the whole
    /// minute"). Ties break toward the target seen earliest.
    public static func dominantPerMinute(_ spans: [FocusSpan]) -> [Minute] {
        guard !spans.isEmpty else { return [] }
        var seconds: [Double: [Target: Double]] = [:]   // minuteEpoch -> target -> s
        var firstSeen: [Target: Date] = [:]
        for span in spans {
            if firstSeen[span.target] == nil { firstSeen[span.target] = span.start }
            var cursor = span.start.timeIntervalSince1970
            let end = span.end.timeIntervalSince1970
            while cursor < end {
                let minute = (cursor / 60).rounded(.down) * 60
                let sliceEnd = Swift.min(minute + 60, end)
                seconds[minute, default: [:]][span.target, default: 0] += sliceEnd - cursor
                cursor = sliceEnd
            }
        }
        return seconds.keys.sorted().map { minute in
            let winner = seconds[minute]!
                .sorted {
                    if $0.value != $1.value { return $0.value > $1.value }
                    return (firstSeen[$0.key] ?? .distantFuture) < (firstSeen[$1.key] ?? .distantFuture)
                }
                .first!.key
            return Minute(minuteStart: Date(timeIntervalSince1970: minute), target: winner)
        }
    }
}
```

- [ ] **Step 3: Run tests (CI/Mac)**

Run: `swift test --filter MinuteResolverTests`
Expected: 3 tests, PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/AmbitickCore/MinuteResolver.swift Tests/AmbitickCoreTests/MinuteResolverTests.swift
git commit -m "feat: dominant-task-per-minute resolution"
```

---

### Task 8: SessionTracker

**Files:**
- Create: `Sources/AmbitickCore/SessionTracker.swift`
- Create: `Tests/AmbitickCoreTests/SessionTrackerTests.swift`

This is the heart. Behaviour under test, from the spec:
1. Dominant-minute sessions: one `Session` per merged run of minutes on a task.
2. Uncertain time: attribute to last certain task at low certainty, queue coalesced `ReviewSegment`s (same surface merged, < `minSegmentSeconds` dropped).
3. Confident non-work: auto-stop by default; with `nonWorkTracksLocally` + `leisureTask`, switch to the local task instead.
4. Idle: input gap > threshold (or sleep) retro-trims to last input and prompts on resume/wake.
5. Calls: mic-on collects uncertain segments; mic-off prompts `callEnded` with them.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import AmbitickCore

final class SessionTrackerTests: XCTestCase {
    // t(n) = n seconds after a minute-aligned base (1_750_000_080 = 29_166_668 × 60)
    let base = Date(timeIntervalSince1970: 1_750_000_080)
    func t(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

    let host = "op.example.com"
    var tasks: [WorkTask] {
        [WorkTask(ref: .op(1), subject: "Ambitick", status: "Now"),
         WorkTask(ref: .op(2), subject: "Investment", status: "Next")]
    }

    func sig(_ app: String, _ title: String, at: TimeInterval, url: String? = nil) -> ActivitySignal {
        ActivitySignal(app: app, windowTitle: title, tabURL: url, timestamp: t(at))
    }

    func makeTracker(config: TrackerConfig = TrackerConfig()) -> (SessionTracker, Attributor) {
        let attributor = Attributor(instanceHost: host)
        let tracker = SessionTracker(attributor: attributor, config: config) { self.tasks }
        return (tracker, attributor)
    }

    func testDominantMinuteSessions() {
        let (tracker, attributor) = makeTracker()
        var sessions: [Session] = []
        tracker.onSession = { sessions.append($0) }
        attributor.confirm(sig("Ghostty", "Ambitick", at: 0), task: .op(1))
        attributor.confirm(sig("Ghostty", "Investment", at: 0), task: .op(2))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 50)))   // A dominates min 0
        tracker.handle(.focus(sig("Ghostty", "Investment", at: 70)))
        tracker.stop(at: t(130))

        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].task, .op(1))
        XCTAssertEqual(sessions[0].start, t(0))
        XCTAssertEqual(sessions[0].end, t(60))
        XCTAssertEqual(sessions[1].task, .op(2))
        XCTAssertEqual(sessions[1].start, t(60))
        XCTAssertEqual(sessions[1].end, t(130))
    }

    func testUncertainTimeSticksToLastTaskAndQueuesReview() {
        let (tracker, _) = makeTracker()
        var reviews: [ReviewSegment] = []
        var states: [TrackerState] = []
        tracker.onReview = { reviews.append($0) }
        tracker.onState = { states.append($0) }

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Mystery", "???", at: 0)))           // unknown -> uncertain
        tracker.handle(.focus(sig("Mystery", "???", at: 30)))          // same surface, coalesces
        tracker.handle(.focus(sig("Other", "thing", at: 60)))          // new surface, 25 s
        tracker.handle(.focus(sig("Other", "thing2", at: 85)))         // 5 s < minSegment: dropped
        tracker.stop(at: t(90))

        // still attributed to op(1), flagged low certainty
        XCTAssertTrue(states.contains { if case .tracking(.task(.op(1)), let c) = $0 { return c < 0.6 }; return false })
        XCTAssertEqual(reviews.count, 2)
        XCTAssertEqual(reviews[0].app, "Mystery")
        XCTAssertEqual(reviews[0].start, t(0))
        XCTAssertEqual(reviews[0].end, t(60))      // coalesced across the two Mystery spans
        XCTAssertEqual(reviews[1].app, "Other")
        XCTAssertEqual(reviews[1].windowTitle, "thing")
        XCTAssertEqual(reviews[1].end, t(85))      // the 5 s "thing2" span was dropped
    }

    func testConfidentNonWorkAutoStops() {
        let (tracker, attributor) = makeTracker()
        var states: [TrackerState] = []
        tracker.onState = { states.append($0) }
        var learning = LearningStore()
        learning.learn(sig("Steam", "Library", at: 0), target: .doNotTrack, weight: 5)
        attributor.replaceLearning(learning)

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))
        tracker.handle(.focus(sig("Steam", "Library", at: 30)))
        XCTAssertEqual(states.last, .stopped)
    }

    func testLeisureOptionTracksLocallyInstead() {
        let leisure = TaskRef.local(UUID())
        var config = TrackerConfig()
        config.nonWorkTracksLocally = true
        config.leisureTask = leisure
        let (tracker, attributor) = makeTracker(config: config)
        var states: [TrackerState] = []
        tracker.onState = { states.append($0) }
        var learning = LearningStore()
        learning.learn(sig("Steam", "Library", at: 0), target: .doNotTrack, weight: 5)
        attributor.replaceLearning(learning)

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Steam", "Library", at: 30)))
        if case .tracking(.task(leisure), _) = states.last {} else {
            XCTFail("expected tracking leisure task, got \(String(describing: states.last))")
        }
    }

    func testIdleRetroTrimsAndPromptsOnNextInput() {
        var config = TrackerConfig()
        config.idleThresholdSeconds = 600
        let (tracker, attributor) = makeTracker(config: config)
        var sessions: [Session] = []
        var prompts: [TrackerPrompt] = []
        tracker.onSession = { sessions.append($0) }
        tracker.onPrompt = { prompts.append($0) }
        attributor.confirm(sig("Ghostty", "Ambitick", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))
        tracker.handle(.input(t(40)))
        tracker.handle(.input(t(700)))   // 660 s gap > 600

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].end, t(40), "session must trim back to last input")
        XCTAssertEqual(prompts, [.resumeAfterIdle(stoppedAt: t(40))])
    }

    func testSleepTrimsAndWakePrompts() {
        let (tracker, attributor) = makeTracker()
        var sessions: [Session] = []
        var prompts: [TrackerPrompt] = []
        tracker.onSession = { sessions.append($0) }
        tracker.onPrompt = { prompts.append($0) }
        attributor.confirm(sig("Ghostty", "Ambitick", at: 0), task: .op(1))

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))
        tracker.handle(.input(t(50)))
        tracker.handle(.willSleep(t(120)))
        tracker.handle(.didWake(t(3000)))

        XCTAssertEqual(sessions.first?.end, t(50))
        XCTAssertEqual(prompts, [.resumeAfterIdle(stoppedAt: t(50))])
    }

    func testCallEndPromptsWithCallSegments() {
        let (tracker, _) = makeTracker()
        var prompts: [TrackerPrompt] = []
        tracker.onPrompt = { prompts.append($0) }

        tracker.start(task: .op(1), at: t(0))
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 0)))
        tracker.handle(.microphone(active: true, at: t(30)))
        tracker.handle(.focus(sig("FaceTime", "Call", at: 30)))   // unknown -> uncertain
        tracker.handle(.focus(sig("Ghostty", "Ambitick", at: 90)))
        tracker.handle(.microphone(active: false, at: t(95)))

        guard case .callEnded(let segments)? = prompts.last else {
            return XCTFail("expected callEnded, got \(prompts)")
        }
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].app, "FaceTime")
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

public struct TrackerConfig: Equatable, Sendable {
    public var minSegmentSeconds: TimeInterval
    public var primeDwellSeconds: TimeInterval
    public var idleThresholdSeconds: TimeInterval
    public var uncertainBelow: Double
    public var nonWorkTracksLocally: Bool
    public var leisureTask: TaskRef?

    public init(minSegmentSeconds: TimeInterval = 20,
                primeDwellSeconds: TimeInterval = 30,
                idleThresholdSeconds: TimeInterval = 600,
                uncertainBelow: Double = 0.6,
                nonWorkTracksLocally: Bool = false,
                leisureTask: TaskRef? = nil) {
        self.minSegmentSeconds = minSegmentSeconds
        self.primeDwellSeconds = primeDwellSeconds
        self.idleThresholdSeconds = idleThresholdSeconds
        self.uncertainBelow = uncertainBelow
        self.nonWorkTracksLocally = nonWorkTracksLocally
        self.leisureTask = leisureTask
    }
}

public enum TrackerState: Equatable, Sendable {
    case stopped
    case tracking(Target, certainty: Double)
}

public enum TrackerPrompt: Equatable, Sendable {
    case resumeAfterIdle(stoppedAt: Date)
    case callEnded(segments: [ReviewSegment])
    case taskChanged(to: Target)
}

/// Event-driven state machine. Single-threaded by contract: callers (the app's
/// sensor loop, or tests) deliver events in timestamp order on one actor/queue.
public final class SessionTracker {
    public private(set) var state: TrackerState = .stopped {
        didSet { if state != oldValue { onState(state) } }
    }
    public var onSession: (Session) -> Void = { _ in }
    public var onReview: (ReviewSegment) -> Void = { _ in }
    public var onState: (TrackerState) -> Void = { _ in }
    public var onPrompt: (TrackerPrompt) -> Void = { _ in }

    private let attributor: Attributor
    private let config: TrackerConfig
    private let tasks: () -> [WorkTask]

    private var spans: [FocusSpan] = []
    private var currentSignal: ActivitySignal?
    private var currentStart: Date?
    private var lastInput: Date?
    private var pendingReview: ReviewSegment?
    private var micActiveSince: Date?
    private var callSegments: [ReviewSegment] = []

    public init(attributor: Attributor, config: TrackerConfig = TrackerConfig(),
                tasks: @escaping () -> [WorkTask]) {
        self.attributor = attributor
        self.config = config
        self.tasks = tasks
    }

    // MARK: - Public controls

    public func start(task: TaskRef, at date: Date) {
        flushSessions(asOf: date)
        lastInput = date
        state = .tracking(.task(task), certainty: 1.0)
    }

    public func stop(at date: Date) {
        endCurrentSpan(at: date)
        flushSessions(asOf: date)
        state = .stopped
    }

    /// User picked a task (popover/prompt) for the surface currently in focus.
    /// This is the UI's confirm entry point: it teaches the attributor AND
    /// lifts the in-flight span to confirmed certainty.
    public func confirm(task: TaskRef, at date: Date) {
        if let signal = currentSignal {
            attributor.confirm(signal, task: task)
        }
        if case .tracking = state {
            state = .tracking(.task(task), certainty: 0.95)
        } else {
            start(task: task, at: date)
        }
    }

    public func handle(_ event: SensorEvent) {
        switch event {
        case .focus(let signal): handleFocus(signal)
        case .input(let date): handleInput(date)
        case .willSleep(let date): idleStop(asOf: min(lastInput ?? date, date), promptNow: false)
        case .didWake: promptResumeIfIdleStopped()
        case .microphone(let active, let at): handleMic(active: active, at: at)
        }
    }

    // MARK: - Event handling

    private var idleStoppedAt: Date?

    private func handleInput(_ date: Date) {
        defer { lastInput = max(lastInput ?? date, date) }
        guard case .tracking = state, let last = lastInput,
              date.timeIntervalSince(last) > config.idleThresholdSeconds else { return }
        idleStop(asOf: last, promptNow: true)
    }

    private func handleFocus(_ signal: ActivitySignal) {
        let now = signal.timestamp
        handleInput(now)   // a focus change counts as input; also runs the idle check
        if let prev = currentSignal, let start = currentStart {
            if now.timeIntervalSince(start) >= config.primeDwellSeconds {
                attributor.noteDwell(prev)
            }
            endCurrentSpan(at: now)
        }
        let attribution = attributor.attribute(signal, tasks: tasks(), now: now)
        currentSignal = signal
        currentStart = now

        switch state {
        case .stopped:
            // Auto-start only on the unambiguous OP-task-page signal.
            if let best = attribution.best, best.score >= 0.99,
               case .task(let task) = best.target {
                lastInput = now
                state = .tracking(.task(task), certainty: best.score)
                onPrompt(.taskChanged(to: .task(task)))
            }
        case .tracking(let currentTarget, _):
            guard let best = attribution.best else {
                state = .tracking(currentTarget, certainty: 0)
                return
            }
            if best.target == .doNotTrack, best.score >= config.uncertainBelow {
                if config.nonWorkTracksLocally, let leisure = config.leisureTask {
                    if currentTarget != .task(leisure) {
                        state = .tracking(.task(leisure), certainty: best.score)
                        onPrompt(.taskChanged(to: .task(leisure)))
                    }
                } else {
                    currentSignal = nil
                    currentStart = nil
                    stop(at: now)
                }
            } else if best.score >= config.uncertainBelow {
                if best.target != currentTarget { onPrompt(.taskChanged(to: best.target)) }
                state = .tracking(best.target, certainty: best.score)
            } else {
                // Uncertain: stick with the last certain target, flag it.
                state = .tracking(currentTarget, certainty: best.score)
            }
        }
    }

    private func handleMic(active: Bool, at date: Date) {
        if active {
            micActiveSince = date
            callSegments = []
        } else if micActiveSince != nil {
            // Flush BEFORE clearing the flag so in-flight call segments are
            // collected; only segments that started during the call count.
            endCurrentSpan(at: date)
            flushPendingReview()
            micActiveSince = nil
            if !callSegments.isEmpty {
                onPrompt(.callEnded(segments: callSegments))
            }
            callSegments = []
        }
    }

    // MARK: - Spans, review queue, sessions

    private func endCurrentSpan(at end: Date) {
        defer { currentSignal = nil; currentStart = nil }
        guard let signal = currentSignal, let start = currentStart, end > start,
              case .tracking(let target, let certainty) = state else { return }
        spans.append(FocusSpan(target: target, certainty: certainty, signal: signal,
                               start: start, end: end))
        if certainty < config.uncertainBelow {
            queueReview(signal: signal, start: start, end: end)
        } else {
            flushPendingReview()
        }
    }

    private func queueReview(signal: ActivitySignal, start: Date, end: Date) {
        if var p = pendingReview, p.app == signal.app, p.windowTitle == signal.windowTitle,
           p.tabURL == signal.tabURL {
            p.end = end
            pendingReview = p
        } else {
            flushPendingReview()
            pendingReview = ReviewSegment(app: signal.app, windowTitle: signal.windowTitle,
                                          tabURL: signal.tabURL, start: start, end: end)
        }
    }

    private func flushPendingReview() {
        guard let p = pendingReview else { return }
        pendingReview = nil
        guard p.end.timeIntervalSince(p.start) >= config.minSegmentSeconds else { return }
        if let since = micActiveSince, p.start >= since { callSegments.append(p) }
        onReview(p)
    }

    private func idleStop(asOf date: Date, promptNow: Bool) {
        guard case .tracking = state else { return }
        if let start = currentStart, date > start {
            endCurrentSpan(at: date)
        } else {
            currentSignal = nil
            currentStart = nil
        }
        flushSessions(asOf: date)
        state = .stopped
        idleStoppedAt = date
        if promptNow { promptResumeIfIdleStopped() }
    }

    private func promptResumeIfIdleStopped() {
        guard let stoppedAt = idleStoppedAt else { return }
        idleStoppedAt = nil
        onPrompt(.resumeAfterIdle(stoppedAt: stoppedAt))
    }

    /// Resolve accumulated spans into dominant-minute sessions and emit them.
    private func flushSessions(asOf date: Date) {
        flushPendingReview()
        let clipped = spans.compactMap { span -> FocusSpan? in
            guard span.start < date else { return nil }
            var s = span
            s.end = min(s.end, date)
            return s
        }
        spans = []
        guard !clipped.isEmpty else { return }
        let overallEnd = clipped.map(\.end).max()!
        let overallStart = clipped.map(\.start).min()!
        let minutes = MinuteResolver.dominantPerMinute(clipped)

        var runs: [(target: Target, start: Date, end: Date)] = []
        for (i, minute) in minutes.enumerated() {
            let mStart = max(minute.minuteStart, overallStart)
            let mEnd = min(minute.minuteStart.addingTimeInterval(60), overallEnd)
            if var last = runs.last, last.target == minute.target,
               i > 0, minutes[i - 1].minuteStart.addingTimeInterval(60) >= minute.minuteStart {
                last.end = mEnd
                runs[runs.count - 1] = last
            } else {
                runs.append((minute.target, mStart, mEnd))
            }
        }
        for run in runs {
            guard case .task(let ref) = run.target else { continue }   // doNotTrack time is never a session
            let certainty = clipped
                .filter { $0.target == run.target && $0.end > run.start && $0.start < run.end }
                .map(\.certainty).min() ?? 0
            let comment = commentText(for: run, in: clipped)
            onSession(Session(task: ref, start: run.start, end: run.end,
                              certainty: certainty, comment: comment))
        }
    }

    /// "App – title" of up to the 3 longest-held surfaces in the run.
    private func commentText(for run: (target: Target, start: Date, end: Date),
                             in spans: [FocusSpan]) -> String? {
        var durations: [String: TimeInterval] = [:]
        for s in spans where s.end > run.start && s.start < run.end {
            let label = [s.signal.app, s.signal.windowTitle].compactMap { $0 }.joined(separator: " – ")
            let overlap = min(s.end, run.end).timeIntervalSince(max(s.start, run.start))
            durations[label, default: 0] += overlap
        }
        let top = durations.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        return top.isEmpty ? nil : top.joined(separator: "; ")
    }
}
```

Also add to `Attributor.swift` (needed by tests to inject a pre-trained store):

```swift
extension Attributor {
    /// Test/persistence hook: swap in a loaded LearningStore.
    public func replaceLearning(_ store: LearningStore) {
        learning = store
    }
}
```

(`learning` must therefore be `public private(set) var` — it already is; the extension lives in the same file so `private(set)` is writable there. Put the extension at the bottom of `Attributor.swift`.)

- [ ] **Step 3: Run tests (CI/Mac)**

Run: `swift test --filter SessionTrackerTests`
Expected: 7 tests, PASS. If `testDominantMinuteSessions` fails on session boundaries, check that `base` in the test file is truly minute-aligned (`1_750_000_080 % 60 == 0`; it is: 1_750_000_080 / 60 = 29_166_668 exactly).

- [ ] **Step 4: Commit**

```bash
git add Sources/AmbitickCore/SessionTracker.swift Sources/AmbitickCore/Attributor.swift Tests/AmbitickCoreTests/SessionTrackerTests.swift
git commit -m "feat: session tracker state machine"
```

---

### Task 9: JournalStore protocol + in-memory implementation + conformance suite

**Files:**
- Create: `Sources/AmbitickCore/JournalStore.swift`
- Create: `Tests/AmbitickCoreTests/JournalStoreTests.swift`

- [ ] **Step 1: Write the conformance test suite (failing)**

The suite is an open class so Plan 2's GRDB-backed store subclasses it and inherits every test.

```swift
import XCTest
@testable import AmbitickCore

/// Conformance suite: subclass and override `makeStore()` to test any
/// JournalStore implementation. The base class itself is skipped.
open class JournalStoreConformanceTests: XCTestCase {
    open func makeStore() throws -> (any JournalStore)? { nil }

    private func store() throws -> any JournalStore {
        guard let s = try makeStore() else { throw XCTSkip("abstract base") }
        return s
    }

    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func session(_ certainty: Double, task: TaskRef = .op(1), pushed: Bool = false) -> Session {
        Session(task: task, start: t0, end: t0.addingTimeInterval(600),
                certainty: certainty, pushedToOP: pushed)
    }

    func testSavesAndListsSessions() throws {
        let s = try store()
        let a = session(0.9)
        try s.save(a)
        XCTAssertEqual(try s.allSessions(), [a])
    }

    func testPushEligibilityFiltersByThresholdPushedAndLocalOnly() throws {
        let s = try store()
        let eligible = session(0.9)
        try s.save(eligible)
        try s.save(session(0.5))                                   // below threshold
        try s.save(session(0.95, pushed: true))                    // already pushed
        try s.save(session(0.99, task: .local(UUID())))            // local-only: never pushed
        XCTAssertEqual(try s.sessions(needingPushAtOrAbove: 0.8), [eligible])
        XCTAssertEqual(try s.sessions(needingPushAtOrAbove: 1.01), [])   // the "101%" setting
    }

    func testMarkPushed() throws {
        let s = try store()
        let a = session(0.9)
        try s.save(a)
        try s.markPushed(a.id)
        XCTAssertEqual(try s.sessions(needingPushAtOrAbove: 0.8), [])
        XCTAssertEqual(try s.allSessions().first?.pushedToOP, true)
    }

    func testReviewSegmentsAssignment() throws {
        let s = try store()
        let seg1 = ReviewSegment(app: "Mystery", start: t0, end: t0.addingTimeInterval(60))
        let seg2 = ReviewSegment(app: "Other", start: t0, end: t0.addingTimeInterval(120))
        try s.save(seg1)
        try s.save(seg2)
        XCTAssertEqual(try s.pendingReview().count, 2)
        try s.assign([seg1.id], to: .task(.op(7)))
        let pending = try s.pendingReview()
        XCTAssertEqual(pending.map(\.id), [seg2.id])
    }
}

final class InMemoryJournalStoreTests: JournalStoreConformanceTests {
    override func makeStore() throws -> (any JournalStore)? { InMemoryJournalStore() }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

/// Persistence boundary. In-memory here; GRDB/SQLite implementation in the
/// macOS app (Plan 2) must pass JournalStoreConformanceTests.
public protocol JournalStore {
    func save(_ session: Session) throws
    func allSessions() throws -> [Session]
    /// Sessions eligible for OP push: certainty >= threshold, not yet pushed,
    /// and on an `.op` task (local-only tasks never push).
    func sessions(needingPushAtOrAbove threshold: Double) throws -> [Session]
    func markPushed(_ id: UUID) throws

    func save(_ segment: ReviewSegment) throws
    /// Unassigned review segments, oldest first.
    func pendingReview() throws -> [ReviewSegment]
    func assign(_ segmentIDs: [UUID], to target: Target) throws
}

public final class InMemoryJournalStore: JournalStore {
    private var sessions: [Session] = []
    private var segments: [ReviewSegment] = []

    public init() {}

    public func save(_ session: Session) throws {
        sessions.append(session)
    }

    public func allSessions() throws -> [Session] {
        sessions
    }

    public func sessions(needingPushAtOrAbove threshold: Double) throws -> [Session] {
        sessions.filter { session in
            guard case .op = session.task else { return false }
            return !session.pushedToOP && session.certainty >= threshold
        }
    }

    public func markPushed(_ id: UUID) throws {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[i].pushedToOP = true
    }

    public func save(_ segment: ReviewSegment) throws {
        segments.append(segment)
    }

    public func pendingReview() throws -> [ReviewSegment] {
        segments.filter { $0.assigned == nil }.sorted { $0.start < $1.start }
    }

    public func assign(_ segmentIDs: [UUID], to target: Target) throws {
        let ids = Set(segmentIDs)
        for i in segments.indices where ids.contains(segments[i].id) {
            segments[i].assigned = target
        }
    }
}
```

- [ ] **Step 3: Run tests (CI/Mac)**

Run: `swift test --filter JournalStore`
Expected: conformance suite SKIPPED on the base class, 4 tests PASS on `InMemoryJournalStoreTests`.

- [ ] **Step 4: Commit**

```bash
git add Sources/AmbitickCore/JournalStore.swift Tests/AmbitickCoreTests/JournalStoreTests.swift
git commit -m "feat: journal store protocol, in-memory impl, conformance suite"
```

---

### Task 10: OPClient

**Files:**
- Create: `Sources/AmbitickCore/OPClient.swift`
- Create: `Tests/AmbitickCoreTests/OPClientTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import AmbitickCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MockTransport: HTTPTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    /// Queue of (status, body) responses, consumed in order.
    var responses: [(Int, String)] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = responses.isEmpty ? (200, "{}") : responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

final class OPClientTests: XCTestCase {
    func makeClient(_ transport: MockTransport) -> OPClient {
        OPClient(baseURL: URL(string: "https://op.example.com")!,
                 apiKey: "SECRET", transport: transport)
    }

    func testFetchTasksPagesThroughAndParses() async throws {
        let transport = MockTransport()
        transport.responses = [
            (200, """
            {"total": 3, "count": 2, "_embedded": {"elements": [
              {"id": 1, "subject": "Ambitick build",
               "_links": {"status": {"title": "Now"}, "project": {"title": "Ambitick"}}},
              {"id": 2, "subject": "Timesheets",
               "_links": {"status": {"title": "Closed"}, "project": {"title": "Admin"}}}
            ]}}
            """),
            (200, """
            {"total": 3, "count": 1, "_embedded": {"elements": [
              {"id": 3, "subject": "Investment review",
               "_links": {"status": {"title": "Next"}, "project": {"title": "Investment"}}}
            ]}}
            """),
        ]
        let tasks = try await makeClient(transport).fetchTasks(pageSize: 2)
        XCTAssertEqual(tasks.count, 3)
        XCTAssertEqual(tasks[0], WorkTask(ref: .op(1), subject: "Ambitick build",
                                          project: "Ambitick", status: "Now"))
        XCTAssertEqual(transport.requests.count, 2)
        // Basic auth: base64("apikey:SECRET")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Authorization"),
                       "Basic " + Data("apikey:SECRET".utf8).base64EncodedString())
        XCTAssertTrue(transport.requests[1].url!.absoluteString.contains("offset=2"))
    }

    func testFetchActivitiesViaTimeEntryForm() async throws {
        let transport = MockTransport()
        transport.responses = [(200, """
        {"_embedded": {"schema": {"activity": {"_embedded": {"allowedValues": [
            {"id": 4, "name": "Development"}, {"id": 5, "name": "Management"}
        ]}}}}}
        """)]
        let activities = try await makeClient(transport).fetchActivities()
        XCTAssertEqual(activities, [OPTimeActivity(id: 4, name: "Development"),
                                    OPTimeActivity(id: 5, name: "Management")])
        XCTAssertEqual(transport.requests[0].httpMethod, "POST")
        XCTAssertTrue(transport.requests[0].url!.path.hasSuffix("/api/v3/time_entries/form"))
    }

    func testCreateTimeEntryBody() async throws {
        let transport = MockTransport()
        transport.responses = [(201, "{}")]
        let start = Date(timeIntervalSince1970: 1_750_000_000)
        try await makeClient(transport).createTimeEntry(
            workPackageID: 42,
            start: start,
            duration: 5_400,         // 1 h 30 m
            activityID: 4,
            comment: "Ghostty – Ambitick")
        let body = try XCTUnwrap(transport.requests[0].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["hours"] as? String, "PT1H30M")
        XCTAssertEqual(json["spentOn"] as? String, "2025-06-15")
        let links = try XCTUnwrap(json["_links"] as? [String: [String: String]])
        XCTAssertEqual(links["workPackage"]?["href"], "/api/v3/work_packages/42")
        XCTAssertEqual(links["activity"]?["href"], "/api/v3/time_entries/activities/4")
        let comment = try XCTUnwrap(json["comment"] as? [String: String])
        XCTAssertEqual(comment["raw"], "Ghostty – Ambitick")
    }

    func testNon2xxThrows() async {
        let transport = MockTransport()
        transport.responses = [(401, #"{"message": "no"}"#)]
        do {
            _ = try await makeClient(transport).fetchTasks()
            XCTFail("expected throw")
        } catch let OPClientError.httpStatus(code, _) {
            XCTAssertEqual(code, 401)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
```

Note for the engineer: `1_750_000_000` epoch = 2025-06-15 UTC. `spentOn` uses UTC; good enough for v0.1 (cross-midnight nicety is a Plan 2 concern).

- [ ] **Step 2: Implement**

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Injection point so tests never hit the network. The app supplies a
/// URLSession-backed implementation (Plan 2).
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct OPTimeActivity: Equatable, Codable, Sendable {
    public var id: Int
    public var name: String
    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public enum OPClientError: Error {
    case httpStatus(Int, String)
    case malformedResponse(String)
}

public final class OPClient {
    private let baseURL: URL
    private let apiKey: String
    private let transport: HTTPTransport

    public init(baseURL: URL, apiKey: String, transport: HTTPTransport) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.transport = transport
    }

    public var instanceHost: String { baseURL.host ?? "" }

    // MARK: - Requests

    private func request(path: String, query: [URLQueryItem] = [], method: String = "GET",
                         body: Data? = nil) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var req = URLRequest(url: components.url!)
        req.httpMethod = method
        req.httpBody = body
        let token = Data("apikey:\(apiKey)".utf8).base64EncodedString()
        req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(req)
        guard (200..<300).contains(response.statusCode) else {
            throw OPClientError.httpStatus(response.statusCode,
                                           String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: - Work packages

    private struct WPPage: Decodable {
        struct Embedded: Decodable {
            let elements: [WPElement]
        }
        let total: Int
        let count: Int
        let _embedded: Embedded
    }

    private struct WPElement: Decodable {
        struct Links: Decodable {
            struct Titled: Decodable { let title: String? }
            let status: Titled?
            let project: Titled?
        }
        let id: Int
        let subject: String
        let _links: Links
    }

    /// Pages through all work packages visible to the API key.
    /// NB: OpenProject's `offset` query parameter is a 1-BASED PAGE NUMBER,
    /// not an element offset.
    public func fetchTasks(pageSize: Int = 100) async throws -> [WorkTask] {
        var tasks: [WorkTask] = []
        var page = 1
        while true {
            let data = try await send(request(
                path: "api/v3/work_packages",
                query: [URLQueryItem(name: "pageSize", value: String(pageSize)),
                        URLQueryItem(name: "offset", value: String(page))]))
            let decoded = try decode(WPPage.self, from: data)
            tasks += decoded._embedded.elements.map {
                WorkTask(ref: .op($0.id), subject: $0.subject,
                         project: $0._links.project?.title,
                         status: $0._links.status?.title ?? "Unknown")
            }
            page += 1
            if tasks.count >= decoded.total || decoded.count == 0 { break }
        }
        return tasks
    }

    // MARK: - Time entry activities

    private struct FormResponse: Decodable {
        struct Embedded: Decodable {
            struct Schema: Decodable {
                struct Activity: Decodable {
                    struct Inner: Decodable { let allowedValues: [OPTimeActivity] }
                    let _embedded: Inner
                }
                let activity: Activity
            }
            let schema: Schema
        }
        let _embedded: Embedded
    }

    /// Allowed activities come from the time-entry creation form schema.
    /// (Engineer note: some OP versions return allowedValues as a link rather
    /// than embedded. If Martin's instance does, this surfaces as
    /// `malformedResponse` at integration time – adjust the decode then, with
    /// a captured real response as the new test fixture.)
    public func fetchActivities() async throws -> [OPTimeActivity] {
        let data = try await send(request(path: "api/v3/time_entries/form",
                                          method: "POST", body: Data("{}".utf8)))
        return try decode(FormResponse.self, from: data)._embedded.schema.activity._embedded.allowedValues
    }

    // MARK: - Time entries

    public func createTimeEntry(workPackageID: Int, start: Date, duration: TimeInterval,
                                activityID: Int, comment: String?) async throws {
        var payload: [String: Any] = [
            "hours": Self.iso8601Duration(duration),
            "spentOn": Self.dayFormatter.string(from: start),
            "_links": [
                "workPackage": ["href": "/api/v3/work_packages/\(workPackageID)"],
                "activity": ["href": "/api/v3/time_entries/activities/\(activityID)"],
            ],
        ]
        if let comment {
            payload["comment"] = ["raw": comment]
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await send(request(path: "api/v3/time_entries", method: "POST", body: body))
    }

    // MARK: - Helpers

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OPClientError.malformedResponse(String(describing: error))
        }
    }

    static func iso8601Duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        return "PT\(h)H\(m)M"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
```

- [ ] **Step 3: Run tests (CI/Mac)**

Run: `swift test --filter OPClientTests`
Expected: 4 tests, PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/AmbitickCore/OPClient.swift Tests/AmbitickCoreTests/OPClientTests.swift
git commit -m "feat: OpenProject API client over injectable transport"
```

---

### Task 11: SyncEngine

**Files:**
- Create: `Sources/AmbitickCore/SyncEngine.swift`
- Create: `Tests/AmbitickCoreTests/SyncEngineTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import AmbitickCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SyncEngineTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func makeWorld() -> (SyncEngine, InMemoryJournalStore, MockTransport) {
        let journal = InMemoryJournalStore()
        let transport = MockTransport()
        let client = OPClient(baseURL: URL(string: "https://op.example.com")!,
                              apiKey: "k", transport: transport)
        let engine = SyncEngine(journal: journal, client: client)
        return (engine, journal, transport)
    }

    func testPushesEligibleAndMarks() async throws {
        let (engine, journal, transport) = makeWorld()
        transport.responses = [(201, "{}")]
        try journal.save(Session(task: .op(42), start: t0, end: t0.addingTimeInterval(1800),
                                 certainty: 0.9, comment: "Ghostty – Ambitick"))
        try journal.save(Session(task: .op(43), start: t0, end: t0.addingTimeInterval(60),
                                 certainty: 0.4))   // below threshold: stays local
        let pushed = try await engine.pushEligible(threshold: 0.8, defaultActivityID: 4,
                                                   includeComments: true)
        XCTAssertEqual(pushed, 1)
        XCTAssertEqual(transport.requests.count, 1)
        let body = try JSONSerialization.jsonObject(with: transport.requests[0].httpBody!) as! [String: Any]
        XCTAssertEqual(body["hours"] as? String, "PT0H30M")
        XCTAssertEqual((body["comment"] as? [String: String])?["raw"], "Ghostty – Ambitick")
        XCTAssertEqual(try journal.sessions(needingPushAtOrAbove: 0.8), [])
    }

    func testActivityOverridePerTask() async throws {
        let (engine, journal, transport) = makeWorld()
        transport.responses = [(201, "{}")]
        try journal.save(Session(task: .op(42), start: t0, end: t0.addingTimeInterval(600),
                                 certainty: 1))
        _ = try await engine.pushEligible(threshold: 0.8, defaultActivityID: 4,
                                          activityOverrides: [.op(42): 9],
                                          includeComments: false)
        let body = try JSONSerialization.jsonObject(with: transport.requests[0].httpBody!) as! [String: Any]
        let links = body["_links"] as! [String: [String: String]]
        XCTAssertEqual(links["activity"]?["href"], "/api/v3/time_entries/activities/9")
        XCTAssertNil(body["comment"])
    }

    func testFailedPushLeavesSessionUnmarked() async throws {
        let (engine, journal, transport) = makeWorld()
        transport.responses = [(500, "{}")]
        try journal.save(Session(task: .op(42), start: t0, end: t0.addingTimeInterval(600),
                                 certainty: 1))
        let pushed = try? await engine.pushEligible(threshold: 0.8, defaultActivityID: 4,
                                                    includeComments: false)
        XCTAssertNotEqual(pushed, 1)
        XCTAssertEqual(try journal.sessions(needingPushAtOrAbove: 0.8).count, 1,
                       "failed push must remain queued")
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

/// Pushes journalled sessions to OP once they clear the user's certainty
/// threshold. The journal stays the source of truth; a failed push leaves
/// the session queued.
public final class SyncEngine {
    private let journal: any JournalStore
    private let client: OPClient

    public init(journal: any JournalStore, client: OPClient) {
        self.journal = journal
        self.client = client
    }

    /// Returns the number of sessions pushed. Throws on the first failure,
    /// leaving that session and later ones unmarked for retry.
    @discardableResult
    public func pushEligible(threshold: Double, defaultActivityID: Int,
                             activityOverrides: [TaskRef: Int] = [:],
                             includeComments: Bool) async throws -> Int {
        var pushed = 0
        for session in try journal.sessions(needingPushAtOrAbove: threshold) {
            guard case .op(let wpID) = session.task else { continue }
            try await client.createTimeEntry(
                workPackageID: wpID,
                start: session.start,
                duration: session.end.timeIntervalSince(session.start),
                activityID: activityOverrides[session.task] ?? defaultActivityID,
                comment: includeComments ? session.comment : nil)
            try journal.markPushed(session.id)
            pushed += 1
        }
        return pushed
    }
}
```

- [ ] **Step 3: Run tests (CI/Mac)**

Run: `swift test --filter SyncEngineTests`
Expected: 3 tests, PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/AmbitickCore/SyncEngine.swift Tests/AmbitickCoreTests/SyncEngineTests.swift
git commit -m "feat: threshold-gated sync engine"
```

---

### Task 12: AIAssist (prompt out, strict JSON back)

**Files:**
- Create: `Sources/AmbitickCore/AIAssist.swift`
- Create: `Tests/AmbitickCoreTests/AIAssistTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import AmbitickCore

final class AIAssistTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let segID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    var tasks: [WorkTask] {
        [WorkTask(ref: .op(1), subject: "Ambitick build", project: "Ambitick", status: "Now")]
    }
    var segments: [ReviewSegment] {
        [ReviewSegment(id: segID, app: "Chrome", windowTitle: "Spreadsheet xyz",
                       start: t0, end: t0.addingTimeInterval(300))]
    }

    func testPromptContainsTasksSegmentsAndFormatContract() {
        let prompt = AIAssist.classificationPrompt(tasks: tasks, segments: segments)
        XCTAssertTrue(prompt.contains("Ambitick build"))
        XCTAssertTrue(prompt.contains("#1"))
        XCTAssertTrue(prompt.contains(segID.uuidString))
        XCTAssertTrue(prompt.contains("Spreadsheet xyz"))
        XCTAssertTrue(prompt.contains(#""assignments""#))
        XCTAssertTrue(prompt.contains("do-not-track"))
    }

    func testParsesValidResponse() throws {
        let json = """
        {"assignments": [
          {"segment": "\(segID.uuidString)", "task": 1},
          {"segment": "\(segID.uuidString)", "task": "do-not-track"}
        ]}
        """
        let parsed = try AIAssist.parseResponse(json, validSegmentIDs: [segID])
        XCTAssertEqual(parsed, [
            AIAssist.Assignment(segmentID: segID, target: .task(.op(1))),
            AIAssist.Assignment(segmentID: segID, target: .doNotTrack),
        ])
    }

    func testRejectsUnknownSegmentAndGarbage() {
        XCTAssertThrowsError(try AIAssist.parseResponse(
            #"{"assignments": [{"segment": "\#(UUID().uuidString)", "task": 1}]}"#,
            validSegmentIDs: [segID]))
        XCTAssertThrowsError(try AIAssist.parseResponse("not json", validSegmentIDs: [segID]))
        XCTAssertThrowsError(try AIAssist.parseResponse(
            #"{"assignments": [{"segment": "\#(segID.uuidString)", "task": true}]}"#,
            validSegmentIDs: [segID]))
    }

    func testToleratesCodeFenceWrapping() throws {
        let json = """
        ```json
        {"assignments": [{"segment": "\(segID.uuidString)", "task": 1}]}
        ```
        """
        let parsed = try AIAssist.parseResponse(json, validSegmentIDs: [segID])
        XCTAssertEqual(parsed.count, 1)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

/// Cold-start AI assist. v0.1 has NO API integration: the app copies a prompt
/// to the clipboard, the user pastes it into the AI of their choice, then
/// pastes the response back. Strict validation on the way back in.
public enum AIAssist {
    public struct Assignment: Equatable, Sendable {
        public var segmentID: UUID
        public var target: Target
        public init(segmentID: UUID, target: Target) {
            self.segmentID = segmentID
            self.target = target
        }
    }

    public enum ParseError: Error {
        case notJSON
        case badShape(String)
        case unknownSegment(String)
        case badTask(String)
    }

    public static func classificationPrompt(tasks: [WorkTask], segments: [ReviewSegment]) -> String {
        var lines: [String] = []
        lines.append("You are classifying time-tracking log segments against a task list.")
        lines.append("")
        lines.append("TASKS (id: subject [project, status]):")
        for t in tasks {
            if case .op(let id) = t.ref {
                lines.append("#\(id): \(t.subject) [\(t.project ?? "-"), \(t.status)]")
            }
        }
        lines.append("")
        lines.append("SEGMENTS (uuid | app | window title | url | minutes):")
        for s in segments {
            let minutes = Int(s.end.timeIntervalSince(s.start) / 60)
            lines.append("\(s.id.uuidString) | \(s.app) | \(s.windowTitle ?? "-") | \(s.tabURL ?? "-") | \(minutes)")
        }
        lines.append("")
        lines.append("""
        Reply with ONLY this JSON, no prose:
        {"assignments": [{"segment": "<uuid>", "task": <task id number or "do-not-track">}]}
        Use "do-not-track" for segments that are clearly not work on any listed task.
        """)
        return lines.joined(separator: "\n")
    }

    public static func parseResponse(_ raw: String, validSegmentIDs: Set<UUID>) throws -> [Assignment] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate ```json fences that chat UIs love to add.
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.notJSON
        }
        guard let list = obj["assignments"] as? [[String: Any]] else {
            throw ParseError.badShape("missing assignments array")
        }
        return try list.map { entry in
            guard let idString = entry["segment"] as? String, let id = UUID(uuidString: idString) else {
                throw ParseError.badShape("bad segment field: \(entry)")
            }
            guard validSegmentIDs.contains(id) else {
                throw ParseError.unknownSegment(idString)
            }
            let target: Target
            if let n = entry["task"] as? Int, !(entry["task"] is Bool) {
                target = .task(.op(n))
            } else if let s = entry["task"] as? String, s == "do-not-track" {
                target = .doNotTrack
            } else {
                throw ParseError.badTask(String(describing: entry["task"]))
            }
            return Assignment(segmentID: id, target: target)
        }
    }
}
```

(Engineer note: on Linux, `entry["task"] as? Int` can succeed for JSON `true`; the explicit `is Bool` guard keeps the garbage test honest on both platforms.)

- [ ] **Step 3: Run tests (CI/Mac)**

Run: `swift test --filter AIAssistTests`
Expected: 4 tests, PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/AmbitickCore/AIAssist.swift Tests/AmbitickCoreTests/AIAssistTests.swift
git commit -m "feat: AI-assist prompt builder and strict response parser"
```

---

### Task 13: Settings + JSONFileStore

**Files:**
- Create: `Sources/AmbitickCore/Settings.swift`
- Create: `Tests/AmbitickCoreTests/SettingsTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import AmbitickCore

final class SettingsTests: XCTestCase {
    func testDefaults() {
        let s = AmbitickSettings(opBaseURL: "https://op.example.com")
        XCTAssertEqual(s.certaintyAutoPushThreshold, 0.8)
        XCTAssertEqual(s.statusOrder, ["Now", "Next", "Open", "Closed"])
        XCTAssertEqual(s.recentCount, 5)
        XCTAssertEqual(s.likelyCount, 5)
        XCTAssertFalse(s.showPercent)
        XCTAssertTrue(s.autoComment)
        XCTAssertFalse(s.trackLeisureLocally)
        XCTAssertEqual(s.colourLow, "#FF3B30")
        XCTAssertEqual(s.colourHigh, "#34C759")
    }

    func testNeverAutoPushIsRepresentable() {
        var s = AmbitickSettings(opBaseURL: "https://op.example.com")
        s.certaintyAutoPushThreshold = 1.01   // the "101%": nothing auto-pushes
        XCTAssertGreaterThan(s.certaintyAutoPushThreshold, 1.0)
    }

    func testFileStoreRoundTripAndMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ambitick-tests-\(UUID().uuidString)")
        let store = JSONFileStore<AmbitickSettings>(
            url: dir.appendingPathComponent("settings.json"))
        XCTAssertNil(try store.load())
        var s = AmbitickSettings(opBaseURL: "https://op.example.com")
        s.defaultActivityID = 4
        s.activityOverrides[.op(42)] = 9
        try store.save(s)
        XCTAssertEqual(try store.load(), s)
        try? FileManager.default.removeItem(at: dir)
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

/// All user-tunable knobs. The OP API key is NOT here – it lives in the
/// macOS Keychain (Plan 2). Persist via JSONFileStore.
public struct AmbitickSettings: Codable, Equatable, Sendable {
    public var opBaseURL: String
    public var recentCount: Int
    public var likelyCount: Int
    /// Sessions at/above this certainty auto-push to OP. > 1.0 means never.
    public var certaintyAutoPushThreshold: Double
    public var colourLow: String      // hex; certainty 0 end of the gradient
    public var colourHigh: String     // hex; certainty 1 end
    public var showPercent: Bool
    public var defaultActivityID: Int?
    public var activityOverrides: [TaskRef: Int]
    public var autoComment: Bool
    public var trackLeisureLocally: Bool
    public var statusOrder: [String]
    public var primeDwellSeconds: Double
    public var minSegmentSeconds: Double

    public init(opBaseURL: String,
                recentCount: Int = 5,
                likelyCount: Int = 5,
                certaintyAutoPushThreshold: Double = 0.8,
                colourLow: String = "#FF3B30",
                colourHigh: String = "#34C759",
                showPercent: Bool = false,
                defaultActivityID: Int? = nil,
                activityOverrides: [TaskRef: Int] = [:],
                autoComment: Bool = true,
                trackLeisureLocally: Bool = false,
                statusOrder: [String] = ["Now", "Next", "Open", "Closed"],
                primeDwellSeconds: Double = 30,
                minSegmentSeconds: Double = 20) {
        self.opBaseURL = opBaseURL
        self.recentCount = recentCount
        self.likelyCount = likelyCount
        self.certaintyAutoPushThreshold = certaintyAutoPushThreshold
        self.colourLow = colourLow
        self.colourHigh = colourHigh
        self.showPercent = showPercent
        self.defaultActivityID = defaultActivityID
        self.activityOverrides = activityOverrides
        self.autoComment = autoComment
        self.trackLeisureLocally = trackLeisureLocally
        self.statusOrder = statusOrder
        self.primeDwellSeconds = primeDwellSeconds
        self.minSegmentSeconds = minSegmentSeconds
    }
}

/// Tiny atomic JSON persistence for any Codable (settings, LearningStore, ...).
public final class JSONFileStore<Value: Codable> {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
```

(Note: `[TaskRef: Int]` encodes as a flat array of alternating keys/values in JSON – ugly but round-trips fine; do not hand-edit the settings file's overrides section.)

- [ ] **Step 3: Run tests (CI/Mac)**

Run: `swift test --filter SettingsTests`
Expected: 3 tests, PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/AmbitickCore/Settings.swift Tests/AmbitickCoreTests/SettingsTests.swift
git commit -m "feat: settings model and JSON file store"
```

---

### Task 14: End-to-end Core test

**Files:**
- Create: `Tests/AmbitickCoreTests/EndToEndTests.swift`

A scripted day driven through the full pipeline: sensors (faked) → tracker → journal → sync → mocked OP. This is the test that proves the modules compose; it is also the template for Plan 2's wiring.

- [ ] **Step 1: Write the test**

```swift
import XCTest
@testable import AmbitickCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class EndToEndTests: XCTestCase {
    func testAFullTrackedStretchReachesOpenProject() async throws {
        let base = Date(timeIntervalSince1970: 1_750_000_080)   // minute-aligned
        func t(_ s: TimeInterval) -> Date { base.addingTimeInterval(s) }

        let tasks = [WorkTask(ref: .op(1), subject: "Ambitick build", status: "Now")]
        let journal = InMemoryJournalStore()
        let transport = MockTransport()
        transport.responses = [(201, "{}")]
        let client = OPClient(baseURL: URL(string: "https://op.example.com")!,
                              apiKey: "k", transport: transport)
        let attributor = Attributor(instanceHost: "op.example.com")
        let tracker = SessionTracker(attributor: attributor,
                                     config: TrackerConfig()) { tasks }
        tracker.onSession = { try? journal.save($0) }
        tracker.onReview = { try? journal.save($0) }

        // The scripted stretch:
        // 1. open WP 1 in OP -> auto-start at 0.99
        tracker.handle(.focus(ActivitySignal(
            app: "Chrome", windowTitle: "WP1",
            tabURL: "https://op.example.com/work_packages/1", timestamp: t(0))))
        // 2. switch to Ghostty; user confirms the task via the popover
        tracker.handle(.focus(ActivitySignal(app: "Ghostty", windowTitle: "Ambitick", timestamp: t(20))))
        tracker.confirm(task: .op(1), at: t(25))
        // 3. keep working in the same window (re-focus events as minutes pass)
        tracker.handle(.focus(ActivitySignal(app: "Ghostty", windowTitle: "Ambitick", timestamp: t(600))))
        tracker.handle(.input(t(1190)))
        // 4. stop after ~20 min
        tracker.stop(at: t(1200))

        let sessions = try journal.allSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].task, .op(1))
        XCTAssertEqual(sessions[0].start, t(0))
        XCTAssertEqual(sessions[0].end, t(1200))
        XCTAssertGreaterThanOrEqual(sessions[0].certainty, 0.95)

        // 5. sync pushes exactly one PT0H20M entry
        let engine = SyncEngine(journal: journal, client: client)
        let pushed = try await engine.pushEligible(threshold: 0.8, defaultActivityID: 4,
                                                   includeComments: true)
        XCTAssertEqual(pushed, 1)
        let body = try JSONSerialization.jsonObject(
            with: transport.requests[0].httpBody!) as! [String: Any]
        XCTAssertEqual(body["hours"] as? String, "PT0H20M")
        XCTAssertEqual(try journal.sessions(needingPushAtOrAbove: 0.8), [])
    }
}
```

- [ ] **Step 2: Run the FULL suite (CI/Mac)**

Run: `swift test`
Expected: all tests pass, 0 failures. Span arithmetic if the session bounds
disagree: auto-start tracks from t(0); Chrome span t(0)–t(20) at 0.99; the
`tracker.confirm` at t(25) lifts state certainty to 0.95 BEFORE the in-flight
Ghostty span is closed, so both Ghostty spans (t(20)–t(600), t(600)–t(1200))
record 0.95. All minutes are dominated by op(1) → one session t(0)–t(1200),
certainty = min(0.99, 0.95, 0.95) = 0.95.

- [ ] **Step 3: Commit and push; verify CI green**

```bash
git add Tests/AmbitickCoreTests/EndToEndTests.swift
git commit -m "test: end-to-end core pipeline"
git push
```

Run: `gh run watch --exit-status` (or Martin: `swift test` on the Mac)
Expected: CI green across the whole suite.

---

### Task 15: Close out

- [ ] **Step 1: Update CHANGELOG.md** (create it – first successful close):

```markdown
# Changelog

## 2026-06-10

- [x] **AmbitickCore v0.1** — Pure-Swift core library: domain models, OP URL
  parsing, learning store, task ranking, attribution with OP task-priming,
  dominant-minute session tracking, journal protocol + in-memory store,
  OpenProject client, threshold-gated sync, AI-assist prompt/parser, settings.
  Tested on Linux CI (`swift test`, N tests). Spec:
  docs/superpowers/specs/2026-06-10-ambitick-design.md. Commits: <range>.
```

(Fill `N` and `<range>` from reality. Same-commit rule: amend alongside the final code commit or commit immediately after the push above.)

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: changelog for AmbitickCore v0.1"
git push
```

- [ ] **Step 3: Confirm with Martin before starting Plan 2** (macOS app: sensors, menu bar UI, review window, GRDB store, Keychain, notifications, README setup docs).
