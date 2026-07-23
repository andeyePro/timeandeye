import Foundation
import timeandeyeCore

func predicateChecks(_ c: Checks) {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let sig = ActivitySignal(app: "Ghostty", windowTitle: "timeandeye — vim",
                             tabURL: "https://github.com/andeyePro/timeandeye", timestamp: now)

    c.check("operators: equals/contains/startsWith/regex") {
        try expect(PinOp.equals.test("Ghostty", "ghostty"), "equals is case-insensitive")
        try expect(PinOp.contains.test("timeandeye — vim", "AndEye"))
        try expect(PinOp.startsWith.test("timeandeye — vim", "timeandeye"))
        try expect(PinOp.startsWith.test("timeandeye — vim", "TIMEANDEYE"), "startsWith is case-insensitive, like equals/contains")
        try expect(PinOp.startsWith.test("anything", ""), "empty prefix matches all (was hasPrefix)")
        try expect(!PinOp.startsWith.test("timeandeye — vim", "vim"))
        try expect(PinOp.regex.test("andeyett", "and.?y"))
        try expect(!PinOp.regex.test("foo", "(unterminated"), "bad regex never matches, never throws")
    }

    c.check("field extraction") {
        try expectEq(PinField.app.value(of: sig), "Ghostty")
        try expectEq(PinField.title.value(of: sig), "timeandeye — vim")
        try expectEq(PinField.url.value(of: sig), "https://github.com/andeyePro/timeandeye")
        let bare = ActivitySignal(app: "x", timestamp: now)
        try expectEq(PinField.url.value(of: bare), "", "missing url is empty, not nil-crash")
    }

    c.check("and/or/not evaluation") {
        let p = Predicate.and([
            .leaf(field: .app, op: .equals, value: "Ghostty"),
            .not(.leaf(field: .url, op: .contains, value: "gitlab")),
        ])
        try expect(p.evaluate(sig))
        let q = Predicate.or([
            .leaf(field: .title, op: .contains, value: "nope"),
            .leaf(field: .url, op: .contains, value: "github"),
        ])
        try expect(q.evaluate(sig))
        try expect(!Predicate.not(.leaf(field: .app, op: .equals, value: "Ghostty")).evaluate(sig))
    }

    c.check("leafCount is the specificity proxy") {
        let p = Predicate.and([
            .leaf(field: .app, op: .equals, value: "a"),
            .or([.leaf(field: .title, op: .contains, value: "b"),
                 .leaf(field: .url, op: .contains, value: "c")]),
        ])
        try expectEq(p.leafCount, 3)
    }

    c.check("Predicate + PinRule round-trip Codable") {
        let rule = PinRule.expression(.and([
            .leaf(field: .title, op: .contains, value: "timeandeye"),
            .not(.leaf(field: .url, op: .regex, value: "gitlab|bitbucket")),
        ]))
        let data = try JSONEncoder().encode(rule)
        let back = try JSONDecoder().decode(PinRule.self, from: data)
        try expectEq(back, rule)
        try expect(back.matches(sig))
    }

    c.check("email fields: sender/subject/any extraction and matching") {
        let email = ActivitySignal(
            app: "Mail", windowTitle: "Re: renewal — Inbox",
            tabURL: nil, timestamp: now,
            // Counterparties only (correspondents are sender + recipients MINUS
            // self), and neither may contain the "example.com" negative probe
            // below — a substring hit there would invert the boundary claim.
            correspondents: ["Jane Doe <jane@harborlane.example>", "sam@northgate.example"],
            emailSubject: "Re: policy renewal")
        try expect(Predicate.leaf(field: .sender, op: .contains, value: "harborlane.example").evaluate(email))
        try expect(!Predicate.leaf(field: .sender, op: .contains, value: "example.com").evaluate(email))
        try expect(Predicate.leaf(field: .subject, op: .contains, value: "renewal").evaluate(email))
        try expect(Predicate.leaf(field: .any, op: .contains, value: "harborlane").evaluate(email), "any reaches a correspondent")
        try expect(Predicate.leaf(field: .any, op: .contains, value: "renewal").evaluate(email), "any reaches the subject")
        try expect(Predicate.leaf(field: .any, op: .contains, value: "Mail").evaluate(email), "any still reaches app")
        try expectEq(PinField.subject.value(of: email), "Re: policy renewal")
        try expectEq(PinField.sender.values(of: email).count, 2)
    }

    c.check("nil correspondents/subject don't match and don't crash") {
        try expect(!Predicate.leaf(field: .sender, op: .contains, value: "anyone").evaluate(sig), "nil correspondents → no match")
        try expect(!Predicate.leaf(field: .subject, op: .contains, value: "anything").evaluate(sig), "nil subject → no match")
        try expectEq(PinField.sender.values(of: sig), [String](), "nil correspondents → empty value list")
        try expect(Predicate.leaf(field: .any, op: .contains, value: "timeandeye").evaluate(sig), "any spans title even with no email fields")
    }
}
