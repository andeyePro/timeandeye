# Undo/redo core — ⌘⇧Z, live pick + Stop, transparent notices (2026-08-13)

Martin's calls: 2026-07-23 ("I suspect cmd-Z should undo a live pick and
even a stop… we also need a redo… I have no clue what it undid") and 13 Aug
reply 12 (⌘Z overshoot with no ⌘⇧Z; the undo notice hidden behind the
popover). Boundary kept throughout: money already posted to a backend is
never silently clawed back.

## The problem shape

`UndoStack` holds (label, inverse) pairs; inverses are opaque snapshot
restores. Redo needs the inverse-of-the-inverse, which registration sites
never supplied. 50 `registerUndo` sites exist; converting them all at once
is a correctness hazard.

## Design: NSUndoManager discipline, generalised

`UndoStack` gains a redo stack and a mode:

- **Normal registration** pushes an undo entry and CLEARS the redo stack
  (a fresh edit invalidates the redo future — standard).
- **During `undo()`** (mode `.undoing`): registrations made by the running
  inverse route to the REDO stack (an inverse that re-registers gives a
  true redo for free). If the inverse registered nothing but the entry
  carried an explicit `redo` closure, that closure becomes the redo entry.
  If neither: the redo stack CLEARS — undoing a non-redoable entry is a
  boundary, never a silent no-op ⌘⇧Z.
- **During `redo()`** (mode `.redoing`): registrations route back to the
  UNDO stack (the replay rebuilds the undo entry). If the redo entry's
  replay registered nothing, the original entry (with its still-valid
  snapshot inverse) is pushed back instead.
- Multiple registrations during one undo/redo bundle into ONE entry
  (reversed on replay), mirroring `group`.

New API: `registerRedoable(label, undo:, redo:)`. The old
`register(label, inverse:)` stays for unconverted sites — their entries
are honest non-redoable boundaries.

### Replay-stability rule for conversions

A `redo` closure must leave every id the original action minted intact —
id-keyed journal UPDATES are safe; session RE-CREATION (fresh ids) is not,
because the entry's original inverse (captured snapshots) must stay valid
after a redo. Convert only sites whose replay is id-stable; leave the rest
as boundaries.

## Controller

- `redo()` beside `undo()`, same serial chain (an undo inverse and a redo
  replay never interleave); ⌘⇧Z in the same key monitor as ⌘Z.
- Both fire `notifyContent` with a one-line story: "undid — <label>" /
  "redid — <label>", plus the Funk sound on an empty stack.
- **Notice z-order**: the notice window must never sit under the popover
  (reply 12). See the notify window-level fix in the same commit.

## Live pick + Stop join ⌘Z (2026-07-23 call)

- `userPicked` registers "switch to <task>": undo = relabel back to the
  prior task + restore the attributor snapshot (the teach un-teaches);
  redo = re-pick (id-stable — the live session has no journal row).
- `stop()` registers "stop tracking": undo = resume onto the stopped task
  (the resume path that already exists); redo = stop again.

## Conversion batches

1. (this spec's commit) Core machinery + checks; ⌘⇧Z; notices; z-order.
2. Live pick + Stop registrations.
3. Billable marks (`setSessionBillable`, `setProjectBillable`,
   `setTaskBillable`) — Martin's overshoot case; replays are id-stable
   flag writes.
4. Forget family (`forget`, `forgetAllExperience`, rule deletes) — replay
   = re-run the forget with the same args.
5. Review assign / timeline edits — audit id-stability per site before
   converting; recreation-based inverses stay boundaries.
