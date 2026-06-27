import Foundation
import AmbitickCore

func predicateChecks(_ c: Checks) {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    let sig = ActivitySignal(app: "Ghostty", windowTitle: "Ambitick — vim",
                             tabURL: "https://github.com/aqueum/ambitick", timestamp: now)

    c.check("operators: equals/contains/startsWith/regex") {
        try expect(PinOp.equals.test("Ghostty", "ghostty"), "equals is case-insensitive")
        try expect(PinOp.contains.test("Ambitick — vim", "ambitick"))
        try expect(PinOp.startsWith.test("Ambitick — vim", "Ambitick"))
        try expect(PinOp.startsWith.test("Ambitick — vim", "ambitick"), "startsWith is case-insensitive, like equals/contains")
        try expect(PinOp.startsWith.test("anything", ""), "empty prefix matches all (was hasPrefix)")
        try expect(!PinOp.startsWith.test("Ambitick — vim", "vim"))
        try expect(PinOp.regex.test("ambitick", "amb.?t"))
        try expect(!PinOp.regex.test("foo", "(unterminated"), "bad regex never matches, never throws")
    }

    c.check("field extraction") {
        try expectEq(PinField.app.value(of: sig), "Ghostty")
        try expectEq(PinField.title.value(of: sig), "Ambitick — vim")
        try expectEq(PinField.url.value(of: sig), "https://github.com/aqueum/ambitick")
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
            .leaf(field: .title, op: .contains, value: "Ambitick"),
            .not(.leaf(field: .url, op: .regex, value: "gitlab|bitbucket")),
        ]))
        let data = try JSONEncoder().encode(rule)
        let back = try JSONDecoder().decode(PinRule.self, from: data)
        try expectEq(back, rule)
        try expect(back.matches(sig))
    }
}
