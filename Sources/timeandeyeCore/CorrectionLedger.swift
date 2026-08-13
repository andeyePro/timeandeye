import Foundation

/// The correction LEDGER (Martin's 13 Aug reply 9: "start tracking all my
/// corrections and showing me what has been corrected based on what
/// correction. We need to know how the correction was made too."). Every
/// gesture that writes persistent learning state — the exact write-point
/// inventory in the 2026-08-13 over-learning diagnosis — appends one record
/// here: when, which gesture, on what surface, teaching what, at what
/// weight, displacing what. The Evidence Card names the record behind a
/// learned association ("taught 2 Aug — reassign on Ambi4-fromMartin"), and
/// the Rules Ledger lists them. Append-only in use; bounded by `prune`.
package struct CorrectionLedger: Codable, Equatable, Sendable {
    /// One learning write. `gesture` is a raw verb (like
    /// `SessionProvenance.sourceRaw`) so a future rename can never mis-read
    /// old ledgers: "pick", "reassign", "reviewAssign", "walkConfirm",
    /// "aiApplied", "timelineReassign", "spentMove", "allocate",
    /// "dontTrack", "boost", "rememberRule", "alwaysRule", "forget".
    package struct Record: Codable, Equatable, Sendable, Identifiable {
        package var id: UUID
        package var at: Date
        package var gesture: String
        /// The taught surface's identity (normalised, same key learning
        /// uses) plus the raw signal fields for display and for rebuilding
        /// features if this record's teaching is ever forgotten wholesale.
        package var app: String
        package var windowTitle: String?
        package var tabURL: String?
        package var target: Target
        package var weight: Double
        /// The belief this correction displaced and discounted, when the
        /// operator's discount arm fired (ranked or primed displacement).
        package var displaced: Target?
        /// True for a forget/suppress (weight is what was erased-toward: 0
        /// when unknown) — the ledger shows un-learning honestly too.
        package var isForget: Bool

        package init(id: UUID = UUID(), at: Date, gesture: String, app: String,
                    windowTitle: String? = nil, tabURL: String? = nil,
                    target: Target, weight: Double, displaced: Target? = nil,
                    isForget: Bool = false) {
            self.id = id
            self.at = at
            self.gesture = gesture
            self.app = app
            self.windowTitle = windowTitle
            self.tabURL = tabURL
            self.target = target
            self.weight = weight
            self.displaced = displaced
            self.isForget = isForget
        }

        /// The surface this record taught, derived the same way learning
        /// derived it (so lookups can never disagree with what was keyed).
        package var surface: Surface {
            Surface(signal: ActivitySignal(app: app, windowTitle: windowTitle,
                                           tabURL: tabURL, timestamp: at))
        }
    }

    package private(set) var records: [Record] = []

    /// Retention: enough to explain anything a user will realistically ask
    /// about, small enough that corrections.json stays trivial.
    package static let maxRecords = 2000
    package static let maxAge: TimeInterval = 180 * 86_400

    package init() {}

    package mutating func append(_ record: Record) {
        records.append(record)
        if records.count > Self.maxRecords {
            records.removeFirst(records.count - Self.maxRecords)
        }
    }

    /// Drop records past retention. Called at load, not on every append.
    package mutating func prune(now: Date = Date()) {
        let floor = now.addingTimeInterval(-Self.maxAge)
        records.removeAll { $0.at < floor }
    }

    /// The most recent TEACH toward `target` whose taught surface matches
    /// this signal's surface exactly, else the most recent one sharing the
    /// app — how the card names the correction behind a learned association.
    /// Exact surface beats app-level however old, because it IS the prime's
    /// own key; app-level is the honest "a correction on some <app> window"
    /// story behind generic-feature pull.
    package func lastTeach(toward target: Target, for signal: ActivitySignal) -> Record? {
        let surface = Surface(signal: signal)
        let teaches = records.reversed().filter { !$0.isForget && $0.target == target }
        if let exact = teaches.first(where: { $0.surface == surface }) { return exact }
        let app = signal.app.lowercased()
        return teaches.first { $0.app.lowercased() == app }
    }

    /// Ledger view feed: newest first.
    package var newestFirst: [Record] { records.reversed() }
}
