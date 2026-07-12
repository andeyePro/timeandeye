import Foundation
import timeandeyeCore

// MARK: - Site recipes (2026-07-09 site-recipes spec, acceptance criteria §10)

private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

private func urlSignal(_ url: String, title: String? = nil,
                       app: String = "Google Chrome") -> ActivitySignal {
    ActivitySignal(app: app, windowTitle: title, tabURL: url, timestamp: t0)
}

/// The canonical GitHub issue fixture — a real URL/title shape.
private func githubIssueSignal() -> ActivitySignal {
    urlSignal("https://github.com/example-org/example-repo/issues/42",
              title: "Pin editor loses focus · Issue #42 · example-org/example-repo")
}

/// ⚠️ The Xero fixture encodes the ASSUMED shapes (spec §4.3 — asserted from
/// memory, not a live session): an org shortcode path segment starting "!",
/// the app section right after it, a "<page> | Xero" title. Verify against
/// real go.xero.com pages (Settings ▸ Diagnostics ▸ "What recipes see here")
/// and fix recipe + fixture TOGETHER if they differ.
private func xeroSignal() -> ActivitySignal {
    urlSignal("https://go.xero.com/app/!x7Kp2/invoicing",
              title: "Amounts owed to you | Xero")
}

// MARK: - Extraction (criteria 1 + 2)

func siteRecipeExtractionChecks(_ c: Checks) {
    c.check("host matching is anchored: subdomains yes, lookalikes and suffix attacks no (C20)") {
        try expectNil(SiteRecipes.recipe(forHost: "notgithub.com"))
        try expectNil(SiteRecipes.recipe(forHost: "github.com.evil.example"))
        try expectEq(SiteRecipes.recipe(forHost: "github.com")?.id, "github")
        try expectEq(SiteRecipes.recipe(forHost: "gist.github.com")?.id, "github")
        try expectEq(SiteRecipes.recipe(forHost: "drive.google.com")?.id, "gdocs")
    }

    c.check("mail-system hosts never produce a SiteContext — email keeps its own pipeline") {
        let gmail = urlSignal("https://mail.google.com/mail/u/0/#inbox/FMfcgz001",
                              title: "Re: Renewals - Gmail")
        try expectNil(SiteRecipes.extract(gmail))
        try expectNil(SiteRecipes.context(for: gmail), "not even the host-only degradation")
    }

    c.check("GitHub issue page: owner/repo/section identity + the item title as content") {
        let site = try unwrap(SiteRecipes.extract(githubIssueSignal()))
        try expectEq(site.recipe?.id, "github")
        try expectEq(site.host, "github.com")
        try expectEq(site.values["owner"], "example-org")
        try expectEq(site.values["repo"], "example-repo")
        try expectEq(site.values["section"], "issues")
        try expectEq(site.values["title"], "Pin editor loses focus")
    }

    c.check("GitHub PR page: 'pull' section, title from the · separator") {
        let pr = urlSignal("https://github.com/example-org/example-repo/pull/7",
                           title: "Fix pin focus by martin · Pull Request #7 · example-org/example-repo")
        let site = try unwrap(SiteRecipes.extract(pr))
        try expectEq(site.values["section"], "pull")
        try expectEq(site.values["title"], "Fix pin focus by martin")
    }

    c.check("GitHub repo home: owner+repo only — no junk section, no junk title (path gate)") {
        // The title has no path-named issue/PR, so the content field must
        // ghost — a repo description must never become a "title" rule value.
        let home = urlSignal("https://github.com/example-org/example-repo",
                             title: "GitHub - example-org/example-repo")
        let site = try unwrap(SiteRecipes.extract(home))
        try expectEq(site.values["owner"], "example-org")
        try expectEq(site.values["repo"], "example-repo")
        try expectNil(site.values["section"], "tree/blob/etc are not sections; absent means ABSENT")
        try expectNil(site.values["title"], "no issue number in the path → no content value")
    }

    c.check("GitHub reserved first segment: view gate refuses; host-only context survives") {
        let notifications = urlSignal("https://github.com/notifications", title: "Notifications")
        try expectNil(SiteRecipes.extract(notifications))
        let context = try unwrap(SiteRecipes.context(for: notifications))
        try expectNil(context.recipe)
        try expectEq(context.host, "github.com")
        try expect(context.values.isEmpty)
    }

    c.check("Google Doc: type + stable id + title (suffix stripped)") {
        let doc = urlSignal("https://docs.google.com/document/d/d1AbC/edit",
                            title: "andeye accounts FY26 - Google Docs")
        let site = try unwrap(SiteRecipes.extract(doc))
        try expectEq(site.recipe?.id, "gdocs")
        try expectEq(site.values["docType"], "document")
        try expectEq(site.values["document"], "d1AbC")
        try expectEq(site.values["docTitle"], "andeye accounts FY26")
    }

    c.check("Google Sheet + Drive folder shapes") {
        let sheet = urlSignal("https://docs.google.com/spreadsheets/d/sh33t/edit#gid=0",
                              title: "Q3 billing - Google Sheets")
        let sheetSite = try unwrap(SiteRecipes.extract(sheet))
        try expectEq(sheetSite.values["docType"], "spreadsheets")
        try expectEq(sheetSite.values["document"], "sh33t")
        try expectEq(sheetSite.values["docTitle"], "Q3 billing")
        let folder = urlSignal("https://drive.google.com/drive/folders/f00bar",
                               title: "Receipts - Google Drive")
        let folderSite = try unwrap(SiteRecipes.extract(folder))
        try expectEq(folderSite.values["docType"], "drive")
        try expectEq(folderSite.values["document"], "f00bar")
    }

    c.check("Docs lagging SPA title (no Google suffix) ghosts the title, keeps the id") {
        // Tier 0's one stale-ish input is the window title — the 'Inbox (1)'
        // staleness lesson applied (spec §9): suffix mismatch = no value.
        let doc = urlSignal("https://docs.google.com/document/d/d1AbC/edit",
                            title: "Inbox (1)")
        let site = try unwrap(SiteRecipes.extract(doc))
        try expectEq(site.values["document"], "d1AbC")
        try expectNil(site.values["docTitle"], "a lagging title must not mint a junk value")
    }

    c.check("Docs view gate: no d/<id> or folder id → nil (list surfaces aren't documents)") {
        try expectNil(SiteRecipes.extract(urlSignal("https://docs.google.com/document/u/0/",
                                                    title: "Google Docs")))
    }

    c.check("Xero org page (ASSUMED shapes — verify live before trusting, spec §4.3)") {
        let site = try unwrap(SiteRecipes.extract(xeroSignal()))
        try expectEq(site.recipe?.id, "xero")
        try expectEq(site.values["organisation"], "!x7Kp2")
        try expectEq(site.values["section"], "invoicing")
        try expectEq(site.values["pageTitle"], "Amounts owed to you")
    }

    c.check("Xero page without the assumed !shortcode: gate refuses, host grain survives") {
        let dashboard = urlSignal("https://go.xero.com/dashboard", title: "Dashboard | Xero")
        try expectNil(SiteRecipes.extract(dashboard))
        try expectEq(SiteRecipes.context(for: dashboard)?.host, "go.xero.com")
    }

    c.check("a disabled recipe extracts nothing; the host-only context survives (Q4 toggle)") {
        try expectNil(SiteRecipes.extract(githubIssueSignal(), disabled: ["github"]))
        let context = try unwrap(SiteRecipes.context(for: githubIssueSignal(),
                                                     disabled: ["github"]))
        try expectNil(context.recipe)
        try expectEq(context.host, "github.com")
    }

    c.check("probeText names the recipe and every field; refuses mail hosts") {
        let text = SiteRecipes.probeText(for: githubIssueSignal())
        try expect(text.contains("GitHub"))
        try expect(text.contains("Repository: example-repo"))
        try expect(text.contains("Owner: example-org"))
        let home = SiteRecipes.probeText(for: urlSignal("https://github.com/example-org/example-repo",
                                                        title: "GitHub - example-org/example-repo"))
        try expect(home.contains("Section: not captured"), "ghosts are named, never hidden")
        let mail = SiteRecipes.probeText(
            for: urlSignal("https://mail.google.com/mail/u/0/#inbox", title: "Inbox - Gmail"))
        try expect(mail.contains("email keeps its own pipeline"))
        let disabled = SiteRecipes.probeText(for: githubIssueSignal(), disabled: ["github"])
        try expect(disabled.contains("DISABLED"))
    }
}

// MARK: - Identity chain shape (criterion 3)

func siteIdentityChecks(_ c: Checks) {
    c.check("a recipe page chains host + ◆ fields + content — REPLACING the raw path (no duplication)") {
        let id = ContextIdentity.from(githubIssueSignal())
        try expectEq(id.segments.map(\.kind),
                     [.urlHost, .recipeField("owner"), .recipeField("repo"),
                      .recipeField("section"), .recipeField("title")])
        try expectEq(id.segments.map(\.value),
                     ["github.com", "example-org", "example-repo", "issues", "Pin editor loses focus"])
        try expect(!id.segments.contains { $0.kind == .urlPath },
                   "raw path segments must NOT ride alongside the fields (spec §6)")
        try expect(id.segments[4].display.contains("Pin editor loses focus")
                       && id.segments[4].display.hasPrefix("\u{201C}"),
                   "content fields display quoted, like the subject row")
    }

    c.check("missing fields render as ghost rows — absent but visible (§5.5 convention)") {
        let id = ContextIdentity.from(urlSignal("https://github.com/example-org/example-repo",
                                                title: "GitHub - example-org/example-repo"))
        let section = try unwrap(id.segments.first { $0.kind == .recipeField("section") })
        try expect(!section.available)
        try expectEq(section.display, "not captured")
        let title = try unwrap(id.segments.first { $0.kind == .recipeField("title") })
        try expect(!title.available)
    }

    c.check("the document row keys on the opaque id but DISPLAYS the human title") {
        let id = ContextIdentity.from(urlSignal(
            "https://docs.google.com/document/d/d1AbC/edit",
            title: "andeye accounts FY26 - Google Docs"))
        let document = try unwrap(id.segments.first { $0.kind == .recipeField("document") })
        try expectEq(document.value, "d1AbC", "the rule survives a rename because it keys on the id")
        try expectEq(document.display, "andeye accounts FY26")
    }

    c.check("siteDefaultGrainIndex is the recipe's DECLARED default: repo / document / organisation") {
        try expectEq(ContextIdentity.from(githubIssueSignal()).siteDefaultGrainIndex, 3)
        try expectEq(ContextIdentity.from(urlSignal(
            "https://docs.google.com/document/d/d1AbC/edit",
            title: "x - Google Docs")).siteDefaultGrainIndex, 3)
        // Xero's default is organisation — the FIRST field, proving the
        // default is declared per recipe, not positional (spec §6).
        try expectEq(ContextIdentity.from(xeroSignal()).siteDefaultGrainIndex, 2)
        // Default field not captured → the host row still commits.
        try expectEq(ContextIdentity.from(urlSignal("https://github.com/example-org",
                                                    title: "example-org")).siteDefaultGrainIndex, 1)
    }

    c.check("footerDefaultGrainIndex: email default first, recipe default next, host row on ANY web page, nil on app windows (Q2)") {
        try expectEq(ContextIdentity.from(githubIssueSignal()).footerDefaultGrainIndex, 3)
        let plain = ContextIdentity.from(urlSignal("https://forum.example.com/t/123",
                                                   title: "A thread"))
        try expectEq(plain.footerDefaultGrainIndex, 1, "the policy note's one-tap host grain")
        try expectEq(plain.siteDefaultGrainIndex, nil, "no recipe → no recipe default")
        let appWindow = ContextIdentity.from(ActivitySignal(app: "Ghostty",
                                                            windowTitle: "timeandeye — vim",
                                                            timestamp: t0))
        try expectNil(appWindow.footerDefaultGrainIndex, "no URL, no site rule, no footer")
    }

    c.check("a DISABLED recipe's page keeps today's PinScope chain byte-for-byte (toggle regression)") {
        let sig = githubIssueSignal()
        let id = ContextIdentity.from(sig, disabledRecipes: ["github"])
        try expectEq(id.segments.map(\.kind),
                     [.urlHost, .urlPath, .urlPath, .urlPath, .urlPath])
        try expectEq(id.segments.map(\.value), PinScope.identity(of: sig)?.segments ?? [])
    }

    c.check("siteHostChain: the disagreeing-batch degradation — host row only; nil for mail") {
        let chain = try unwrap(ContextIdentity.siteHostChain(of: githubIssueSignal()))
        try expectEq(chain.segments.map(\.kind), [.urlHost])
        try expectEq(chain.segments[0].value, "github.com")
        try expectEq(chain.footerDefaultGrainIndex, 1)
        try expectNil(ContextIdentity.siteHostChain(of: urlSignal(
            "https://mail.google.com/mail/u/0/#inbox", title: "Inbox - Gmail")))
    }

    c.check("a review row's stored URL/title re-derives recipe grains at render time (criterion 9)") {
        // No ReviewSegment schema change: the footer builds identity from
        // row.signal, so OLD queue rows gain recipe grains retroactively.
        let row = ReviewSegment(app: "Google Chrome",
                                windowTitle: "Pin editor loses focus · Issue #42 · example-org/example-repo",
                                tabURL: "https://github.com/example-org/example-repo/issues/42",
                                start: t0, end: t0.addingTimeInterval(300))
        let id = ContextIdentity.from(row.signal)
        try expectEq(id.footerDefaultGrainIndex, 3)
        try expectEq(id.segments[2].value, "example-repo")
    }

    c.check("caller-supplied recipeFields (Tier 1 DOM values, later) still splice after the root") {
        let sig = urlSignal("https://crm.example.com/clients/9", title: "Acme")
        let id = ContextIdentity.from(sig, recipeFields: [(name: "client", value: "Acme Ltd")])
        try expectEq(id.segments[0].kind, .urlHost)
        try expectEq(id.segments[1].kind, .recipeField("client"))
        try expectEq(id.segments[1].value, "Acme Ltd")
    }
}

// MARK: - SiteMatcher (criterion 4)

func siteMatcherChecks(_ c: Checks) {
    let github = SiteRecipes.extract(githubIssueSignal())!
    func rule(_ field: String, _ value: String, to id: Int, recipe: String? = "github",
              pinned: Bool = false, at: Date = t0) -> SiteRule {
        SiteRule(recipeID: field == SiteRule.siteField ? nil : recipe, field: field,
                 value: value, target: .op(id), pinned: pinned, createdAt: at)
    }

    c.check("most specific level wins over the recipe's declared order; site sits below all fields") {
        let rules = [rule("site", "github.com", to: 1),
                     rule("owner", "example-org", to: 2),
                     rule("repo", "example-repo", to: 3)]
        try expectEq(SiteMatcher.match(github, rules: rules)?.target, .op(3))
        try expectEq(SiteMatcher.match(github, rules: Array(rules.prefix(2)))?.target, .op(2))
        try expectEq(SiteMatcher.match(github, rules: Array(rules.prefix(1)))?.target, .op(1))
    }

    c.check("content field is most specific and matches by case-insensitive SUBSTRING") {
        let rules = [rule("repo", "example-repo", to: 1),
                     rule("title", "pin editor", to: 2)]
        try expectEq(SiteMatcher.match(github, rules: rules)?.target, .op(2))
        try expectNil(SiteMatcher.match(github, rules: [rule("title", "invoicing", to: 9)]))
    }

    c.check("identity fields match by EQUALITY (case-insensitive), never substring") {
        try expectNil(SiteMatcher.match(github, rules: [rule("repo", "example-rep", to: 9)]),
                      "'example-rep' must not match repo 'example-repo'")
        try expectEq(SiteMatcher.match(github, rules: [rule("repo", "EXAMPLE-REPO", to: 1)])?.target,
                     .op(1))
    }

    c.check("pinned beats learned at a level; newest unpinned wins ties (EmailMatcher verbatim)") {
        let older = rule("repo", "example-repo", to: 1, at: t0)
        let newer = rule("repo", "example-repo", to: 2, at: t0.addingTimeInterval(60))
        try expectEq(SiteMatcher.match(github, rules: [older, newer])?.target, .op(2))
        let pinnedRule = rule("repo", "example-repo", to: 3, pinned: true)
        try expectEq(SiteMatcher.match(github, rules: [older, pinnedRule, newer])?.target, .op(3))
    }

    c.check("a recipe-field rule never fires on another recipe's page or a host-only context") {
        let xero = SiteRecipes.extract(xeroSignal())!
        try expectNil(SiteMatcher.match(xero, rules: [rule("repo", "example-repo", to: 9)]))
        // Host-only context (recipe disabled): field rules dormant, site rules live.
        let hostOnly = SiteRecipes.context(for: githubIssueSignal(), disabled: ["github"])!
        try expectNil(SiteMatcher.match(hostOnly, rules: [rule("repo", "example-repo", to: 9)]))
        try expectEq(SiteMatcher.match(hostOnly, rules: [rule("site", "github.com", to: 1)])?.target,
                     .op(1))
    }

    c.check("the site level needs no recipe: it matches on ANY non-mail page (Q2)") {
        let anywhere = SiteRecipes.context(
            for: urlSignal("https://forum.example.com/t/123", title: "Thread"))!
        try expectEq(SiteMatcher.match(anywhere,
                                       rules: [rule("site", "forum.example.com", to: 4)])?.target,
                     .op(4))
    }
}

// MARK: - Attributor rung + un-learn (criteria 5 + 6)

func siteRulePrecedenceChecks(_ c: Checks) {
    let host = "op.example.com"
    let tasks = [WorkTask(ref: .op(1), subject: "Repo work", status: "Open"),
                 WorkTask(ref: .op(2), subject: "Other", status: "Open")]
    func repoRule(to id: Int, pinned: Bool = false) -> SiteRule {
        SiteRule(recipeID: "github", field: "repo", value: "example-repo", target: .op(id),
                 pinned: pinned, createdAt: t0)
    }

    c.check("a site rule wins at exactly the 0.95 inferred ceiling over primes and the ranker") {
        let a = Attributor(instanceHost: host)
        a.siteRules = [repoRule(to: 1)]
        a.learnSurface(githubIssueSignal(), to: .op(2), weight: 4)   // a prime to beat
        let result = a.attribute(githubIssueSignal(), tasks: tasks, now: t0)
        try expectEq(result.best?.target, .task(.op(1)))
        try expectClose(result.certainty, Attributor.inferredCeiling)
    }

    c.check("a pin beats a site rule (1.0 over 0.95)") {
        let a = Attributor(instanceHost: host)
        a.siteRules = [repoRule(to: 1)]
        a.upsert(Pin(rule: .components(PinScope(kind: .url, prefix: ["github.com"])), task: .op(2)))
        let result = a.attribute(githubIssueSignal(), tasks: tasks, now: t0)
        try expectEq(result.best?.target, .task(.op(2)))
        try expectClose(result.certainty, 1.0)
    }

    c.check("a session sticky beats a site rule (your word today outranks the learned rule)") {
        let a = Attributor(instanceHost: host)
        a.siteRules = [repoRule(to: 1)]
        a.assign(githubIssueSignal(), target: .task(.op(2)), tasks: tasks, now: t0)
        let result = a.attribute(githubIssueSignal(), tasks: tasks, now: t0)
        try expectEq(result.best?.target, .task(.op(2)))
    }

    c.check("a backend task URL beats a site rule — the recognizer already answered") {
        let a = Attributor(instanceHost: host)
        a.siteRules = [SiteRule(recipeID: nil, field: SiteRule.siteField,
                                value: host, target: .op(1), createdAt: t0)]
        let wpPage = urlSignal("https://\(host)/work_packages/7", title: "WP 7")
        let result = a.attribute(wpPage, tasks: tasks, now: t0)
        try expectEq(result.best?.target, .task(.op(7)))
    }

    c.check("mail hosts and site rules are disjoint: a rule on a mail host can never fire") {
        let a = Attributor(instanceHost: host)
        a.siteRules = [SiteRule(recipeID: nil, field: SiteRule.siteField,
                                value: "mail.google.com", target: .op(1), createdAt: t0)]
        let gmail = urlSignal("https://mail.google.com/mail/u/0/#inbox", title: "Inbox - Gmail")
        try expectNil(a.siteRuleMatch(gmail))
        // Whatever the ranked fallback picks, it is a fallback — never the
        // rule's 0.95 rung.
        try expect(a.attribute(gmail, tasks: tasks, now: t0).certainty
                       < Attributor.inferredCeiling)
    }

    c.check("fire provenance bumps only on a real attribute() win; onFirstSiteFire exactly once at 0→1") {
        let a = Attributor(instanceHost: host)
        a.siteRules = [repoRule(to: 1)]
        var firstFires = 0
        a.onFirstSiteFire = { _ in firstFires += 1 }
        _ = a.explain(githubIssueSignal(), tasks: tasks, now: t0)
        _ = a.siteRuleMatch(githubIssueSignal())
        try expectEq(a.siteRules[0].fireCount, 0, "explain/match must never bump provenance")
        _ = a.attribute(githubIssueSignal(), tasks: tasks, now: t0)
        try expectEq(a.siteRules[0].fireCount, 1)
        try expectEq(a.siteRules[0].lastFired, t0)
        _ = a.attribute(githubIssueSignal(), tasks: tasks, now: t0.addingTimeInterval(60))
        try expectEq(a.siteRules[0].fireCount, 2)
        try expectEq(firstFires, 1, "the first-fire hook is once per rule lifetime")
    }

    c.check("explain mirrors the decision: source .siteRule carrying the exact matched rule") {
        let a = Attributor(instanceHost: host)
        a.siteRules = [repoRule(to: 1)]
        let e = a.explain(githubIssueSignal(), tasks: tasks, now: t0)
        try expectEq(e.source, .siteRule)
        try expectEq(e.chosen, .task(.op(1)))
        try expectClose(e.chosenScore, Attributor.inferredCeiling)
        try expectEq(e.matchedSiteRule?.value, "example-repo")
    }

    c.check("forgettable returns the unpinned site rule that fired; nil for a pinned one") {
        let a = Attributor(instanceHost: host)
        a.siteRules = [repoRule(to: 1)]
        try expectEq(a.forgettable(for: githubIssueSignal(), now: t0),
                     .siteRule(a.siteRules[0]))
        a.siteRules = [repoRule(to: 1, pinned: true)]
        try expectNil(a.forgettable(for: githubIssueSignal(), now: t0),
                      "a pinned rule counts as a pin here — lifted in the ledger, not forgotten")
    }

    c.check("forget removes exactly the named rule; explainWithout restores state byte-for-byte") {
        let a = Attributor(instanceHost: host)
        let keep = SiteRule(recipeID: "github", field: "owner", value: "example-org",
                            target: .op(2), createdAt: t0)
        a.siteRules = [repoRule(to: 1), keep]
        let before = a.siteRules
        let preview = a.explainWithout(.siteRule(a.siteRules[0]), githubIssueSignal(),
                                       tasks: tasks, now: t0)
        try expectEq(preview.chosen, .task(.op(2)), "without repo, the owner rule answers")
        try expectEq(a.siteRules, before, "explainWithout must leave no trace")
        a.forget(.siteRule(before[0]), signal: githubIssueSignal())
        try expectEq(a.siteRules, [keep])
    }

    c.check("forgettableWithout exposes the fallback's own forgettable, without mutating") {
        let a = Attributor(instanceHost: host)
        let repo = repoRule(to: 1)
        let owner = SiteRule(recipeID: "github", field: "owner", value: "example-org",
                             target: .op(2), createdAt: t0)
        a.siteRules = [repo, owner]
        try expectEq(a.forgettableWithout(.siteRule(repo), githubIssueSignal(), now: t0),
                     .siteRule(owner))
        try expectEq(a.siteRules, [repo, owner])
    }

    c.check("learnSiteRule replaces an existing UNPINNED same-grain rule; a pinned one survives") {
        let a = Attributor(instanceHost: host)
        a.learnSiteRule(recipeID: "github", field: "repo", value: "Example-Repo", to: .op(1), now: t0)
        try expectEq(a.siteRules.count, 1)
        try expectEq(a.siteRules[0].value, "example-repo", "stored lowercased")
        a.learnSiteRule(recipeID: "github", field: "repo", value: "example-repo", to: .op(2), now: t0)
        try expectEq(a.siteRules.count, 1, "the unpinned rule was replaced, not stacked")
        try expectEq(a.siteRules[0].target, .op(2))
        let pinned = SiteRule(recipeID: "github", field: "repo", value: "example-repo",
                              target: .op(3), pinned: true, createdAt: t0)
        a.siteRules.append(pinned)
        a.learnSiteRule(recipeID: "github", field: "repo", value: "example-repo", to: .op(4), now: t0)
        try expect(a.siteRules.contains { $0.sameRule(as: pinned) },
                   "a pinned rule is never silently replaced")
    }

    c.check("a disabled recipe's rules go dormant; the host rule still fires (toggle semantics)") {
        let a = Attributor(instanceHost: host)
        a.siteRules = [repoRule(to: 1),
                       SiteRule(recipeID: nil, field: SiteRule.siteField,
                                value: "github.com", target: .op(2), createdAt: t0)]
        a.disabledSiteRecipes = ["github"]
        try expectEq(a.siteRuleMatch(githubIssueSignal())?.target, .op(2),
                     "the repo rule sleeps; the host rule holds the fort")
    }

    c.check("siterules.json round-trip + metadata-lenient decode (new-file store, no migration)") {
        let rule = repoRule(to: 1)
        let data = try JSONEncoder().encode([rule])
        let decoded = try JSONDecoder().decode([SiteRule].self, from: data)
        try expectEq(decoded, [rule])
        // Strip the provenance keys — a hand-edited/older row still loads.
        var json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        json[0].removeValue(forKey: "createdAt")
        json[0].removeValue(forKey: "origin")
        json[0].removeValue(forKey: "fireCount")
        let lenient = try JSONDecoder().decode(
            [SiteRule].self, from: JSONSerialization.data(withJSONObject: json))
        try expectEq(lenient[0].createdAt, .distantPast)
        try expectEq(lenient[0].origin, .migrated)
        try expectEq(lenient[0].fireCount, 0)
    }
}

// MARK: - Learned features + compliance (criteria 7 + 8)

func siteFeatureChecks(_ c: Checks) {
    c.check("a recipe-matched signal emits .recipeField features for IDENTITY fields only") {
        let feats = LearningStore.features(from: githubIssueSignal())
        try expect(feats.contains(Feature(.recipeField, "github.owner=example-org")))
        try expect(feats.contains(Feature(.recipeField, "github.repo=example-repo")))
        try expect(feats.contains(Feature(.recipeField, "github.section=issues")))
        try expect(!feats.contains { $0.kind == .recipeField && $0.value.contains("github.title=") },
                   "content fields never become features — a whole issue title would never repeat")
        // The coarse urlPath feature is untouched (owner-level, as before).
        try expect(feats.contains(Feature(.urlPath, "github.com/example-org")))
    }

    c.check("a disabled recipe emits no recipe features (spec §8: disabled = extracts nothing)") {
        let feats = LearningStore.features(from: githubIssueSignal(),
                                           disabledRecipes: ["github"])
        try expect(!feats.contains { $0.kind == .recipeField })
    }

    c.check("non-recipe pages emit no recipe features — inert until a recipe matches") {
        let feats = LearningStore.features(from: urlSignal(
            "https://forum.example.com/t/123", title: "Thread"))
        try expect(!feats.contains { $0.kind == .recipeField })
    }

    c.check("learning.json with unknown-kind rows still decodes (additive migration, criterion 7)") {
        var store = LearningStore()
        store.learn(githubIssueSignal(), target: .task(.op(1)), weight: 2)
        let json = String(data: try JSONEncoder().encode(store), encoding: .utf8)!
        // Simulate a NEWER build's kind landing in this build's file.
        let futured = json.replacingOccurrences(of: "\"titleToken\"", with: "\"telepathyToken\"")
        let decoded = try JSONDecoder().decode(LearningStore.self,
                                               from: Data(futured.utf8))
        try expect(!decoded.isEmpty, "the store survives; unknown rows land as .unknown")
        // And directly: an unrecognised rawValue maps to .unknown, not a throw.
        let feature = try JSONDecoder().decode(
            Feature.self, from: Data("{\"kind\":\"fromTheFuture\",\"value\":\"x\"}".utf8))
        try expectEq(feature.kind, .unknown)
    }

    c.check("compliance: on a recipe'd Xero host, every learned feature derives from the SIGNAL (§8)") {
        // The Xero T&Cs freeze, extended per spec §8: seed a signal on a
        // recipe'd host, learn against a Xero-backend task, and assert the
        // persisted model contains nothing that isn't on the user's screen.
        let signal = xeroSignal()
        let xeroTask = WorkTask(ref: .remote("guid-site-compliance"),
                                subject: "XERO-API-SUBJECT-3F9Z", project: "Xero Client Co",
                                status: "ACTIVE")
        var store = LearningStore()
        store.learn(signal, target: .task(xeroTask.ref), weight: 2)
        let json = String(data: try JSONEncoder().encode(store), encoding: .utf8)!
        try expect(!json.contains("XERO-API-SUBJECT-3F9Z"), "API text must never enter the model")
        try expect(!json.contains("Xero Client Co"))
        try expect(json.contains("guid-site-compliance"), "the ref IS the documented label boundary")
        // Structural half: every feature VALUE is traceable to the signal's
        // own app/title/URL (or the derived hour bucket).
        let screen = "\(signal.app) \(signal.windowTitle ?? "") \(signal.tabURL ?? "")".lowercased()
        for feature in LearningStore.features(from: signal) where feature.kind != .hourOfDay {
            let value = feature.kind == .recipeField
                ? String(feature.value.split(separator: "=", maxSplits: 1).last ?? "")
                : feature.value
            try expect(screen.contains(value.lowercased()),
                       "feature \(feature.kind.rawValue)=\(feature.value) not on-screen")
        }
    }
}

// MARK: - Ledger grouping/export (criterion 10)

func siteLedgerChecks(_ c: Checks) {
    let names: [TaskRef: String] = [.op(1): "Brain work", .op(2): "Accounts"]
    func name(_ ref: TaskRef) -> String { names[ref] ?? "?" }
    let repo = SiteRule(recipeID: "github", field: "repo", value: "example-repo",
                        target: .op(1), createdAt: t0, fireCount: 3)
    let owner = SiteRule(recipeID: "github", field: "owner", value: "example-org",
                         target: .op(1), pinned: true, createdAt: t0.addingTimeInterval(-60))
    let org = SiteRule(recipeID: "xero", field: "organisation", value: "!x7kp2",
                       target: .op(2), createdAt: t0, fireCount: 9)

    c.check("groups sort by task name; rows pinned-first then most-fired then newest") {
        let groups = SiteRulesLedger.grouped([repo, owner, org], nameOf: name)
        try expectEq(groups.map { name($0.target) }, ["Accounts", "Brain work"])
        try expectEq(groups[1].rows, [owner, repo], "pinned outranks the busier learned rule")
    }

    c.check("search matches value, grain label and task name") {
        try expectEq(SiteRulesLedger.grouped([repo, owner, org], nameOf: name,
                                             search: "example-repo").flatMap(\.rows), [repo])
        try expectEq(SiteRulesLedger.grouped([repo, owner, org], nameOf: name,
                                             search: "organisation").flatMap(\.rows), [org])
        try expectEq(SiteRulesLedger.grouped([repo, owner, org], nameOf: name,
                                             search: "accounts").flatMap(\.rows), [org])
    }

    c.check("export text: grouped, grain-labelled, provenance on every line") {
        let text = SiteRulesLedger.exportText([repo, org], nameOf: name)
        try expect(text.contains("Brain work"))
        try expect(text.contains("GitHub repository: example-repo"))
        try expect(text.contains("Xero organisation: !x7kp2"))
        try expect(text.contains("fired 9×"))
        try expect(text.hasSuffix("\n"))
        try expectEq(SiteRulesLedger.exportText([], nameOf: name),
                     "No site rules learned or pinned yet.\n")
    }

    c.check("grainLabel: reserved site level, recipe labels, raw field for a retired recipe") {
        try expectEq(SiteRule(recipeID: nil, field: SiteRule.siteField, value: "x",
                              target: .op(1)).grainLabel, "Site")
        try expectEq(repo.grainLabel, "GitHub repository")
        try expectEq(SiteRule(recipeID: "gone", field: "client", value: "x",
                              target: .op(1)).grainLabel, "client")
    }
}
