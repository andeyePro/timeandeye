import Foundation

/// Information architecture for the Settings window: the fixed category list
/// plus a searchable index of every setting, so the window can offer a
/// System-Settings-style sidebar and a ⌘F search that finds any control by
/// its visible label or a synonym. Pure data + string matching — the UI layer
/// renders it, the check suite proves it (every item points at a real
/// category, search is case/diacritic-insensitive, titles outrank keywords).
public enum SettingsIA {

    // MARK: Categories (sidebar order = declaration order)

    public enum Category: String, CaseIterable, Codable, Identifiable, Sendable {
        // Declaration order = sidebar order. Tracking leads (the app's core;
        // Martin, 2026-07-11: the backend connection is not the front page)
        // and the connection panel wears a plain-English name.
        case tracking
        case behaviour
        case menuBar
        case colours
        case localTasks
        case backend
        case billing
        case emailCalendar
        case maintenance
        case diagnostics
        case about

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .backend:       return "Connections"
            case .tracking:      return "Tracking"
            case .behaviour:     return "Behaviour"
            case .menuBar:       return "Menu bar"
            case .colours:       return "Colours"
            case .localTasks:    return "Local tasks"
            case .billing:       return "Billing"
            case .emailCalendar: return "Email & Calendar"
            case .maintenance:   return "Maintenance"
            case .diagnostics:   return "Diagnostics"
            case .about:         return "About"
            }
        }

        /// SF Symbol for the sidebar row.
        public var systemImage: String {
            switch self {
            case .backend:       return "link"
            case .tracking:      return "record.circle"
            case .behaviour:     return "slider.horizontal.3"
            case .menuBar:       return "menubar.rectangle"
            case .colours:       return "paintpalette"
            case .localTasks:    return "checklist"
            case .billing:       return "creditcard"
            case .emailCalendar: return "envelope"
            case .maintenance:   return "wrench.and.screwdriver"
            case .diagnostics:   return "stethoscope"
            case .about:         return "info.circle"
            }
        }
    }

    // MARK: Searchable items

    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        /// The control's visible label, verbatim — what the user's eye will
        /// look for after landing on the category.
        public let title: String
        /// Lowercase synonyms (include US spellings — colour/color).
        public let keywords: [String]
        public let category: Category

        public init(_ id: String, _ title: String, _ keywords: [String],
                    _ category: Category) {
            self.id = id
            self.title = title
            self.keywords = keywords
            self.category = category
        }
    }

    /// One entry per user-visible control. Conditional sections (posting
    /// health, billing mappings) stay indexed — search lands the user on the
    /// right category even when the section is currently empty.
    public static let items: [Item] = [
        // Backend
        Item("backend.url", "Instance URL",
             ["openproject", "server", "address", "connect", "http", "backend",
              "connections"], .backend),
        Item("backend.apiKey", "API key",
             ["token", "secret", "openproject", "connect", "password"], .backend),
        Item("backend.activity", "Default activity",
             ["openproject", "activity type"], .backend),
        Item("backend.health", "Posting health",
             ["stuck", "retry", "drifted", "quarantined", "failed"], .backend),
        Item("backend.unlock", "Unlock invoice",
             ["lock", "locked", "invoice", "xero", "billed"], .backend),
        // Tracking
        Item("tracking.autoPush", "Auto-push threshold",
             ["certainty", "automatic", "post", "upload", "push"], .tracking),
        Item("tracking.review", "Review threshold",
             ["queue", "certain", "ask", "review"], .tracking),
        Item("tracking.floor", "Review queue floor",
             ["brief", "glances", "seconds", "minimum"], .tracking),
        Item("tracking.refileMode", "When later evidence contradicts past entries",
             ["refile", "mis-filed", "update", "review mode", "correct"], .tracking),
        Item("tracking.autoComment", "Auto-comment time entries",
             ["apps", "docs", "comment"], .tracking),
        Item("tracking.commentTracked", "Comment to tracked time",
             ["note", "time entry"], .tracking),
        Item("tracking.commentTask", "Comment to task",
             ["note", "activity feed"], .tracking),
        // Behaviour
        Item("behaviour.switchBuffer", "Switch buffer",
             ["grace", "focus", "debounce", "merge"], .behaviour),
        Item("behaviour.sleepGrace", "Sleep grace",
             ["wake", "nap", "stop", "continue"], .behaviour),
        Item("behaviour.idleBackfill", "Offer to log time you were away",
             ["idle", "backfill", "away", "gap", "break"], .behaviour),
        Item("behaviour.popoverDefault", "Popover defaults to Reassign",
             ["switch to", "relabel", "change mode", "start fresh"], .behaviour),
        Item("behaviour.timeButton", "Time button opens",
             ["timeline", "pie", "last viewed", "chart"], .behaviour),
        Item("behaviour.notifications", "System notifications",
             ["sounds", "banners", "alerts"], .behaviour),
        Item("behaviour.quietPresenting", "Quiet while presenting",
             ["screen share", "privacy", "mirror", "mic", "banners"], .behaviour),
        Item("behaviour.lockOnLeave", "Lock the Mac when I leave my desk",
             ["lock screen", "leave", "away", "security"], .behaviour),
        Item("behaviour.leisure", "Track leisure to local-only tasks",
             ["non-work", "personal", "stop", "catch-all"], .behaviour),
        // Menu bar
        Item("menuBar.colourLow", "Low-certainty colour",
             ["color", "hex", "tint"], .menuBar),
        Item("menuBar.colourHigh", "High-certainty colour",
             ["color", "hex", "tint"], .menuBar),
        Item("menuBar.percent", "Show certainty %",
             ["percentage"], .menuBar),
        Item("menuBar.taskChars", "Task name in menu bar",
             ["letters", "chars", "title", "abbreviation"], .menuBar),
        // Colours
        Item("colours.rederive", "Re-derive automatic colours",
             ["re-apply", "from scratch", "cohesive", "palette", "reset colours",
              "color"], .colours),
        Item("colours.save", "Save colour set",
             ["export", "backup", "palette", "color"], .colours),
        Item("colours.load", "Load colour set",
             ["import", "restore", "palette", "color"], .colours),
        Item("colours.manual", "Manually picked colours",
             ["overrides", "picks", "edit", "revert", "color"], .colours),
        // Local tasks
        Item("localTasks.list", "Local tasks",
             ["personal", "private", "offline", "add task", "project"], .localTasks),
        Item("localTasks.catchAll", "Non-work catch-all task",
             ["leisure", "default", "personal"], .localTasks),
        // Billing
        Item("billing.currency", "Currency symbol",
             ["money", "locale", "billable", "pound", "dollar", "euro"], .billing),
        Item("billing.mappings", "Billing mappings",
             ["xero", "finance", "map", "invoice", "bills to"], .billing),
        // Email & Calendar
        Item("email.own", "My addresses/domains",
             ["own email", "me", "correspondent"], .emailCalendar),
        Item("email.rules", "Context rules",
             ["learned", "pinned", "forget", "provenance", "email rules"], .emailCalendar),
        Item("email.order", "Email match order",
             ["specificity", "level", "precedence", "general", "specific"], .emailCalendar),
        Item("calendar.enable", "Use my calendar",
             ["meetings", "events", "read-only"], .emailCalendar),
        Item("calendar.preAlert", "Alert before meetings",
             ["pulse", "lead", "calendar"], .emailCalendar),
        Item("calendar.startFlash", "Flash at meeting start",
             ["alert", "calendar"], .emailCalendar),
        Item("calendar.excluded", "Excluded calendars",
             ["ignore", "holidays", "birthdays"], .emailCalendar),
        // Maintenance
        Item("maintenance.duplicates", "Scan for duplicate OpenProject entries",
             ["duplicates", "reconcile", "merge", "clean up"], .maintenance),
        Item("maintenance.export", "Export timesheet",
             ["csv", "markdown", "copy", "spreadsheet", "invoice"], .maintenance),
        Item("maintenance.iCloud", "iCloud footprint",
             ["size", "storage", "quota", "sync", "cloudkit"], .maintenance),
        Item("maintenance.consolidate", "Consolidate old history",
             ["collapse", "rollup", "years", "daily totals", "shrink"], .maintenance),
        Item("maintenance.hardCap", "Hard cap",
             ["prune", "delete", "emergency", "mb", "cap"], .maintenance),
        // Diagnostics
        Item("diagnostics.mode", "Diagnostics mode",
             ["developer", "debug", "copy card", "affordances"], .diagnostics),
        Item("diagnostics.sender", "Probe email sender",
             ["accessibility", "extractor", "debug", "probe"], .diagnostics),
        Item("diagnostics.recipes", "What recipes see here",
             ["site recipe", "url", "title", "debug", "probe"], .diagnostics),
        // About
        Item("about.build", "Build details",
             ["version", "copy", "bug report", "about"], .about),
        Item("about.licence", "Licence",
             ["license", "key", "xero", "paid", "pro", "community", "renew"], .about),
    ]

    // MARK: Search

    /// Case/diacritic-insensitive multi-token search. Every whitespace-
    /// separated token must match the item (in its title or a keyword);
    /// items whose TITLE matches rank above keyword-only matches, title
    /// prefixes above title substrings, ties keep registry order.
    public static func search(_ query: String) -> [Item] {
        let tokens = fold(query).split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        // Score: 0 = title prefix, 1 = title substring, 2 = keyword only.
        // An item's score is its WORST token (every token must land).
        var scored: [(score: Int, index: Int, item: Item)] = []
        for (index, item) in items.enumerated() {
            let title = fold(item.title)
            let keywords = item.keywords.map(fold)
            var worst = 0
            var matched = true
            for token in tokens {
                let s: Int
                if title.hasPrefix(token) { s = 0 }
                else if title.contains(token) { s = 1 }
                else if keywords.contains(where: { $0.contains(token) }) { s = 2 }
                else { matched = false; break }
                worst = max(worst, s)
            }
            if matched { scored.append((worst, index, item)) }
        }
        return scored
            .sorted { ($0.score, $0.index) < ($1.score, $1.index) }
            .map(\.item)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive],
                  locale: Locale(identifier: "en_GB"))
         .lowercased()
    }
}
