import Foundation

/// Infinite, session-bounded undo of data edits (timeline, review, local
/// tasks, colours) — the pure stack + grouping semantics behind the app's
/// global ⌘Z, extracted from AppController so it's checkable and sharable.
/// Not thread-safe: owned and driven by the main-actor controller.
public final class UndoStack {
    public typealias Inverse = () async -> Void

    private var stack: [(label: String, inverse: Inverse)] = []
    /// Non-nil while inside `group`: inverses accumulate here and the group
    /// pushes ONE entry when the outermost body finishes.
    private var pendingGroup: [Inverse]?

    public init() {}

    public var count: Int { stack.count }

    public func register(_ label: String, inverse: @escaping Inverse) {
        if pendingGroup != nil {
            pendingGroup?.append(inverse)   // accumulate; the group pushes one entry
        } else {
            stack.append((label, inverse))
        }
    }

    /// Bundle every mutation registered in `body` into ONE undo step (a handle
    /// drag that overwrites several records, or an overlap save that trims a
    /// neighbour and moves a slice, undoes in a single ⌘Z). Nestable — inner
    /// groups fold into the outermost. An empty group pushes nothing.
    public func group(_ label: String, _ body: () async -> Void) async {
        let outer = pendingGroup == nil
        if outer { pendingGroup = [] }
        await body()
        if outer, let group = pendingGroup {
            pendingGroup = nil
            if !group.isEmpty {
                stack.append((label, { for inverse in group.reversed() { await inverse() } }))
            }
        }
    }

    /// The most recent entry, removed. The caller runs the inverse (and owns
    /// the user-facing notification). nil when there is nothing to undo.
    public func pop() -> (label: String, inverse: Inverse)? {
        stack.popLast()
    }
}
