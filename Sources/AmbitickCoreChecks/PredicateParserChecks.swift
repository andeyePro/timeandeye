import Foundation
import AmbitickCore

func predicateParserChecks(_ c: Checks) {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let sig = ActivitySignal(app: "Ghostty", windowTitle: "Ambitick — vim",
                             tabURL: "https://github.com/aqueum/ambitick", timestamp: now)

    func parsed(_ s: String) throws -> AmbitickCore.Predicate {
        switch PredicateParser.parse(s) {
        case .success(let p): return p
        case .failure(let e): throw CheckFailure(description: "parse failed: \(e) for \(s)")
        }
    }

    c.check("single leaf with each operator") {
        try expectEq(try parsed("app is \"Ghostty\""),
                     .leaf(field: .app, op: .equals, value: "Ghostty"))
        try expectEq(try parsed("title contains \"vim\""),
                     .leaf(field: .title, op: .contains, value: "vim"))
        try expectEq(try parsed("title starts with \"Ambitick\""),
                     .leaf(field: .title, op: .startsWith, value: "Ambitick"))
        try expectEq(try parsed("url matches \"amb.*\""),
                     .leaf(field: .url, op: .regex, value: "amb.*"))
    }

    c.check("and / or / not with precedence (and binds tighter than or)") {
        let p = try parsed("app is \"Ghostty\" and title contains \"vim\" or url contains \"github\"")
        // Expect (A and B) or C
        try expectEq(p, .or([
            .and([.leaf(field: .app, op: .equals, value: "Ghostty"),
                  .leaf(field: .title, op: .contains, value: "vim")]),
            .leaf(field: .url, op: .contains, value: "github"),
        ]))
        try expect(p.evaluate(sig))
    }

    c.check("not and parentheses") {
        let p = try parsed("not (url contains \"gitlab\")")
        try expectEq(p, .not(.leaf(field: .url, op: .contains, value: "gitlab")))
        try expect(p.evaluate(sig), "github url does not contain gitlab → not = true")
    }

    c.check("bare text means contains-any-field") {
        let p = try parsed("Ambitick")
        try expectEq(p, PredicateParser.anyFieldContains("Ambitick"))
        try expect(p.evaluate(sig), "matches the window title")
        // A bare multi-word string is one substring, not an AND.
        try expectEq(try parsed("voting site"), PredicateParser.anyFieldContains("voting site"))
    }

    c.check("negation: 'is not' and 'does not contain'") {
        try expectEq(try parsed("app is not \"Ghostty\""),
                     .not(.leaf(field: .app, op: .equals, value: "Ghostty")))
        try expectEq(try parsed("url does not contain \"github\""),
                     .not(.leaf(field: .url, op: .contains, value: "github")))
        try expectEq(try parsed("title doesn't match \"^Inv\""),
                     .not(.leaf(field: .title, op: .regex, value: "^Inv")))
        // The user's example must now parse.
        let p = try parsed("title contains \"Ambitick\" and app is not \"Ghostty\"")
        try expectEq(p, .and([
            .leaf(field: .title, op: .contains, value: "Ambitick"),
            .not(.leaf(field: .app, op: .equals, value: "Ghostty")),
        ]))
    }

    c.check("an unquoted single-word value is accepted") {
        try expectEq(try parsed("app is Ghostty"),
                     .leaf(field: .app, op: .equals, value: "Ghostty"))
    }

    c.check("errors: empty, unbalanced parens, dangling operator") {
        try expectEq(PredicateParser.parse("   "), .failure(.empty))
        if case .success = PredicateParser.parse("(app is \"x\"") {
            throw CheckFailure(description: "unbalanced parens should fail")
        }
        if case .success = PredicateParser.parse("app is and title contains \"x\"") {
            throw CheckFailure(description: "operator with no value should fail")
        }
    }

    c.check("render round-trips back to an equal predicate") {
        let cases: [AmbitickCore.Predicate] = [
            .leaf(field: .app, op: .equals, value: "Ghostty"),
            .and([.leaf(field: .title, op: .contains, value: "Ambitick"),
                  .not(.leaf(field: .url, op: .regex, value: "gitlab|bitbucket"))]),
            .or([.leaf(field: .title, op: .startsWith, value: "Inv"),
                 .and([.leaf(field: .app, op: .equals, value: "Chrome"),
                       .leaf(field: .url, op: .contains, value: "openproject")])]),
        ]
        for p in cases {
            let text = PredicateParser.string(from: p)
            try expectEq(try parsed(text), p, "round-trip failed for: \(text)")
        }
    }
}
