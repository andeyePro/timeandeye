import Foundation

/// Validate-on-use for email recipes (the NAIL correspondent programme's
/// self-heal architecture, 2026-06-29): every recipe read is CHEAPLY
/// validated — did the selectors resolve to at least one plausible external
/// party? — and only a failure escalates. A webmail redesign or a localized
/// "From" label doesn't throw an error anywhere; it just makes a recipe
/// silently return nothing (or junk), so the shape of the OUTPUT is the only
/// detector we have. Pure, so redesign scenarios are checkable with no
/// browser in the loop.
package enum EmailRecipeValidation {
    /// Why a read was judged suspect — the health record keeps the latest one
    /// so diagnostics can say WHICH redesign symptom is presenting.
    package enum Fault: String, Equatable, Sendable {
        /// Selectors matched nothing on a page we already classified as an
        /// OPEN MESSAGE (the capture gate ran first) — the classic redesign /
        /// renamed-class symptom (`.gD` disappearing).
        case noParties
        /// Selectors matched nodes but none carried an address-shaped value —
        /// e.g. the email attribute becoming an opaque token after a redesign.
        /// Reachable two ways: parties whose captured value fails the address
        /// shape, and (because the capture JS pre-filters value-less nodes)
        /// the JS-reported count of MATCHED-but-unparseable nodes — without
        /// that count, an attribute redesign would misreport as `noParties`
        /// and send the future re-learn loop hunting for missing selectors
        /// instead of a moved attribute.
        case garbage
    }

    package enum Verdict: Equatable, Sendable {
        /// The read is trustworthy; enrich the signal with these counterparties.
        case healthy([EmailSignal.Party])
        /// Implausibly many counterparties for one message header. That can
        /// be a selector regressed to scraping the LIST surface — but it is
        /// just as plausibly a legitimate reply-all storm, and either way the
        /// selectors demonstrably resolved address-shaped parties, so this is
        /// NOT a recipe-health strike. Enrichment keeps the senders plus the
        /// leading recipients up to `maxPlausibleCounterparties` (the
        /// associated list, already capped): the sender is the strong signal
        /// and survives; a list-scrape's per-row tail cannot flood learning.
        case flooded([EmailSignal.Party])
        /// The recipe resolved fine but every party is the user (note-to-self,
        /// own-domain-only thread). Nothing to enrich — and explicitly NOT a
        /// recipe failure: absence of a counterparty is not a broken selector,
        /// and counting it would tick the streak on every self-addressed note
        /// until a pointless re-learn of a working recipe fired.
        case selfOnly
        /// Do not enrich (a polluted correspondent would poison learning and
        /// EmailRule matching); counts against the recipe's health.
        case suspect(Fault)
    }

    /// One sender plus a CC list; even a large meeting thread rarely exceeds
    /// this. Beyond it the read is `flooded`: enrichment is capped here, but
    /// (unlike the suspect faults) health is untouched — see `Verdict.flooded`.
    package static let maxPlausibleCounterparties = 12

    /// Judge one recipe read. `senders`/`recipients` are the RAW parties the
    /// selectors yielded (pre self-filtering) — the raw set is what tells a
    /// broken recipe (nothing/junk matched) apart from a healthy read whose
    /// parties all happened to be the user. `unparseable` is the capture JS's
    /// count of selector-MATCHED nodes that yielded no address-shaped value
    /// (the JS drops them from the party lists, so only this count can tell
    /// an attribute redesign apart from selectors matching nothing at all).
    package static func validate(senders: [EmailSignal.Party],
                                recipients: [EmailSignal.Party],
                                ownAddresses: Set<String> = [],
                                ownDomains: Set<String> = [],
                                unparseable: Int = 0) -> Verdict {
        guard !(senders.isEmpty && recipients.isEmpty) else {
            return .suspect(unparseable > 0 ? .garbage : .noParties)
        }
        // Drop garbage per-party, not per-read: Gmail decorates some chips
        // with opaque hovercard ids while the header chip stays sound — a
        // partial redesign must not discard the one good read.
        let soundSenders = senders.filter { EmailSignal.isAddress($0.email) }
        let soundRecipients = recipients.filter { EmailSignal.isAddress($0.email) }
        guard !(soundSenders.isEmpty && soundRecipients.isEmpty) else { return .suspect(.garbage) }
        let others = EmailSignal.counterparties(senders: soundSenders,
                                                recipients: soundRecipients,
                                                ownAddresses: ownAddresses,
                                                ownDomains: ownDomains)
        guard !others.isEmpty else { return .selfOnly }
        guard others.count <= maxPlausibleCounterparties else {
            // `counterparties` returns senders first, so the prefix always
            // keeps the sender(s) and truncates the recipient tail.
            return .flooded(Array(others.prefix(maxPlausibleCounterparties)))
        }
        return .healthy(others)
    }
}

/// Per-system recipe health: the consecutive validate-on-use failure streak
/// and the latest fault. A pure value — the capture engine holds one per
/// system, in memory only, deliberately: a genuinely broken recipe re-proves
/// itself within one read after relaunch, and no per-system store exists to
/// piggyback on (a new store file just for a streak counter isn't worth the
/// surface).
package struct EmailRecipeHealth: Equatable, Sendable {
    /// Three strikes: one suspect read can be a slow page load or a
    /// half-rendered message; three in a row with no healthy read between is
    /// a recipe that has actually gone bad.
    package static let unhealthyThreshold = 3

    package private(set) var consecutiveFailures = 0
    package private(set) var lastFault: EmailRecipeValidation.Fault?

    package var isUnhealthy: Bool { consecutiveFailures >= Self.unhealthyThreshold }

    package init() {}

    /// Fold one verdict in. `selfOnly` resets the streak just like `healthy`
    /// does — a recipe that cleanly read a self-thread demonstrably works.
    /// Recovery is total (back to 0, fault cleared): transient wobbles must
    /// never accumulate across healthy reads into a false unhealthy. A
    /// `flooded` read leaves the streak UNTOUCHED, deliberately in the
    /// middle: its parties parsed, so it must never strike toward a re-learn
    /// of selectors that plainly resolve — but its untrusted tail isn't
    /// proof of a sound recipe either, so it doesn't erase strikes.
    package func recording(_ verdict: EmailRecipeValidation.Verdict) -> EmailRecipeHealth {
        var next = self
        switch verdict {
        case .healthy, .selfOnly:
            next.consecutiveFailures = 0
            next.lastFault = nil
        case .flooded:
            break
        case .suspect(let fault):
            next.consecutiveFailures += 1
            next.lastFault = fault
        }
        return next
    }
}
