import Foundation

/// Infinite, session-bounded undo of data edits (timeline, review, local
/// tasks, colours) — the pure stack + grouping semantics behind the app's
/// global ⌘Z, extracted from AppController so it's checkable and sharable.
/// Not thread-safe: owned and driven by the main-actor controller.
package final class UndoStack {
    package typealias Inverse = () async -> Void

    /// One step. `redo` is the explicit replay a converted site supplies
    /// (2026-08-13 undo-redo spec); nil = a legacy entry whose undo is a
    /// non-redoable boundary unless its inverse re-registers while running.
    package struct Entry {
        package var label: String
        package var undo: Inverse
        package var redo: Inverse?
    }

    /// NSUndoManager-style routing (see the 2026-08-13 spec): registrations
    /// made WHILE an undo inverse runs build the redo entry; registrations
    /// made while a redo replay runs rebuild the undo entry; normal
    /// registrations clear the redo stack (a fresh edit invalidates the
    /// redo future).
    private enum Mode { case normal, undoing, redoing }
    private var mode: Mode = .normal
    /// Registrations collected during the CURRENT undo/redo run.
    private var collected: [(label: String, inverse: Inverse)] = []

    private var stack: [Entry] = []
    private var redoStack: [Entry] = []
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
    package var redoCount: Int { redoStack.count }

    package func register(_ label: String, inverse: @escaping Inverse) {
        register(label, inverse: inverse, redo: nil)
    }

    /// A registration whose forward effect can be REPLAYED id-stably —
    /// undoing it arms ⌘⇧Z instead of clearing the redo future (2026-08-13
    /// spec; conversions per its replay-stability rule).
    package func register(_ label: String, inverse: @escaping Inverse,
                          redo: Inverse?) {
        switch mode {
        case .undoing, .redoing:
            // Route to the run's collection — endUndo/endRedo turns it into
            // the opposite stack's entry. Groups don't apply mid-replay.
            collected.append((label, inverse))
        case .normal:
            if pendingGroupToken != nil, Self.activeGroupToken == pendingGroupToken {
                pendingGroup?.append(inverse)   // in-context: the group pushes one entry
            } else {
                stack.append(Entry(label: label, undo: inverse, redo: redo))
            }
            // A fresh edit invalidates whatever was undone before it.
            redoStack.removeAll()
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
            stack.append(Entry(label: label,
                               undo: { for inverse in group.reversed() { await inverse() } },
                               redo: nil))
        }
    }

    /// The most recent entry, removed. The caller runs the inverse (and owns
    /// the user-facing notification). nil when there is nothing to undo.
    /// Prefer `performUndo` — this raw pop exists for the legacy banner
    /// paths and bypasses redo bookkeeping (the popped entry's redo future
    /// is deliberately dropped).
    package func pop() -> (label: String, inverse: Inverse)? {
        redoStack.removeAll()
        return stack.popLast().map { ($0.label, $0.undo) }
    }

    // MARK: - Undo/redo execution (2026-08-13 spec)

    /// Pop and run the most recent undo entry, arming redo per the spec's
    /// routing rules. Returns its label, nil when the stack is empty. The
    /// closure runs to completion before this returns (caller supplies the
    /// serial context, exactly as with `pop`).
    package func performUndo() async -> String? {
        guard let entry = stack.popLast() else { return nil }
        mode = .undoing
        collected = []
        await entry.undo()
        mode = .normal
        if !collected.isEmpty {
            // The inverse re-registered — those registrations ARE the redo.
            let group = collected.map(\.inverse)
            redoStack.append(Entry(label: entry.label,
                                   undo: { for inverse in group.reversed() { await inverse() } },
                                   redo: nil))
        } else if entry.redo != nil {
            redoStack.append(entry)
        } else {
            // A non-redoable boundary: nothing beyond it can be replayed
            // soundly, so ⌘⇧Z goes honestly quiet rather than skipping steps.
            redoStack.removeAll()
        }
        collected = []
        return entry.label
    }

    /// Pop and run the most recent redo entry; the undone step returns to
    /// the undo stack (via the replay's own registrations when it made any,
    /// else the original entry — its snapshot inverse is still valid because
    /// conversions are id-stable by rule). Returns its label, nil when empty.
    package func performRedo() async -> String? {
        guard let entry = redoStack.popLast() else { return nil }
        mode = .redoing
        collected = []
        if let redo = entry.redo {
            await redo()
        } else {
            await entry.undo()   // an inverse-built redo entry: run what was collected
        }
        mode = .normal
        if !collected.isEmpty {
            let group = collected.map(\.inverse)
            stack.append(Entry(label: entry.label,
                               undo: { for inverse in group.reversed() { await inverse() } },
                               redo: entry.redo))
        } else {
            stack.append(entry)
        }
        collected = []
        return entry.label
    }
}
