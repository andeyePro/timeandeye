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
        return try response.assignments.map { entry in
            guard let id = UUID(uuidString: entry.segment) else {
                throw ParseError.badShape("bad segment uuid: \(entry.segment)")
            }
            guard validSegmentIDs.contains(id) else {
                throw ParseError.unknownSegment(entry.segment)
            }
            switch entry.task {
            case .id(let n): return Assignment(segmentID: id, target: .task(.op(n)))
            case .doNotTrack: return Assignment(segmentID: id, target: .doNotTrack)
            }
        }
    }
}
