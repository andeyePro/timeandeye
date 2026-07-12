import Foundation

package enum MinuteResolver {
    package struct Minute: Equatable, Sendable {
        package var minuteStart: Date
        package var target: Target
        package init(minuteStart: Date, target: Target) {
            self.minuteStart = minuteStart
            self.target = target
        }
    }

    /// Buckets spans into wall-clock minutes; each minute goes wholly to the
    /// target that held it longest (spec: "the dominant task wins the whole
    /// minute"). Ties break toward the target seen earliest.
    package static func dominantPerMinute(_ spans: [FocusSpan]) -> [Minute] {
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
