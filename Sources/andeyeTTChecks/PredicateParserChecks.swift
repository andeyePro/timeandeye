import Foundation
import andeyeTTCore

func predicateParserChecks(_ c: Checks) {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let sig = ActivitySignal(app: "Ghostty", windowTitle: "andeyeTT — vim",
                             tabURL: "https://github.com/andeyePro/andeyeTT", timestamp: now)

    func parsed(_ s: String) throws -> andeyeTTCore.Predicate {
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
        try expectEq(try parsed("title starts with \"andeyeTT\""),
                     .leaf(field: .title, op: .startsWith, value: "andeyeTT"))
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
        let p = try parsed("andeyeTT")
        try expectEq(p, PredicateParser.anyFieldContains("andeyeTT"))
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
        let p = try parsed("title contains \"andeyeTT\" and app is not \"Ghostty\"")
        try expectEq(p, .and([
            .leaf(field: .title, op: .contains, value: "andeyeTT"),
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
        let cases: [andeyeTTCore.Predicate] = [
            .leaf(field: .app, op: .equals, value: "Ghostty"),
            .and([.leaf(field: .title, op: .contains, value: "andeyeTT"),
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

    c.check("operator aliases: = / equals / regex; written-out negations") {
        // `=` and `equals` are aliases of `is`; `regex` is an alias of `matches`.
        try expectEq(try parsed("app = \"Ghostty\""),
                     .leaf(field: .app, op: .equals, value: "Ghostty"))
        try expectEq(try parsed("app equals \"Ghostty\""),
                     .leaf(field: .app, op: .equals, value: "Ghostty"))
        try expectEq(try parsed("url regex \"amb.*\""),
                     .leaf(field: .url, op: .regex, value: "amb.*"))
        // `does not match` and the contracted `doesn't` negate the verb.
        try expectEq(try parsed("title does not match \"^Inv\""),
                     .not(.leaf(field: .title, op: .regex, value: "^Inv")))
        try expectEq(try parsed("app doesn't start with \"G\""),
                     .not(.leaf(field: .app, op: .startsWith, value: "G")))
    }

    c.check("double-not, logic-word-as-value, and unknown-verb fallthrough") {
        // `not not X` parses to a doubled negation (parseNot recurses).
        try expectEq(try parsed("not not app is \"Ghostty\""),
                     .not(.not(.leaf(field: .app, op: .equals, value: "Ghostty"))))
        // A logic word can't be swallowed as a leaf value: `app is and …` is an
        // error, not `app is "and"`.
        if case .success = PredicateParser.parse("app is and title contains \"x\"") {
            throw CheckFailure(description: "a logic word as a value must fail, not parse")
        }
        // `does <unknown-verb>` returns nil from parseOperator, so the field is
        // re-read as bare text → any-field-contains, which then chokes on the
        // trailing `"x"` it can't place: the whole expression errors.
        if case .success = PredicateParser.parse("app does frobnicate \"x\"") {
            throw CheckFailure(description: "an unknown verb after 'does' must not parse as a leaf")
        }
    }

    c.check("email fields: from/sender synonyms, subject, any") {
        try expectEq(try parsed("from contains \"harborlane.example\""),
                     .leaf(field: .sender, op: .contains, value: "harborlane.example"))
        try expectEq(try parsed("sender contains \"harborlane.example\""),
                     .leaf(field: .sender, op: .contains, value: "harborlane.example"))
        try expectEq(try parsed("subject contains \"renewal\""),
                     .leaf(field: .subject, op: .contains, value: "renewal"))
        try expectEq(try parsed("any contains \"foo\""),
                     .leaf(field: .any, op: .contains, value: "foo"))
        let email = ActivitySignal(
            app: "Mail", windowTitle: "Re: renewal",
            tabURL: nil, timestamp: now,
            correspondents: ["jane@harborlane.example"],
            emailSubject: "policy renewal")
        try expect(try parsed("from contains \"harborlane.example\"").evaluate(email))
        try expect(try parsed("subject contains \"renewal\"").evaluate(email))
    }

    c.check("bare text now also spans email correspondents + subject") {
        let email = ActivitySignal(
            app: "Mail", windowTitle: "Re: renewal",
            tabURL: nil, timestamp: now,
            correspondents: ["jane@harborlane.example"],
            emailSubject: "policy renewal")
        let p = try parsed("harborlane")
        try expectEq(p, PredicateParser.anyFieldContains("harborlane"))
        try expectEq(p, .leaf(field: .any, op: .contains, value: "harborlane"))
        try expect(p.evaluate(email), "bare keyword now hits a correspondent")
        try expect(try parsed("policy").evaluate(email), "bare keyword hits the subject too")
    }
}
