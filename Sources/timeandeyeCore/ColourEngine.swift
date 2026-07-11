import Foundation

// The task/project colour engine (colour-strategy spec,
// docs/superpowers/specs/2026-07-06-colour-strategy.md; reference semantics
// proven interactively in sites/previews/colour-lab.html, strategy C "hue
// neighbourhood").
//
// GOVERNING PRINCIPLE — COLOUR STABILITY. A colour assignment is created the
// first time an item is rendered and from then on it is DATA, not
// derivation: the allocator only ever READS existing records and appends new
// ones, so a colour, once seen, never changes underneath the user. The only
// thing that changes a seen colour is the user's own edit (which lives in
// `AndeyeSettings.taskColours`, checked before any record here) and its undo.
//
// Platform-independent on purpose: all colour maths happens in OKLCH
// (perceptual — equal steps look equal) on plain Doubles and hex strings.
// NSColor/Color conversion stays at the platform edges (AppController,
// PhonePalette).

// MARK: - Value types

/// An sRGB colour as 0–255 integer channels — the engine's interchange form.
/// Integer channels (not CGFloat) so a persisted hex round-trips
/// byte-identically: restart and store round-trip must return IDENTICAL
/// colours, and integers can't drift.
public struct RGB255: Equatable, Sendable {
    public var r: Int
    public var g: Int
    public var b: Int

    public init(r: Int, g: Int, b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: Int((v >> 16) & 0xFF), g: Int((v >> 8) & 0xFF), b: Int(v & 0xFF))
    }

    public var hex: String {
        String(format: "#%02X%02X%02X",
               min(max(r, 0), 255), min(max(g, 0), 255), min(max(b, 0), 255))
    }
}

/// A colour in OKLCH (lightness, chroma, hue-degrees) — the space every
/// allocation decision is made in.
public struct OKLCH: Equatable, Sendable {
    public var L: Double
    public var C: Double
    public var H: Double

    public init(L: Double, C: Double, H: Double) {
        self.L = L
        self.C = C
        self.H = H
    }
}

// MARK: - Persisted assignments (colours.json)

/// The colour-assignment store: one record per first-sighted subject, in a
/// dedicated user-ownable JSON file beside pins.json (same JSONFileStore
/// pattern) — human-readable, backupable, diffable. Records key on STABLE
/// identity (`TaskRef.storageKey`; `BillableRules` project keys), never on
/// labels, so renames keep colour. Sync (future): whole-record LWW like
/// `Pin`, per the 2026-07-02 sync design.
public struct ColourAssignments: Codable, Equatable, Sendable {
    /// A project's hue anchor. `hue`/`bandL` are the canonical allocation
    /// coordinates (what spacing decisions score against); `hex` is the
    /// resolved display swatch (contrast-adjusted lightness at that hue).
    public struct ProjectRecord: Codable, Equatable, Sendable {
        public var hue: Double
        public var bandL: Double
        public var hex: String
        public var firstSeen: Date
        /// "auto" = engine pick; "migrated" = the colour the project ring was
        /// ALREADY showing pre-engine (a child task's legacy colour),
        /// snapshotted so the upgrade never changes a colour the user saw.
        /// nil = written by the first engine build (2026-07-09), which
        /// allocated fresh anchors for already-seen projects and broke the
        /// stability promise — `repairProjectAnchor` repairs exactly these
        /// (while the store-level repair window is open; see
        /// `ColourAssignments.version`).
        public var provenance: String?

        public init(hue: Double, bandL: Double, hex: String, firstSeen: Date,
                    provenance: String? = nil) {
            self.hue = hue
            self.bandL = bandL
            self.hex = hex
            self.firstSeen = firstSeen
            self.provenance = provenance
        }
    }

    /// A task's assigned colour. Engine picks carry their exact OKLCH
    /// coordinates so later allocations score against the unrounded value
    /// (lab parity); migrated legacy-hash snapshots carry hex only.
    public struct TaskRecord: Codable, Equatable, Sendable {
        public var hex: String
        public var L: Double?
        public var C: Double?
        public var H: Double?
        /// "auto" = engine pick; "migrated" = pre-engine hash colour
        /// snapshotted so the upgrade never changes a colour the user saw.
        public var provenance: String
        public var firstSeen: Date

        public init(hex: String, L: Double? = nil, C: Double? = nil, H: Double? = nil,
                    provenance: String, firstSeen: Date) {
            self.hex = hex
            self.L = L
            self.C = C
            self.H = H
            self.provenance = provenance
            self.firstSeen = firstSeen
        }
    }

    /// Stable project key (BillableRules key builders) → anchor.
    public var projects: [String: ProjectRecord]
    /// `TaskRef.storageKey` → colour.
    public var tasks: [String: TaskRecord]
    /// Store schema version. nil = the file was last SAVED by a pre-version
    /// build (the broken 2026-07-09 engine or the 2026-07-10 interim repair)
    /// — every "auto" project record in such a store predates the
    /// deterministic anchor repair and may be one of those builds' wrong
    /// fresh picks, so `repairProjectAnchor` may replace it. A decode by an
    /// old binary DROPS this field along with the provenance flags (Codable
    /// ignores unknown keys; re-encode loses them), which is why the version
    /// stamp alone can't close the repair era — the controller pairs it with
    /// a one-time marker file OUTSIDE this JSON that old binaries never
    /// touch (see AppController.finalizeColourRepairsIfComplete).
    public var version: Int?

    /// What this build writes into `version`.
    public static let currentVersion = 2

    public init(projects: [String: ProjectRecord] = [:],
                tasks: [String: TaskRecord] = [:],
                version: Int? = nil) {
        self.projects = projects
        self.tasks = tasks
        self.version = version
    }

    /// Anchor key for tasks whose project is unknown (ref no longer in any
    /// cache, no project title). They share one "unfiled" neighbourhood
    /// rather than scattering, and keep their colour if the project later
    /// becomes known (task records never re-derive).
    public static let unfiledKey = "unfiled"

    /// Total record count — the cheap "did an allocation just happen?" probe
    /// controllers use to decide whether to persist.
    public var recordCount: Int { projects.count + tasks.count }

    /// Title-key → id-key project-record migration, mirroring
    /// `BillableRules.migrateProjectKeys` (the two stores share the key
    /// convention, so they migrate on the same trigger). An already-populated
    /// id key wins — never clobbered. Idempotent. Returns how many moved.
    @discardableResult
    public mutating func migrateProjectKeys(_ mapping: [String: String]) -> Int {
        var moved = 0
        for (titleKey, idKey) in mapping {
            guard let record = projects[titleKey] else { continue }
            if projects[idKey] == nil {
                projects[idKey] = record
                moved += 1
            }
            projects[titleKey] = nil
        }
        return moved
    }
}

// MARK: - The engine

/// A saved colour set (Settings ▸ Colours — Martin, 2026-07-11): the user's
/// explicit picks PLUS the engine's records — everything that determines
/// what renders, so loading a set reproduces the exact look, automatic
/// behaviour included.
public struct ColourSet: Codable, Equatable, Sendable {
    public var version: Int
    /// settings.taskColours — the user's per-task picks (hex by storageKey).
    public var taskOverrides: [String: String]
    /// settings.projectColours — the user's project-swatch picks.
    public var projectOverrides: [String: String]
    /// The engine store as it stood when saved.
    public var assignments: ColourAssignments

    public static let currentVersion = 1

    public init(taskOverrides: [String: String],
                projectOverrides: [String: String],
                assignments: ColourAssignments) {
        self.version = Self.currentVersion
        self.taskOverrides = taskOverrides
        self.projectOverrides = projectOverrides
        self.assignments = assignments
    }
}

public enum ColourEngine {

    // MARK: Palette constants (colour-lab strategy C)

    /// Worst-case CVD-aware pairwise distance below which two colours are
    /// treated as no longer legibly distinct (the lab's demo floor).
    public static let legibilityFloor = 0.02
    /// Chosen-label WCAG contrast every auto colour must reach (spec §9).
    public static let labelContrastFloor = 4.5

    /// Canonical anchor chroma/lightness. Band 1 is the lab's wheel; band 2
    /// opens on hue exhaustion (spec §7): when the best free band-1 hue's
    /// minimum distance drops below the floor, new projects allocate at a
    /// darker lightness instead — capacity doubles and OLD ANCHORS NEVER MOVE.
    static let anchorChroma = 0.13
    static let anchorBandLs = [0.62, 0.45]
    static let firstAnchorHue = 258.0
    static let anchorWheelStep = 12.0

    /// Task-candidate grid: hue within ±25° of the project anchor, crossed
    /// with the lightness/chroma ramp. Scan order (delta, then L, then C,
    /// ascending) is LOAD-BEARING: argmax ties break to the first candidate
    /// scanned, so this order is part of determinism — never reorder.
    static let taskHueDeltas = stride(from: -25.0, through: 25.0, by: 5.0).map { $0 }
    static let taskRampLs = [0.42, 0.52, 0.62, 0.72, 0.82]
    static let taskRampCs = [0.07, 0.10, 0.13, 0.16]

    /// Anchor DISPLAY lightness ladder per band: the first entry whose
    /// swatch passes the label-contrast floor at the anchor's hue wins.
    /// (Teal/green hues at L 0.55 sit just under 4.5:1 with the white label
    /// the luminance rule picks, so those hues step one rung darker.)
    static let displayLadders: [[Double]] = [[0.55, 0.51, 0.47, 0.43],
                                             [0.45, 0.41, 0.37, 0.33]]
    static let displayChroma = 0.14

    // MARK: Resolution (what controllers call)

    /// Effective task colour hex: user override → stored record → first-sight
    /// allocation (committed into `store`; caller persists when
    /// `store.recordCount` grew). Overrides NEVER write a record here — they
    /// live in settings exactly as before this engine existed, so existing
    /// saved overrides keep working unchanged.
    public static func effectiveHex(taskKey: String, projectKey: String?,
                                    override: String?,
                                    anchorHueOverride: Double? = nil,
                                    in store: inout ColourAssignments,
                                    at now: Date = Date()) -> String {
        if let override, RGB255(hex: override) != nil { return override }
        return taskHex(taskKey, projectKey: projectKey,
                       anchorHueOverride: anchorHueOverride, in: &store, at: now)
    }

    /// Stored-or-allocated task colour (no override layer).
    /// `anchorHueOverride`: when the user has recoloured the PROJECT swatch
    /// (a settings-level override — the anchor record itself never moves),
    /// a NEW task shades around the override's hue so the family the user
    /// chose is the family new work joins. Existing records are returned
    /// untouched either way — the override steers first sight only.
    @discardableResult
    public static func taskHex(_ taskKey: String, projectKey: String?,
                               anchorHueOverride: Double? = nil,
                               in store: inout ColourAssignments,
                               at now: Date = Date()) -> String {
        if let existing = store.tasks[taskKey] { return existing.hex }
        let anchor = projectRecord(projectKey ?? ColourAssignments.unfiledKey,
                                   in: &store, at: now)
        let pick = allocateTask(anchorHue: anchorHueOverride ?? anchor.hue, in: store)
        store.tasks[taskKey] = ColourAssignments.TaskRecord(
            hex: rgb(from: pick).hex, L: pick.L, C: pick.C, H: pick.H,
            provenance: "auto", firstSeen: now)
        return store.tasks[taskKey]!.hex
    }

    /// The allocation hue a user's project-colour override contributes to
    /// future task shading: the override's own OKLCH hue — unless the pick
    /// is (near-)achromatic, where the hue is quantisation noise (see
    /// `anchorHueChromaFloor`), so a grey pick steers nothing and the
    /// anchor record's hue stays in charge. nil for undecodable hex too.
    public static func overrideAnchorHue(hex: String) -> Double? {
        guard let rgb = RGB255(hex: hex) else { return nil }
        let c = oklch(from: rgb)
        return c.C >= anchorHueChromaFloor ? c.H : nil
    }

    /// Stored-or-allocated project anchor. The record's `hex` is the swatch
    /// the project itself renders with (pie project ring, legend row).
    @discardableResult
    public static func projectRecord(_ key: String,
                                     in store: inout ColourAssignments,
                                     at now: Date = Date()) -> ColourAssignments.ProjectRecord {
        if let existing = store.projects[key] { return existing }
        let (hue, bandL) = allocateAnchor(in: store)
        let band = anchorBandLs.firstIndex(of: bandL) ?? 0
        let record = ColourAssignments.ProjectRecord(
            hue: hue, bandL: bandL,
            hex: rgb(from: displayColour(hue: hue, band: band)).hex,
            firstSeen: now, provenance: "auto")
        store.projects[key] = record
        return record
    }

    // MARK: Re-derive from scratch (Martin, 2026-07-11)

    /// Drop and re-allocate every automatic colour for the given project
    /// groupings, in first-seen order, so the whole palette comes out
    /// cohesive: anchors spread across the wheel, each project's tasks
    /// shading its own hue neighbourhood — the cure for preserved legacy
    /// colours that predate the engine and share no family. Records for
    /// keys NOT covered by `groups` are preserved untouched (history tasks
    /// the caller can no longer group), user overrides never live in this
    /// store at all, and original first-seen stamps order the pass and
    /// survive it. Deterministic: same store + groups ⇒ same result.
    public static func rederiveAll(
        groups: [(projectKey: String, memberTaskKeys: [String])],
        in store: ColourAssignments,
        at now: Date = Date()) -> ColourAssignments {
        var rebuilt = store
        func projectSeen(_ key: String) -> Date { store.projects[key]?.firstSeen ?? now }
        func taskSeen(_ key: String) -> Date { store.tasks[key]?.firstSeen ?? now }
        let ordered = groups.sorted {
            (projectSeen($0.projectKey), $0.projectKey)
                < (projectSeen($1.projectKey), $1.projectKey)
        }
        // Clear everything being re-derived FIRST, so allocation only has
        // to stay distinct from what is genuinely staying.
        for group in ordered {
            rebuilt.projects[group.projectKey] = nil
            for key in group.memberTaskKeys { rebuilt.tasks[key] = nil }
        }
        for group in ordered {
            _ = projectRecord(group.projectKey, in: &rebuilt,
                              at: projectSeen(group.projectKey))
            let members = group.memberTaskKeys.sorted {
                (taskSeen($0), $0) < (taskSeen($1), $1)
            }
            for key in members {
                _ = taskHex(key, projectKey: group.projectKey, in: &rebuilt,
                            at: taskSeen(key))
            }
        }
        rebuilt.version = ColourAssignments.currentVersion
        return rebuilt
    }

    /// One-time migration commit: snapshot a pre-engine colour (the legacy
    /// hash pick) as this task's permanent assignment, so the store upgrade
    /// keeps exactly the colour the user already associates with the task.
    /// Never overwrites an existing record.
    public static func snapshotLegacy(taskKey: String, hex: String,
                                      in store: inout ColourAssignments,
                                      at now: Date = Date()) {
        guard store.tasks[taskKey] == nil, RGB255(hex: hex) != nil else { return }
        store.tasks[taskKey] = ColourAssignments.TaskRecord(
            hex: hex, provenance: "migrated", firstSeen: now)
    }

    /// Anchor repair/upgrade for a PROJECT that predates the engine: restore
    /// the colour its pie ring wore before the engine existed, and bring the
    /// project's engine-allocated tasks back into that hue family. The
    /// controller calls this BEFORE any code path that creates or reads the
    /// project's record (`projectRecord`, `taskHex`), so a new task in an
    /// already-seen project can neither allocate around a wrong anchor nor
    /// close the repair window by minting an "auto" record first.
    ///
    /// WHAT COUNTS AS PRE-ENGINE. Only a project with at least one MIGRATED
    /// member task record verifiably predates the engine — those records are
    /// written exactly once, at store bootstrap, from the legacy hash
    /// palette. A user override alone proves nothing (overrides carry no
    /// date), so a brand-new project whose first task the user recoloured is
    /// NOT anchored to that override under a false "migrated" stamp — it
    /// allocates normally.
    ///
    /// WHICH CHILD IS "THE" LEGACY CHILD. Pre-engine the ring wore the pie's
    /// then-current first child — which child that was depended on the period
    /// being viewed and is unrecoverable. The nearest provable,
    /// store-deterministic rule (honest approximation): the
    /// earliest-snapshotted migrated member, ties broken lexicographically by
    /// key — every migrated hex is a colour the project's tasks genuinely
    /// wore pre-engine, and this pick depends only on persisted records,
    /// never on today's sort order. If the user overrode THAT task's colour,
    /// the override is what they actually saw, so it wins for the anchor.
    ///
    /// WHAT MAY BE OVERWRITTEN. "migrated" anchors: never (each already IS a
    /// restored legacy colour; re-picking would flip a settled colour again).
    /// "auto" anchors: only when the store was loaded pre-v2
    /// (`storeLoadedPreV2`) — in a pre-v2 store an "auto" anchor on a
    /// pre-engine project can only be the 2026-07-09/10 builds' wrong fresh
    /// pick (days old at most) while the legacy colour was seen for months;
    /// in a v2 store an "auto" anchor is a legitimate engine pick and is
    /// closed. nil-provenance anchors: always eligible; when the project has
    /// NO migrated member, the nil anchor belonged to a genuinely new
    /// project whose engine pick is the only colour ever seen — it is
    /// adopted in place (stamped "auto"), never recoloured.
    ///
    /// COHORT RE-SHADE. When an anchor moves under a repair, the project's
    /// "auto" member task records re-allocate around the restored hue
    /// (sorted-key order, firstSeen preserved). Judgement call, documented:
    /// those records are days old and already changed once when the engine
    /// landed — moving them back into the project's family is the lesser
    /// evil vs a permanent intra-project clash. Migrated records and user
    /// overrides never move. If the anchor already wears the target colour
    /// (a re-run after an old binary stripped the provenance fields), the
    /// re-shade is skipped so nothing churns.
    ///
    /// ACHROMATIC LEGACY COLOURS. A grey hex has OKLCH chroma ≈ 0, so its
    /// "hue" is atan2 over sRGB quantisation noise (a pure grey lands
    /// red-ish) — committing that would permanently shade every future task
    /// around a hue that matches nothing the user ever saw. The ring KEEPS
    /// the grey (its hex and lightness are real; the user saw them); only
    /// the allocation hue falls back: to the first CHROMATIC migrated member
    /// in the same deterministic order (another colour the project genuinely
    /// wore), else to the engine's own anchor allocation (the most-distinct
    /// free hue — a sensible fresh neighbourhood, since an all-grey project
    /// gave the user no hue association to preserve).
    @discardableResult
    public static func repairProjectAnchor(projectKey: String,
                                           memberTaskKeys: [String],
                                           overrides: [String: String] = [:],
                                           storeLoadedPreV2: Bool,
                                           in store: inout ColourAssignments,
                                           at now: Date = Date()) -> Bool {
        let existing = store.projects[projectKey]
        if let existing {
            if existing.provenance == "migrated" { return false }
            if existing.provenance == "auto", !storeLoadedPreV2 { return false }
        }
        // Deterministic legacy order: earliest migrated members first, ties
        // broken by key. The head is "the" legacy child; the tail doubles as
        // the achromatic-hue fallback ladder.
        let migratedMembers = memberTaskKeys
            .compactMap { key -> (key: String, record: ColourAssignments.TaskRecord)? in
                guard let record = store.tasks[key], record.provenance == "migrated"
                else { return nil }
                return (key, record)
            }
            .sorted { ($0.record.firstSeen, $0.key) < ($1.record.firstSeen, $1.key) }
        guard let legacy = migratedMembers.first else {
            if existing != nil, existing?.provenance == nil {
                store.projects[projectKey]?.provenance = "auto"
                return true
            }
            return false
        }
        // The colour the user actually saw for a member: a (valid) override
        // beats its migrated snapshot.
        func effectiveHex(_ member: (key: String, record: ColourAssignments.TaskRecord)) -> String {
            overrides[member.key].flatMap { RGB255(hex: $0) != nil ? $0 : nil }
                ?? member.record.hex
        }
        let hex = effectiveHex(legacy)
        guard let rgb = RGB255(hex: hex) else { return false }
        let c = oklch(from: rgb)
        var hue = c.H
        if c.C < anchorHueChromaFloor {
            hue = migratedMembers.lazy
                .compactMap { member -> Double? in
                    guard let rgb = RGB255(hex: effectiveHex(member)) else { return nil }
                    let mc = oklch(from: rgb)
                    return mc.C >= anchorHueChromaFloor ? mc.H : nil
                }
                .first ?? allocateAnchor(in: store).hue
        }
        let anchorUnmoved = existing?.hex == hex && existing?.hue == hue
            && existing?.bandL == c.L
        store.projects[projectKey] = ColourAssignments.ProjectRecord(
            hue: hue, bandL: c.L, hex: hex,
            firstSeen: existing?.firstSeen ?? now,
            provenance: "migrated")
        if !anchorUnmoved {
            reshadeAutoTasks(memberTaskKeys: memberTaskKeys, anchorHue: hue,
                             in: &store)
        }
        return true
    }

    /// Below this OKLCH chroma a hex is effectively achromatic: its hue
    /// component is quantisation noise, never a colour association worth
    /// preserving. (Pure greys sit at C ≈ 0.000x; the dullest colour the
    /// engine's own ramps emit with a legible hue carries C 0.07.)
    static let anchorHueChromaFloor = 0.02

    /// Close every remaining provenance-less anchor as an engine pick.
    /// Called once, when the repair pass has seen a COMPLETE task cache, so
    /// anchors whose projects no longer resolve to any cached task (deleted
    /// projects, the unfiled bucket) stop advertising themselves as
    /// repairable forever. Colours are kept as-is: with no migrated member
    /// resolvable there is no older colour to restore.
    @discardableResult
    public static func adoptUnrepairedAnchors(in store: inout ColourAssignments) -> Int {
        var adopted = 0
        for key in store.projects.keys where store.projects[key]?.provenance == nil {
            store.projects[key]?.provenance = "auto"
            adopted += 1
        }
        return adopted
    }

    /// Re-allocate a repaired project's engine-picked task records around the
    /// restored anchor hue. Records are removed then re-allocated in sorted
    /// key order (deterministic), each scoring against everything still in
    /// the store, and keep their original firstSeen — the task's identity and
    /// history don't change, only its shade rejoins the family.
    private static func reshadeAutoTasks(memberTaskKeys: [String],
                                         anchorHue: Double,
                                         in store: inout ColourAssignments) {
        let keys = memberTaskKeys
            .filter { store.tasks[$0]?.provenance == "auto" }
            .sorted()
        guard !keys.isEmpty else { return }
        var firstSeens: [String: Date] = [:]
        for key in keys {
            firstSeens[key] = store.tasks[key]?.firstSeen
            store.tasks[key] = nil
        }
        for key in keys {
            let pick = allocateTask(anchorHue: anchorHue, in: store)
            store.tasks[key] = ColourAssignments.TaskRecord(
                hex: rgb(from: pick).hex, L: pick.L, C: pick.C, H: pick.H,
                provenance: "auto", firstSeen: firstSeens[key] ?? Date())
        }
    }

    // MARK: Allocation

    /// New-project anchor: argmax of minimum worst-case distance over the
    /// candidate wheel vs every existing anchor — "the most
    /// distinct-from-neighbours free hue". Deterministic: fixed wheel order,
    /// strict-improvement argmax, and the existing set only contributes a
    /// minimum (order-free), so same store ⇒ same answer on every device.
    private static func allocateAnchor(in store: ColourAssignments) -> (hue: Double, bandL: Double) {
        if store.projects.isEmpty { return (firstAnchorHue, anchorBandLs[0]) }
        let existing = store.projects.values.map {
            OKLCH(L: $0.bandL, C: anchorChroma, H: $0.hue)
        }
        var fallback: (hue: Double, bandL: Double) = (firstAnchorHue, anchorBandLs[0])
        for (band, bandL) in anchorBandLs.enumerated() {
            var best: Double?
            var bestScore = -Double.infinity
            var h = 0.0
            while h < 360 {
                let candidate = OKLCH(L: bandL, C: anchorChroma, H: h)
                var minD = Double.infinity
                for ex in existing {
                    minD = min(minD, worstCaseDistance(candidate, ex))
                }
                if minD > bestScore {
                    bestScore = minD
                    best = h
                }
                h += anchorWheelStep
            }
            guard let hue = best else { continue }
            // Band 1 wins while it still has a legible gap; otherwise the
            // second band opens (last band commits regardless — beyond that,
            // borders and the legend carry the remaining difference).
            if bestScore >= legibilityFloor || band == anchorBandLs.count - 1 {
                return (hue, bandL)
            }
            fallback = (hue, bandL)
        }
        return fallback
    }

    /// New-task colour: candidates are the ±25° hue neighbourhood of the
    /// project anchor crossed with the L/C ramp, FILTERED by the
    /// label-contrast floor (spec §9 — an auto colour on which the black-or-
    /// white label rule can't reach 4.5:1 is never emitted), scored by
    /// minimum worst-case distance to EVERY task colour assigned so far,
    /// anywhere — not just this project — argmax wins. First-ever task:
    /// nothing to be distinct from, so take the passing candidate
    /// perceptually nearest the project's own colour (reads as "the project").
    private static func allocateTask(anchorHue: Double, in store: ColourAssignments) -> OKLCH {
        let candidates = taskCandidates(anchorHue: anchorHue)
        // The ramp's darkest rung passes the contrast filter at every hue, so
        // this never fires — but an argmax over [] must not be able to trap.
        guard !candidates.isEmpty else {
            return OKLCH(L: taskRampLs[0], C: taskRampCs[0], H: anchorHue)
        }
        if store.tasks.isEmpty {
            let preferred = oklab(OKLCH(L: 0.62, C: 0.13, H: anchorHue))
            var best = candidates[0]
            var bestD = Double.infinity
            for c in candidates {
                let d = distance(oklab(c), preferred)
                if d < bestD {
                    bestD = d
                    best = c
                }
            }
            return best
        }
        // Existing records: engine picks score from their exact OKLCH,
        // migrated/legacy records from their (rounded) hex — the best
        // available truth for each.
        let existing: [[Oklab]] = store.tasks.values.map { record in
            if let L = record.L, let C = record.C, let H = record.H {
                return perModeOklab(OKLCH(L: L, C: C, H: H))
            }
            return perModeOklab(RGB255(hex: record.hex) ?? RGB255(r: 128, g: 128, b: 128))
        }
        var best = candidates[0]
        var bestScore = -Double.infinity
        for c in candidates {
            let cModes = perModeOklab(c)
            var minD = Double.infinity
            for ex in existing {
                minD = min(minD, worstOverModes(cModes, ex))
                if minD <= bestScore { break }   // can't beat the champion
            }
            if minD > bestScore {
                bestScore = minD
                best = c
            }
        }
        return best
    }

    static func taskCandidates(anchorHue: Double) -> [OKLCH] {
        var out: [OKLCH] = []
        for delta in taskHueDeltas {
            let hue = (anchorHue + delta).truncatingRemainder(dividingBy: 360)
            let h = hue < 0 ? hue + 360 : hue
            for L in taskRampLs {
                for C in taskRampCs {
                    let c = OKLCH(L: L, C: C, H: h)
                    if passesLabelContrast(c) { out.append(c) }
                }
            }
        }
        return out
    }

    /// Anchor display swatch: the ladder's first lightness whose swatch
    /// passes the label-contrast floor at this hue.
    static func displayColour(hue: Double, band: Int) -> OKLCH {
        let ladder = displayLadders[min(band, displayLadders.count - 1)]
        for L in ladder {
            let c = OKLCH(L: L, C: displayChroma, H: hue)
            if passesLabelContrast(c) { return c }
        }
        return OKLCH(L: ladder[ladder.count - 1], C: displayChroma, H: hue)
    }

    // MARK: Accessibility metrics (public so checks can drive them)

    /// The app's existing black-or-white label rule (NSColor
    /// .readableTextColour), replicated on integer sRGB so the engine can
    /// guarantee the label the UI will actually choose reaches 4.5:1.
    public static func labelIsBlack(on colour: RGB255) -> Bool {
        let lum = (0.299 * Double(colour.r) + 0.587 * Double(colour.g)
            + 0.114 * Double(colour.b)) / 255
        return lum > 0.6
    }

    /// WCAG contrast ratio between a swatch and the label colour the rule
    /// above picks for it.
    public static func labelContrastRatio(on colour: RGB255) -> Double {
        let label = labelIsBlack(on: colour)
            ? RGB255(r: 0, g: 0, b: 0) : RGB255(r: 255, g: 255, b: 255)
        let a = wcagLuminance(colour)
        let b = wcagLuminance(label)
        let (hi, lo) = a > b ? (a, b) : (b, a)
        return (hi + 0.05) / (lo + 0.05)
    }

    static func passesLabelContrast(_ c: OKLCH) -> Bool {
        labelContrastRatio(on: rgb(from: c)) >= labelContrastFloor
    }

    /// Worst-case perceptual distance: the minimum of the identity OKLab
    /// distance and the distance under protan/deutan/tritan simulation
    /// (Machado 2009 matrices) — "a hue pair is only as distinct as its
    /// worst-case viewer" (spec §9). No colour-blind MODE exists: the metric
    /// is always on, because a toggle that changes allocations would fight
    /// stability.
    public static func worstCaseDistance(_ a: OKLCH, _ b: OKLCH) -> Double {
        worstOverModes(perModeOklab(a), perModeOklab(b))
    }

    public static func worstCaseDistance(hexA: String, hexB: String) -> Double {
        guard let a = RGB255(hex: hexA), let b = RGB255(hex: hexB) else {
            return 0
        }
        return worstOverModes(perModeOklab(a), perModeOklab(b))
    }

    // MARK: - Colour maths (Björn Ottosson's OKLab; sRGB transfer curves)

    struct Oklab {
        var L: Double
        var a: Double
        var b: Double
    }

    private static func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func linearToSrgb(_ c: Double) -> Double {
        let x = min(max(c, 0), 1)
        return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    /// Sign-preserving cube root (out-of-gamut intermediates go slightly
    /// negative; JS Math.cbrt handles that and so must we, for lab parity).
    private static func cubeRoot(_ x: Double) -> Double {
        x < 0 ? -pow(-x, 1.0 / 3.0) : pow(x, 1.0 / 3.0)
    }

    private static func linearToOklab(r: Double, g: Double, b: Double) -> Oklab {
        let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
        let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
        let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
        let l3 = cubeRoot(l), m3 = cubeRoot(m), s3 = cubeRoot(s)
        return Oklab(
            L: 0.2104542553 * l3 + 0.7936177850 * m3 - 0.0040720468 * s3,
            a: 1.9779984951 * l3 - 2.4285922050 * m3 + 0.4505937099 * s3,
            b: 0.0259040371 * l3 + 0.7827717662 * m3 - 0.8086757660 * s3)
    }

    private static func oklabToLinear(_ c: Oklab) -> (r: Double, g: Double, b: Double) {
        let l3 = c.L + 0.3963377774 * c.a + 0.2158037573 * c.b
        let m3 = c.L - 0.1055613458 * c.a - 0.0638541728 * c.b
        let s3 = c.L - 0.0894841775 * c.a - 1.2914855480 * c.b
        let l = l3 * l3 * l3, m = m3 * m3 * m3, s = s3 * s3 * s3
        return (r: 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                g: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                b: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    static func oklab(_ c: OKLCH) -> Oklab {
        let hr = c.H * Double.pi / 180
        return Oklab(L: c.L, a: c.C * cos(hr), b: c.C * sin(hr))
    }

    /// OKLCH → rounded sRGB, gamut-clipped exactly like the lab (clamp in
    /// linear light, then encode).
    public static func rgb(from c: OKLCH) -> RGB255 {
        let lin = oklabToLinear(oklab(c))
        return RGB255(r: Int((linearToSrgb(lin.r) * 255).rounded()),
                      g: Int((linearToSrgb(lin.g) * 255).rounded()),
                      b: Int((linearToSrgb(lin.b) * 255).rounded()))
    }

    static func oklab(_ c: RGB255) -> Oklab {
        linearToOklab(r: srgbToLinear(Double(c.r) / 255),
                      g: srgbToLinear(Double(c.g) / 255),
                      b: srgbToLinear(Double(c.b) / 255))
    }

    /// sRGB → OKLCH, the inverse edge `repairProjectAnchor` needs: a
    /// migrated hex must yield real allocation coordinates (hue for the task
    /// neighbourhood, L for anchor spacing), not a guessed band.
    public static func oklch(from c: RGB255) -> OKLCH {
        let lab = oklab(c)
        let h = atan2(lab.b, lab.a) * 180 / Double.pi
        return OKLCH(L: lab.L, C: (lab.a * lab.a + lab.b * lab.b).squareRoot(),
                     H: h < 0 ? h + 360 : h)
    }

    private static func distance(_ a: Oklab, _ b: Oklab) -> Double {
        let dl = a.L - b.L, da = a.a - b.a, db = a.b - b.b
        return (dl * dl + da * da + db * db).squareRoot()
    }

    private static func wcagLuminance(_ c: RGB255) -> Double {
        0.2126 * srgbToLinear(Double(c.r) / 255)
            + 0.7152 * srgbToLinear(Double(c.g) / 255)
            + 0.0722 * srgbToLinear(Double(c.b) / 255)
    }

    // MARK: CVD simulation

    /// Machado, Oliveira & Fairchild (2009) full-dichromacy matrices, applied
    /// in linear sRGB — a perceptual-engineering simulation (good enough to
    /// keep allocations apart for every viewer), not a clinical one.
    private static let cvdMatrices: [[Double]] = [
        // protan
        [0.152286, 1.052583, -0.204868,
         0.114503, 0.786281, 0.099216,
         -0.003882, -0.048116, 1.051998],
        // deutan
        [0.367322, 0.860646, -0.227968,
         0.280085, 0.672501, 0.047413,
         -0.011820, 0.042940, 0.968881],
        // tritan
        [1.255528, -0.076749, -0.178779,
         -0.078411, 0.930809, 0.147602,
         0.004733, 0.691367, 0.303900],
    ]

    private static func simulate(_ c: RGB255, matrix m: [Double]) -> RGB255 {
        let lr = srgbToLinear(Double(c.r) / 255)
        let lg = srgbToLinear(Double(c.g) / 255)
        let lb = srgbToLinear(Double(c.b) / 255)
        let r2 = m[0] * lr + m[1] * lg + m[2] * lb
        let g2 = m[3] * lr + m[4] * lg + m[5] * lb
        let b2 = m[6] * lr + m[7] * lg + m[8] * lb
        return RGB255(r: Int((linearToSrgb(r2) * 255).rounded()),
                      g: Int((linearToSrgb(g2) * 255).rounded()),
                      b: Int((linearToSrgb(b2) * 255).rounded()))
    }

    /// [identity, protan, deutan, tritan] OKLab views of one colour —
    /// precomputed so N-way scoring doesn't re-simulate per pair. Identity
    /// comes from the exact OKLCH (lab parity: only the CVD legs round
    /// through 8-bit sRGB).
    static func perModeOklab(_ c: OKLCH) -> [Oklab] {
        let base = rgb(from: c)
        return [oklab(c)] + cvdMatrices.map { oklab(simulate(base, matrix: $0)) }
    }

    static func perModeOklab(_ c: RGB255) -> [Oklab] {
        [oklab(c)] + cvdMatrices.map { oklab(simulate(c, matrix: $0)) }
    }

    static func worstOverModes(_ a: [Oklab], _ b: [Oklab]) -> Double {
        var worst = Double.infinity
        for i in 0..<min(a.count, b.count) {
            worst = min(worst, distance(a[i], b[i]))
        }
        return worst
    }
}
