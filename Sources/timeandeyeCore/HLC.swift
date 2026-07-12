import Foundation

/// Hybrid logical clock timestamp: orders edits across devices without
/// trusting wall clocks. Total order: (physicalMillis, counter, deviceID) —
/// deviceID breaks exact ties deterministically, so two devices can never
/// produce incomparable stamps. See docs/superpowers/specs/2026-07-02-sync-design.md.
package struct HLC: Codable, Comparable, Hashable, Sendable, CustomStringConvertible {
    package var physicalMillis: Int64
    package var counter: Int32
    package var deviceID: String

    package init(physicalMillis: Int64, counter: Int32, deviceID: String) {
        self.physicalMillis = physicalMillis
        self.counter = counter
        self.deviceID = deviceID
    }

    package static func < (a: HLC, b: HLC) -> Bool {
        if a.physicalMillis != b.physicalMillis { return a.physicalMillis < b.physicalMillis }
        if a.counter != b.counter { return a.counter < b.counter }
        return a.deviceID < b.deviceID
    }

    package var description: String { "\(physicalMillis).\(counter)@\(deviceID)" }
}

/// The per-device clock. `tick()` stamps a local mutation; `receive(_:)`
/// folds in a remote stamp so causality is preserved (anything we write after
/// seeing a remote revision orders after it). Injectable `now` for checks.
package final class HLCClock {
    package let deviceID: String
    package private(set) var last: HLC
    private let now: () -> Date

    /// Cap on how far a remote physical clock can drag ours forward (a device
    /// with a wildly-wrong clock must not poison every later local stamp).
    /// Beyond the cap we keep OUR physical time and rely on the counter.
    package static let maxDriftMillis: Int64 = 60 * 60 * 1000   // 1 h

    package init(deviceID: String, last: HLC? = nil, now: @escaping () -> Date = Date.init) {
        self.deviceID = deviceID
        self.now = now
        self.last = last ?? HLC(physicalMillis: 0, counter: 0, deviceID: deviceID)
    }

    private var physicalNow: Int64 {
        Int64((now().timeIntervalSince1970 * 1000).rounded())
    }

    /// Stamp a local event: strictly greater than every stamp seen so far.
    package func tick() -> HLC {
        let pt = physicalNow
        if pt > last.physicalMillis {
            last = HLC(physicalMillis: pt, counter: 0, deviceID: deviceID)
        } else {
            last = HLC(physicalMillis: last.physicalMillis, counter: last.counter + 1,
                       deviceID: deviceID)
        }
        return last
    }

    /// Fold in a remote stamp: our next tick() must order after it. Returns
    /// the updated local clock state (not a stamp for an event).
    @discardableResult
    package func receive(_ remote: HLC) -> HLC {
        let pt = physicalNow
        let cappedRemote = min(remote.physicalMillis, pt + Self.maxDriftMillis)
        let maxPhysical = max(last.physicalMillis, cappedRemote, pt)
        let counter: Int32
        if maxPhysical == last.physicalMillis && maxPhysical == cappedRemote {
            counter = max(last.counter, remote.counter) + 1
        } else if maxPhysical == last.physicalMillis {
            counter = last.counter + 1
        } else if maxPhysical == cappedRemote {
            counter = remote.counter + 1
        } else {
            counter = 0
        }
        last = HLC(physicalMillis: maxPhysical, counter: counter, deviceID: deviceID)
        return last
    }
}
