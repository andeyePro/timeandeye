import Foundation

/// Parse / render the typed Expression syntax for pins, e.g.
///
///     title contains "Ambitick" and not url contains "github"
///     app is "Ghostty" and title contains "voting"
///     url matches "amb.*"
///     Ambitick                     ← bare text = contains, in any field
///
/// Fields: `app`, `title`, `url`. Operators: `is`, `contains`, `starts with`,
/// `matches` (= regex). Logic: `and`, `or`, `not`, parentheses. A bare string
/// with no field / operator / logic means "any field contains this".
///
/// This is the text front-end to the same `Predicate` the engine evaluates, so
/// a typed expression and an AI-emitted one are the same thing — re-opening an
/// Expression pin just renders its `Predicate` back to text.
public enum PredicateParser {
    public enum ParseError: Error, Equatable {
        case empty
        case unexpected(String)
        case unbalancedParens
        case expectedValue
    }

    // MARK: Parse

    public static func parse(_ input: String) -> Result<Predicate, ParseError> {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        let toks = tokenize(trimmed)
        // No structure at all (no parens, no logic word, no field+operator) →
        // the whole thing is a bare "any field contains this" substring.
        if !hasStructure(toks) {
            return .success(anyFieldContains(trimmed))
        }
        var p = Cursor(toks: toks)
        do {
            let pred = try p.parseOr()
            guard p.atEnd else { return .failure(.unexpected(p.describeRest())) }
            return .success(pred)
        } catch let e as ParseError {
            return .failure(e)
        } catch {
            return .failure(.unexpected("\(error)"))
        }
    }

    /// "Any field contains" sugar, as an explicit OR over the observable fields.
    public static func anyFieldContains(_ value: String) -> Predicate {
        .or([.leaf(field: .app, op: .contains, value: value),
             .leaf(field: .title, op: .contains, value: value),
             .leaf(field: .url, op: .contains, value: value)])
    }

    // MARK: Render

    /// Render a `Predicate` back to the typed syntax. Compound children are
    /// parenthesised so the result always re-parses to the same tree.
    public static func string(from predicate: Predicate) -> String {
        switch predicate {
        case .leaf(let f, let op, let v):
            return "\(f.rawValue) \(word(for: op)) \"\(v)\""
        case .and(let ps):
            return ps.map(atom).joined(separator: " and ")
        case .or(let ps):
            return ps.map(atom).joined(separator: " or ")
        case .not(let p):
            return "not \(atom(p))"
        }
    }

    private static func atom(_ p: Predicate) -> String {
        switch p {
        case .leaf: return string(from: p)
        default:    return "(\(string(from: p)))"
        }
    }

    private static func word(for op: PinOp) -> String {
        switch op {
        case .equals:     return "is"
        case .contains:   return "contains"
        case .startsWith: return "starts with"
        case .regex:      return "matches"
        }
    }

    // MARK: Tokenizer

    enum Tok: Equatable { case lparen, rparen, word(String), quoted(String) }

    private static let logicWords: Set<String> = ["and", "or", "not"]

    static func tokenize(_ s: String) -> [Tok] {
        var toks: [Tok] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " || c == "\t" || c == "\n" { i += 1; continue }
            if c == "(" { toks.append(.lparen); i += 1; continue }
            if c == ")" { toks.append(.rparen); i += 1; continue }
            if c == "\"" {
                i += 1
                var v = ""
                while i < chars.count, chars[i] != "\"" { v.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 }   // consume closing quote
                toks.append(.quoted(v))
                continue
            }
            var w = ""
            while i < chars.count, !" \t\n()\"".contains(chars[i]) { w.append(chars[i]); i += 1 }
            toks.append(.word(w))
        }
        return toks
    }

    /// Does the token stream carry boolean/field structure, or is it just bare
    /// text? Bare text (no parens, no logic word, no field-followed-by-operator)
    /// is treated as an any-field-contains substring.
    private static func hasStructure(_ toks: [Tok]) -> Bool {
        for (idx, t) in toks.enumerated() {
            switch t {
            case .lparen, .rparen: return true
            case .quoted: return true   // a quoted value implies field/op intent
            case .word(let w):
                let lw = w.lowercased()
                if logicWords.contains(lw) { return true }
                if PinField(token: lw) != nil, idx + 1 < toks.count,
                   case .word(let n)? = toks[safe: idx + 1],
                   operatorWord(n.lowercased()) != nil {
                    return true
                }
            }
        }
        return false
    }

    private static func operatorWord(_ w: String) -> PinOp? {
        switch w {
        case "is", "equals": return .equals
        case "contains": return .contains
        case "matches", "regex": return .regex
        case "starts": return .startsWith   // "starts with" — the "with" is consumed in parse
        default: return nil
        }
    }

    // MARK: Recursive-descent cursor

    private struct Cursor {
        let toks: [Tok]
        var i = 0

        var atEnd: Bool { i >= toks.count }
        func peek() -> Tok? { i < toks.count ? toks[i] : nil }

        mutating func matchWord(_ w: String) -> Bool {
            if case .word(let x)? = peek(), x.lowercased() == w { i += 1; return true }
            return false
        }

        mutating func parseOr() throws -> Predicate {
            var parts = [try parseAnd()]
            while matchWord("or") { parts.append(try parseAnd()) }
            return parts.count == 1 ? parts[0] : .or(parts)
        }

        mutating func parseAnd() throws -> Predicate {
            var parts = [try parseNot()]
            while matchWord("and") { parts.append(try parseNot()) }
            return parts.count == 1 ? parts[0] : .and(parts)
        }

        mutating func parseNot() throws -> Predicate {
            if matchWord("not") { return .not(try parseNot()) }
            return try parseAtom()
        }

        mutating func parseAtom() throws -> Predicate {
            guard let t = peek() else { throw ParseError.unexpected("end of expression") }
            if case .lparen = t {
                i += 1
                let e = try parseOr()
                guard case .rparen? = peek() else { throw ParseError.unbalancedParens }
                i += 1
                return e
            }
            return try parseLeaf()
        }

        mutating func parseLeaf() throws -> Predicate {
            // field operator value ?
            if case .word(let w)? = peek(), let field = PinField(token: w.lowercased()) {
                let save = i
                i += 1
                if let op = parseOperator() {
                    guard let v = parseValue() else { throw ParseError.expectedValue }
                    return .leaf(field: field, op: op, value: v)
                }
                i = save   // it wasn't field+operator after all — treat as bare text
            }
            // bare value → any field contains
            guard let v = parseValue() else {
                throw ParseError.unexpected(describeRest())
            }
            return PredicateParser.anyFieldContains(v)
        }

        mutating func parseOperator() -> PinOp? {
            guard case .word(let w)? = peek() else { return nil }
            guard let op = PredicateParser.operatorWord(w.lowercased()) else { return nil }
            i += 1
            // "starts with": swallow the following "with".
            if op == .startsWith, case .word(let n)? = peek(), n.lowercased() == "with" {
                i += 1
            }
            return op
        }

        mutating func parseValue() -> String? {
            switch peek() {
            case .quoted(let v): i += 1; return v
            case .word(let w):
                let lw = w.lowercased()
                // Don't swallow logic keywords as a value.
                if PredicateParser.logicWords.contains(lw) { return nil }
                i += 1
                return w
            default:
                return nil
            }
        }

        func describeRest() -> String {
            toks[i...].prefix(3).map { tok in
                switch tok {
                case .lparen: return "("
                case .rparen: return ")"
                case .word(let w): return w
                case .quoted(let v): return "\"\(v)\""
                }
            }.joined(separator: " ")
        }
    }
}

private extension PinField {
    init?(token: String) {
        switch token {
        case "app": self = .app
        case "title": self = .title
        case "url": self = .url
        default: return nil
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
