import Foundation

/// Infinite, session-bounded undo of data edits (timeline, review, local
/// tasks, colours) — the pure stack + grouping semantics behind the app's
/// global ⌘Z, extracted from AppController so it's checkable and sharable.
/// Not thread-safe: owned and driven by the main-actor controller.
package final class UndoStack {
    package typealias Inverse = () async -> Void

    private var stack: [(label: String, inverse: Inverse)] = []
    /// Non-nil while inside `group`: inverses accumulate here and the group
    /// pushes ONE entry when the outermost body finishes.
    private var pendingGroup: [Inverse]?
    /// Identifies the open group. A registration folds in ONLY when it runs
    /// inside this group's OWN task context (`activeGroupToken` matches) —
    /// see `register`.
    private var pendingGroupToken: Int?
    private static var tokenSeq = 0

    /// The group a registration belongs to, carried down the group body's
    /// synchronous + awaited call tree (task-locals propagate through `await`
    /// but NOT into a separately-spawned `Task`). This is the reentrancy
    /// guard: a `group` body that awaits yields the main actor, and any
    /// UNRELATED registration that interleaves during that suspension runs
    /// with no (or a different) token, so it lands as its own ⌘Z step instead
    /// of being swallowed under the open group's label.
    @TaskLocal private static var activeGroupToken: Int?

    package init() {}

    package var count: Int { stack.count }

    package func register(_ label: String, inverse: @escaping Inverse) {
        if pendingGroupToken != nil, Self.activeGroupToken == pendingGroupToken {
            pendingGroup?.append(inverse)   // in-context: the group pushes one entry
        } else {
            stack.append((label, inverse))
        }
    }

    /// Bundle every mutation registered in `body` into ONE undo step (a handle
    /// drag that overwrites several records, or an overlap save that trims a
    /// neighbour and moves a slice, undoes in a single ⌘Z). Nestable — inner
    /// groups fold into the outermost. An empty group pushes nothing.
    package func group(_ label: String, _ body: () async -> Void) async {
        let (token, outer) = beginGroup()
        await Self.$activeGroupToken.withValue(token) { await body() }
        endGroup(label, outer: outer)
    }

    /// Same one-⌘Z-step bundling for callers that CANNOT await: the AI-assist
    /// ingest applies N review assignments from inside a synchronous button
    /// handler (it returns a status string to display), where forcing the
    /// async `group` would ripple an async signature through the review UI.
    /// Inverses are still async and replay reversed on undo; the two flavours
    /// nest freely (both fold into whichever group is outermost). A distinct
    /// name, not a `group` overload: trailing-closure syntax drops argument
    /// labels, so an overload would silently re-route existing sync-bodied
    /// `await group { … }` callers here.
    package func groupSync(_ label: String, _ body: () -> Void) {
        let (token, outer) = beginGroup()
        Self.$activeGroupToken.withValue(token) { body() }
        endGroup(label, outer: outer)
    }

    /// Establish (or nest into) the open group, returning its token and
    /// whether THIS call owns the final push.
    private func beginGroup() -> (token: Int, outer: Bool) {
        // Genuine nesting: this call runs inside the open group's own context
        // (an awaited inner group). Reuse the token so its registrations still
        // fold in; not outer, so it pushes nothing of its own.
        if let open = pendingGroupToken, Self.activeGroupToken == open {
            return (open, false)
        }
        Self.tokenSeq += 1
        let token = Self.tokenSeq
        // Own the pending slot only when none is open. A group that begins
        // while an UNRELATED group is mid-await (a stray task) must NOT seize
        // the slot and swallow the stranger's inverses; it runs under its own
        // token, so its registrations land as individual undo steps.
        if pendingGroup == nil {
            pendingGroup = []
            pendingGroupToken = token
            return (token, true)
        }
        return (token, false)
    }

    private func endGroup(_ label: String, outer: Bool) {
        guard outer, let group = pendingGroup else { return }
        pendingGroup = nil
        pendingGroupToken = nil
        if !group.isEmpty {
            stack.append((label, { for inverse in group.reversed() { await inverse() } }))
        }
    }

    /// The most recent entry, removed. The caller runs the inverse (and owns
    /// the user-facing notification). nil when there is nothing to undo.
    package func pop() -> (label: String, inverse: Inverse)? {
        stack.popLast()
    }
}
