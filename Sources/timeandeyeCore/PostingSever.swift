import Foundation

/// The two laws every linkage-severing user path (timeline edit, delete,
/// reassign, coalesce, reconcile) must obey — factored out of the controller
/// so the LAW is pinned in Core, check-first, exactly as `ContradictionRefile`
/// models the refile sever decision.
///
/// A "sever" is any user action that breaks a session's live link to a remote
/// backend entry: the task changed, the session was deleted, its slices were
/// merged away. Each sever has exactly one lawful compensation:
///
///   - **The lock law.** A cell covered by a SENT invoice (`lockedInvoiceRef`)
///     is frozen against every path. The local edit still stands (the user's
///     word about where time went), but the billed remote entry is never
///     deleted and never amended — the cell parks `.diverged` and a human
///     reconciles at invoicing time. No path touches billed time, ever.
///   - **The compensation law.** An unlocked live entry is retracted now. If
///     the immediate remote delete FAILS, the row may not be cleared — it
///     survives (`.failed`, `entryID` retained, marked with `retractIntentReason`)
///     so the engine's next pass completes the retraction. Clearing on failure
///     would orphan a live backend entry no scan can ever see again.
package enum PostingSever {

    /// Marker `lastError` on a `.failed` row that still carries an `entryID`
    /// and means "a user path severed this linkage but the immediate remote
    /// delete failed — RETRACT this entry (do not re-post it)".
    ///
    /// Deliberately DISTINCT from the resurrection demote, which also leaves a
    /// `.failed`-with-`entryID` row but whose reason says the entry *vanished*
    /// and means the opposite (re-POST). The two share the state but never the
    /// reason, so `amendDiverged`'s retract sweep and the queue can tell a
    /// sever's unfinished retraction from a resurrection's pending re-post.
    package static let retractIntentReason = "linkage severed — retract this entry"

    /// What a sever must do about the remote entry, computed from the cell
    /// BEFORE any wire call so the lock law is honoured up front.
    package enum Plan: Equatable, Sendable {
        /// No live linkage to sever (no entry, empty/`.pending` cell).
        case noLinkage
        /// Lock law: billed time — never touch the remote entry; park `.diverged`.
        case locked
        /// Retract this entry now; on delete failure retain it (compensation law).
        case retract(entryID: RemoteEntryID)
    }

    /// `cell` is the (session, backend) ledger row; `entryID` is the linkage
    /// the caller intends to break (the pm mirror's `opTimeEntryID`, or the
    /// cell's own `entryID` for a finance backend).
    package static func plan(cell: PostingRecord?, entryID: RemoteEntryID?) -> Plan {
        if cell?.lockedInvoiceRef != nil { return .locked }
        if let entryID { return .retract(entryID: entryID) }
        return .noLinkage
    }
}
