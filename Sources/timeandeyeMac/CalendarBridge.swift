import Foundation
import AppKit
import EventKit
import timeandeyeCore

/// Read-only EventKit capture — the calendar-signal spec's §3. Never writes
/// to the calendar, never requests access eagerly (see `requestAccess`,
/// called lazily by `AppController` only the first time the user turns the
/// feature on, mirroring how Accessibility/Automation are already asked for
/// once and never nagged about again).
///
/// Fetch cadence is deliberately NOT the 2 s poll `SensorHub` uses for focus:
/// calendars don't need sub-minute freshness, and re-querying a whole event
/// window every 2 s would be wasted work and (per the C10 main-thread guard
/// every emitter in this codebase honours) main-thread contention for no
/// benefit. Instead a fresh fetch fires on `EKEventStoreChanged` (external
/// edits/new invites), on wake (the Mac may have missed changes asleep), and
/// a defensive 5-minute fallback timer (notification delivery isn't 100%
/// guaranteed after a long background stretch).
package final class CalendarBridge {
    /// The rolling window's events, re-emitted on every refresh. Every
    /// emitter in this codebase funnels onto the main thread (C10 guard) —
    /// `emit` below enforces the same rule here.
    package var onEvent: ([CalendarEvent]) -> Void = { _ in }

    private let store = EKEventStore()
    private var fallbackTimer: Timer?
    private var excludedNames: Set<String> = []
    private var changeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    package init() {}

    private func emit(_ events: [CalendarEvent]) {
        if Thread.isMainThread {
            onEvent(events)
        } else {
            assertionFailure("CalendarBridge emitter off the main thread — C10 guard")
            DispatchQueue.main.async { self.onEvent(events) }
        }
    }

    /// macOS 14+ full-access API only — the bundle's own
    /// `LSMinimumSystemVersion` is already 14.0 (make-app.sh), so there is no
    /// pre-14 install to fall back for (mirrors the calendar-signal spec §1's
    /// TCC precedent note).
    package func requestAccess(completion: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// Begins observing + does the first fetch. `excludedCalendarNames` is
    /// the settings opt-list (Settings ▸ Calendar); call
    /// `setExcludedCalendarNames` again later to change it without a
    /// restart.
    package func start(excludedCalendarNames: [String] = []) {
        excludedNames = Set(excludedCalendarNames)
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        fallbackTimer?.tolerance = 30
        refresh()
    }

    package func stop() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        changeObserver = nil
        wakeObserver = nil
    }

    package func setExcludedCalendarNames(_ names: [String]) {
        excludedNames = Set(names)
        refresh()
    }

    /// Today's local midnight − 1 day to + 2 days (spec §3) — covers
    /// overnight events and gives the pick-list "now:" badge a lookahead
    /// without re-querying constantly.
    private func refresh() {
        let now = Date()
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: now)
        let from = midnight.addingTimeInterval(-86_400)
        let to = midnight.addingTimeInterval(3 * 86_400)
        emit(fetch(from: from, to: to))
    }

    /// The live prior's own read: events covering `date`, all-day excluded
    /// (spec §3 — an all-day banner isn't "what you're doing this minute").
    package func currentEvents(at date: Date = Date()) -> [CalendarEvent] {
        let from = date.addingTimeInterval(-86_400)
        let to = date.addingTimeInterval(86_400)
        return fetch(from: from, to: to).filter { $0.start <= date && date < $0.end }
    }

    /// The review-queue hint's read (§7): every event whose own span
    /// overlaps `span`, fetched fresh from EventKit within `[from, to]` —
    /// deliberately a wider bound than `span` itself so a query for one
    /// instant (a zero-length span) still finds the event actually covering
    /// it. `from`/`to` is the caller's lookback window
    /// (derived from the oldest unresolved review row); all-day and free-marked events are
    /// INCLUDED here even though they're excluded from the live prior (§7 —
    /// "Annual leave" overlapping a queued day is still a legitimate hint).
    package func events(overlapping span: (start: Date, end: Date), from: Date, to: Date) -> [CalendarEvent] {
        fetch(from: from, to: to, allDayIncluded: true)
            .filter { $0.start < span.end && $0.end > span.start }
    }

    /// Shared EventKit query: declined events are dropped everywhere
    /// (spec §3); cancelled recurring instances never appear in EventKit's
    /// own result, so no extra filtering is needed for those.
    /// Calendars of type `.birthday`/`.subscription` are excluded by
    /// default (never "what you're supposed to be doing"), plus any
    /// calendar name the user has opted out in Settings.
    private func fetch(from: Date, to: Date, allDayIncluded: Bool = false) -> [CalendarEvent] {
        let calendars = store.calendars(for: .event).filter { cal in
            cal.type != .birthday && cal.type != .subscription && !excludedNames.contains(cal.title)
        }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: calendars)
        return store.events(matching: predicate).compactMap { event -> CalendarEvent? in
            if !allDayIncluded, event.isAllDay { return nil }
            if let own = event.attendees?.first(where: { $0.isCurrentUser }),
               own.participantStatus == .declined { return nil }
            return CalendarEvent(id: event.eventIdentifier ?? UUID().uuidString,
                                 title: event.title ?? "",
                                 calendarName: event.calendar?.title ?? "",
                                 attendees: attendeeIdentities(event),
                                 start: event.startDate, end: event.endDate,
                                 tentative: isTentative(event),
                                 allDay: event.isAllDay)
        }
    }

    /// Lowercased emails where EventKit exposes one (`mailto:` URLs), else
    /// the attendee's display name — mirrors `EmailContext`'s own
    /// lowercased-address convention.
    private func attendeeIdentities(_ event: EKEvent) -> [String] {
        (event.attendees ?? []).compactMap { attendee -> String? in
            if attendee.url.scheme == "mailto" {
                return attendee.url.absoluteString
                    .replacingOccurrences(of: "mailto:", with: "").lowercased()
            }
            return attendee.name?.lowercased()
        }
    }

    /// A real signal at half weight, not a full one (spec §0 Q2): the event
    /// itself may be marked tentative, the local user's own RSVP may be
    /// tentative, or the calendar's own busy/free reading may say tentative.
    private func isTentative(_ event: EKEvent) -> Bool {
        if event.status == .tentative { return true }
        if event.availability == .tentative { return true }
        if let own = event.attendees?.first(where: { $0.isCurrentUser }),
           own.participantStatus == .tentative { return true }
        return false
    }
}
