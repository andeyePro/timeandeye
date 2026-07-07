import Foundation
import andeyeTTCore
#if canImport(CryptoKit)
import CryptoKit
#endif

/// v2 licence suite — the spec's acceptance criteria 1–14
/// ( §5). Checks mint
/// with throwaway keypairs + throwaway kids; the production PRIVATE keys
/// exist only in the pro repo's channels.
func licenseChecks(_ c: Checks) {
    #if canImport(CryptoKit)
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let day: TimeInterval = 86_400
    let twoHundredYears: TimeInterval = 200 * 365.25 * day

    let priv = Curve25519.Signing.PrivateKey()
    let privB = Curve25519.Signing.PrivateKey()
    let verifier = LicenseVerifier(
        keys: ["direct-2026": priv.publicKey.rawRepresentation,
               "web-2026": privB.publicKey.rawRepresentation],
        productID: "time.andeye")

    /// A fully-populated v2 licence with overridable fields.
    func license(tier: LicenseTier = .pro, kid: String = "direct-2026",
                 jti: String = "JTI-001", product: String = "time.andeye",
                 expires: Date? = nil,
                 connectors: [String] = ["xero"]) -> License {
        License(kid: kid, jti: jti, tier: tier,
                licensee: "Test User <licensee@example.com>", issued: t0,
                expires: expires ?? t0.addingTimeInterval(35 * day),
                product: product, connectors: connectors)
    }

    func mint(_ l: License, with key: Curve25519.Signing.PrivateKey = priv) throws -> String {
        try LicenseSigner.key(l, privateKey: key.rawRepresentation)
    }

    /// Hand-signed raw payload — for shapes the League of Nine-Field Structs
    /// cannot express (missing fields, wrong versions, unknown tiers).
    func rawKey(_ payloadJSON: String,
                with key: Curve25519.Signing.PrivateKey = priv) throws -> String {
        let payload = Data(payloadJSON.utf8)
        let sig = try key.signature(for: payload)
        return [LicenseVerifier.keyPrefix,
                LicenseVerifier.base64urlEncode(payload),
                LicenseVerifier.base64urlEncode(sig)].joined(separator: ".")
    }

    let issuedS = Int(t0.timeIntervalSince1970)
    let expiresS = Int(t0.addingTimeInterval(35 * day).timeIntervalSince1970)
    /// The complete hand-written payload, minus whatever a check strips.
    func fields(dropping dropped: Set<String> = [], v: String? = "2",
                tier: String = "\"pro\"") -> String {
        var parts: [String] = []
        if let v { parts.append("\"v\":\(v)") }
        for (k, val) in [("kid", "\"direct-2026\""), ("jti", "\"JTI-001\""),
                         ("tier", tier), ("licensee", "\"A\""),
                         ("issued", "\(issuedS)"), ("expires", "\(expiresS)"),
                         ("product", "\"time.andeye\""),
                         ("connectors", "[\"xero\"]")] where !dropped.contains(k) {
            parts.append("\"\(k)\":\(val)")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    c.check("1. round-trip: all nine fields mint, validate and decode back equal") {
        let l = license(tier: .plus, connectors: ["xero"])
        let key = try mint(l)
        try expect(key.hasPrefix("ANDEYE1."), "recognisable prefix")
        switch verifier.validate(key, now: t0) {
        case .success(let got):
            try expectEq(got.v, 2)
            try expectEq(got.kid, "direct-2026")
            try expectEq(got.jti, "JTI-001")
            try expectEq(got.tier, .plus)
            try expectEq(got.licensee, l.licensee)
            try expectClose(got.issued.timeIntervalSince1970,
                            l.issued.timeIntervalSince1970, accuracy: 1)
            try expectClose(got.expires.timeIntervalSince1970,
                            l.expires.timeIntervalSince1970, accuracy: 1)
            try expectEq(got.product, "time.andeye")
            try expectEq(got.connectors, ["xero"])
        case .failure(let e):
            throw CheckFailure(description: "expected valid, got \(e)")
        }
    }

    c.check("2. any absent required field fails .malformed — a lost expiry can NEVER become perpetual") {
        for missing in ["expires", "product", "connectors", "jti", "licensee"] {
            let key = try rawKey(fields(dropping: [missing]))
            try expectEq(verifier.validate(key, now: t0), .failure(.malformed),
                         "payload without \(missing) must fail closed")
        }
    }

    c.check("3. kid selects the pubkey; a kid claim signed by the WRONG key fails the signature") {
        // Signed by direct's key, claiming direct: valid.
        if case .failure(let e) = verifier.validate(try mint(license()), now: t0) {
            throw CheckFailure(description: "direct-signed direct key failed: \(e)")
        }
        // Signed by web's key, claiming web: valid too — the map selected it.
        if case .failure(let e) = verifier.validate(
            try mint(license(kid: "web-2026"), with: privB), now: t0) {
            throw CheckFailure(description: "web-signed web key failed: \(e)")
        }
        // Claims direct but signed by web's key: the claim picks direct's
        // pubkey, so verification fails — a kid is a lookup, never a trust.
        try expectEq(verifier.validate(try mint(license(), with: privB), now: t0),
                     .failure(.badSignature))
    }

    c.check("4. unknown kid fails .unknownKeyID, not .badSignature, not success") {
        try expectEq(verifier.validate(try mint(license(kid: "nonesuch-2030")), now: t0),
                     .failure(.unknownKeyID))
    }

    c.check("5. a retired keypair is dead; the surviving kid's keys still validate") {
        // Drop web-2026 (the compromised-channel story) — every web key dies,
        // direct keys are untouched.
        let pruned = LicenseVerifier(
            keys: ["direct-2026": priv.publicKey.rawRepresentation],
            productID: "time.andeye")
        try expectEq(pruned.validate(try mint(license(kid: "web-2026"), with: privB),
                                     now: t0),
                     .failure(.unknownKeyID))
        if case .failure(let e) = pruned.validate(try mint(license()), now: t0) {
            throw CheckFailure(description: "surviving kid's key failed: \(e)")
        }
    }

    c.check("6. wrong product rejects even with a valid signature") {
        try expectEq(verifier.validate(try mint(license(product: "other.andeye")), now: t0),
                     .failure(.wrongProduct))
    }

    c.check("7. a denylisted jti is revoked; the same key body under a clean jti validates") {
        let burning = LicenseVerifier(
            keys: ["direct-2026": priv.publicKey.rawRepresentation],
            productID: "time.andeye", denylist: ["JTI-LEAKED"])
        try expectEq(burning.validate(try mint(license(jti: "JTI-LEAKED")), now: t0),
                     .failure(.revoked("JTI-LEAKED")))
        if case .failure(let e) = burning.validate(try mint(license(jti: "JTI-CLEAN")),
                                                   now: t0) {
            throw CheckFailure(description: "clean jti failed: \(e)")
        }
    }

    c.check("8. version gate: v absent/1/3 → .unsupportedVersion; the old flat shape fails closed") {
        try expectEq(verifier.validate(try rawKey(fields(v: nil)), now: t0),
                     .failure(.unsupportedVersion), "absent v")
        try expectEq(verifier.validate(try rawKey(fields(v: "1")), now: t0),
                     .failure(.unsupportedVersion), "v=1")
        try expectEq(verifier.validate(try rawKey(fields(v: "3")), now: t0),
                     .failure(.unsupportedVersion), "v=3")
        // There is intentionally NO v1 compatibility path: no real v1 key
        // ever issued, so the flat {tier,licensee,issued} payload fails
        // closed (it has no kid to even select a key).
        let flat = try rawKey("{\"issued\":\(issuedS),\"licensee\":\"A\",\"tier\":\"pro\"}")
        try expectEq(verifier.validate(flat, now: t0), .failure(.malformed))
    }

    c.check("9. expiry: in-date lease ok; lapsed fails; a +200y lifetime outlives decades of clock") {
        let lease = try mint(license())
        if case .failure(let e) = verifier.validate(lease, now: t0) {
            throw CheckFailure(description: "in-date lease failed: \(e)")
        }
        guard case .failure(.expired) = verifier.validate(
            lease, now: t0.addingTimeInterval(36 * day)) else {
            throw CheckFailure(description: "lapsed lease must fail .expired")
        }
        let lifetime = try mint(license(
            tier: .plus, expires: t0.addingTimeInterval(twoHundredYears)))
        if case .failure(let e) = verifier.validate(
            lifetime, now: t0.addingTimeInterval(50 * 365 * day)) {
            throw CheckFailure(description: "lifetime key failed at +50y: \(e)")
        }
    }

    c.check("10. tamper and keygen both fail closed") {
        // Upgrade attack: swap in a pro payload under a plus key's signature.
        let plusKey = try mint(license(tier: .plus))
        let proKey = try mint(license(tier: .pro))
        let forged = plusKey.split(separator: ".")[0] + "."
            + proKey.split(separator: ".")[1] + "."
            + plusKey.split(separator: ".")[2]
        try expectEq(verifier.validate(String(forged), now: t0),
                     .failure(.badSignature))
        // Attacker-minted key with a perfectly valid kid claim.
        let attacker = Curve25519.Signing.PrivateKey()
        try expectEq(verifier.validate(try mint(license(tier: .enterprise),
                                                with: attacker), now: t0),
                     .failure(.badSignature))
    }

    c.check("11. entitlement gates registration: connectors[] AND the tier floor, fail-closed") {
        let xero = BackendEntitlementRequirement(requiredTier: .plus, connectorID: "xero")
        let quickbooks = BackendEntitlementRequirement(requiredTier: .plus, connectorID: "quickbooks")
        let fancy = BackendEntitlementRequirement(requiredTier: .premium, connectorID: "fancy")

        // Community (no licence): a built-in registers, a Pro connector never.
        let registry = BackendRegistry()
        registry.register(FakeBackend(owns: .op), id: "op-main", class: .pm,
                          requires: nil)
        try expectEq(registry.entries.count, 1, "requires-nil registers under nil licence")
        try expectEq(registry.register(FakeBackend(owns: .remote), id: "xero-1",
                                       class: .finance, requires: xero),
                     .denied(.noLicense))
        try expectEq(registry.entries.count, 1, "denial must register nothing")

        // The flagship: a Plus-Lifetime key registers its ONE listed
        // connector (standard floor is .plus — the two-gate AND passes).
        registry.license = license(tier: .plus, connectors: ["xero"])
        try expectEq(registry.register(FakeBackend(owns: .remote), id: "xero-1",
                                       class: .finance, requires: xero),
                     .allowed)
        // …and is capped at that one by the allowlist, not by any count rule.
        try expectEq(registry.register(FakeBackend(owns: .remote), id: "qb-1",
                                       class: .finance, requires: quickbooks),
                     .denied(.notInConnectors))

        // A pro key with a two-id list registers both.
        registry.license = license(tier: .pro, connectors: ["xero", "quickbooks"])
        try expectEq(registry.register(FakeBackend(owns: .remote), id: "qb-1",
                                       class: .finance, requires: quickbooks),
                     .allowed)

        // The class floor: premium connector under pro denies, under premium allows —
        // even though the id is allow-listed. Both gates, AND.
        registry.license = license(tier: .pro, connectors: ["fancy"])
        try expectEq(BackendRegistry.entitlement(license: registry.license, requires: fancy),
                     .denied(.tierBelowFloor(required: .premium)))
        registry.license = license(tier: .premium, connectors: ["fancy"])
        try expectEq(BackendRegistry.entitlement(license: registry.license, requires: fancy),
                     .allowed)
    }

    c.check("12. garbage is malformed, not a crash; unknown tier fails closed; whitespace forgiven") {
        for junk in ["", "ANDEYE1", "ANDEYE1.x", "ANDEYE1.!!.!!", "WRONG.a.b",
                     "AMBI1.a.b", "ANDE1.a.b",
                     "ANDEYE1.\(LicenseVerifier.base64urlEncode(Data("{}".utf8))).c"] {
            switch verifier.validate(junk, now: t0) {
            case .failure(.malformed), .failure(.badSignature): continue
            case let other: throw CheckFailure(description: "junk '\(junk)' → \(other)")
            }
        }
        // A validly-signed payload with an unknown tier rawValue: fail-closed
        // .malformed — a future fifth tier downgrades old builds to
        // Community rather than crashing (its SKU page carries a
        // minimum-app-version note).
        try expectEq(verifier.validate(try rawKey(fields(tier: "\"ultra\"")), now: t0),
                     .failure(.malformed))
        let key = "  " + (try mint(license())) + "\n"
        if case .failure = verifier.validate(key, now: t0) {
            throw CheckFailure(description: "surrounding whitespace must be trimmed")
        }
    }

    c.check("13. .clockRollback ships (enum stability) but is NOT in the v1 verify path") {
        // The case exists so landing the high-water-mark later is additive…
        let reserved: LicenseError = .clockRollback
        try expectEq(reserved, .clockRollback)
        // …and a validate() with `now` far in the past still only trips
        // expiry logic, never a rollback error (the mitigation is deferred).
        let key = try mint(license())
        if case .failure(.clockRollback) = verifier.validate(
            key, now: t0.addingTimeInterval(-365 * day)) {
            throw CheckFailure(description: "clock-rollback must not be enforced in v1")
        }
    }

    c.check("14. the tier ladder is pinned: plus < pro < premium < enterprise") {
        try expect(LicenseTier.plus < .pro, "plus < pro")
        try expect(LicenseTier.pro < .premium, "pro < premium")
        try expect(LicenseTier.premium < .enterprise, "premium < enterprise")
        try expect(!(LicenseTier.pro < .plus), "order is not reversed")
        try expect(LicenseTier.pro >= .pro, "floors are inclusive (>=)")
        // The gate the ladder exists for: a standard connector's floor is
        // .plus, so every paid tier passes it.
        for tier in LicenseTier.allCases {
            try expect(tier >= .plus, "\(tier) must clear a standard connector's floor")
        }
        // Completeness: comparing EVERY pair exercises the ladder lookup for
        // every case — a fifth tier added without updating the ladder array
        // fails HERE (loudly), not in a production comparison.
        for a in LicenseTier.allCases {
            for b in LicenseTier.allCases { _ = a < b }
        }
    }
    #endif
}
