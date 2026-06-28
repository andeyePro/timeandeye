import Foundation

/// Cold-start AI assist. v0.1 has NO API integration: the app copies a prompt
/// to the clipboard, the user pastes it into the AI of their choice, then
/// pastes the response back. Strict validation on the way back in.
public enum AIAssist {
    public struct Assignment: Equatable, Sendable {
        public var segmentID: UUID
        public var target: Target
        public init(segmentID: UUID, target: Target) {
            self.segmentID = segmentID
            self.target = target
        }
    }

    public enum ParseError: Error {
        case notJSON
        case badShape(String)
        case unknownSegment(String)
        case badTask(String)
    }

    public static func classificationPrompt(tasks: [WorkTask],
                                            segments: [ReviewSegment]) -> String {
        var lines: [String] = []
        lines.append("You are classifying time-tracking log segments against a task list.")
        lines.append("")
        lines.append("TASKS (id: subject [project, status]):")
        for t in tasks {
            if case .op(let id) = t.ref {
                lines.append("#\(id): \(t.subject) [\(t.project ?? "-"), \(t.status)]")
            }
        }
        lines.append("")
        lines.append("SEGMENTS (uuid | app | window title | url | minutes):")
        for s in segments {
            let minutes = Int(s.end.timeIntervalSince(s.start) / 60)
            lines.append("\(s.id.uuidString) | \(s.app) | \(s.windowTitle ?? "-") | \(s.tabURL ?? "-") | \(minutes)")
        }
        lines.append("")
        lines.append("""
        Reply with ONLY this JSON, no prose:
        {"assignments": [{"segment": "<uuid>", "task": <task id number or "do-not-track">}]}
        Use "do-not-track" for segments that are clearly not work on any listed task.
        """)
        return lines.joined(separator: "\n")
    }

    /// The default guidance seeded into the pin AI prompt — nudges the model
    /// toward a robust rule rather than one keyed on a volatile window title.
    public static let defaultPinAdvice =
        "Prefer a stable title or URL pattern. If the title looks volatile " +
        "(it has counts, timestamps, or document names that change), key on a " +
        "more robust field, or suggest a setup change that would make it stable."

    /// Build the clipboard prompt that asks an AI to write ONE pin rule (a boolean
    /// expression in the app's grammar) for the given window. `advice` is the
    /// editable guidance box (see `defaultPinAdvice`).
    public static func pinRulePrompt(app: String, title: String?, url: String?,
                                     advice: String) -> String {
        var lines: [String] = []
        lines.append("You are writing ONE matching rule for a macOS time-tracker.")
        lines.append("The rule decides whether a window/tab is ALWAYS a particular task.")
        lines.append("")
        lines.append("The window I want to pin:")
        lines.append("- app:   \(app)")
        lines.append("- title: \(title ?? "(none)")")
        lines.append("- url:   \(url ?? "(none)")")
        lines.append("")
        lines.append("Reply with a boolean expression in this grammar:")
        lines.append("  fields:    app, title, url")
        lines.append("  operators: is, contains, starts with, matches (regex)")
        lines.append("  logic:     and, or, not, parentheses")
        lines.append("  values are double-quoted, e.g.  title contains \"Inbox\"")
        lines.append("  examples:  app is \"Ghostty\" and title contains \"voting\"")
        lines.append("             url contains \"openproject\" and not title contains \"Sign in\"")
        let trimmed = advice.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            lines.append("")
            lines.append("Guidance: \(trimmed)")
        }
        lines.append("")
        lines.append("Output ONLY the expression on a single line — no backticks, no explanation.")
        return lines.joined(separator: "\n")
    }

    /// Clean an AI's pin-rule reply down to the single expression line: strips
    /// ``` fences and takes the first non-empty line (models sometimes add a note).
    public static func cleanRuleReply(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let firstLine = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return firstLine ?? text
    }

    // Codable (not JSONSerialization) so Bool/Int are discriminated correctly
    // on Apple platforms, where NSNumber(1) bridges to Bool.
    private struct Response: Decodable {
        struct Entry: Decodable {
            let segment: String
            let task: TaskValue
        }
        let assignments: [Entry]
    }

    private enum TaskValue: Decodable {
        case id(Int)
        case doNotTrack

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) {
                self = .id(n)
            } else if let s = try? c.decode(String.self), s == "do-not-track" {
                self = .doNotTrack
            } else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "task must be an integer id or \"do-not-track\"")
            }
        }
    }

    public static func parseResponse(_ raw: String,
                                     validSegmentIDs: Set<UUID>) throws -> [Assignment] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate ```json fences that chat UIs love to add.
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: Data(text.utf8))
        } catch let error as DecodingError {
            if case .dataCorrupted(let ctx) = error, ctx.codingPath.last?.stringValue == "task" {
                throw ParseError.badTask(ctx.debugDescription)
            }
            throw ParseError.badShape(String(describing: error))
        } catch {
            throw ParseError.notJSON
        }
        // Skip entries that don't match a current segment (a hallucinated or
        // mistyped uuid, or one already assigned in another batch) rather than
        // rejecting the WHOLE paste on the first bad one — one stray uuid used
        // to throw away 300 good assignments. The caller applies what matched.
        return response.assignments.compactMap { entry -> Assignment? in
            guard let id = UUID(uuidString: entry.segment),
                  validSegmentIDs.contains(id) else { return nil }
            switch entry.task {
            case .id(let n): return Assignment(segmentID: id, target: .task(.op(n)))
            case .doNotTrack: return Assignment(segmentID: id, target: .doNotTrack)
            }
        }
    }
}
