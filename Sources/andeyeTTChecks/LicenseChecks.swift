import Foundation
import andeyeTTCore
#if canImport(CryptoKit)
import CryptoKit
#endif

func licenseChecks(_ c: Checks) {
    #if canImport(CryptoKit)
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    // Checks mint with their own throwaway keypair — the production PRIVATE
    // key exists only in the pro repo's generator.
    let priv = Curve25519.Signing.PrivateKey()
    let verifier = LicenseVerifier(publicKey: priv.publicKey.rawRepresentation)

    func mint(_ license: License) throws -> String {
        try LicenseSigner.key(license, privateKey: priv.rawRepresentation)
    }

    c.check("a minted key validates and round-trips its payload") {
        let license = License(tier: .pro, licensee: "Test User <licensee@example.com>",
                              issued: t0)
        let key = try mint(license)
        try expect(key.hasPrefix("ANDEYE1."), "recognisable prefix")
        switch verifier.validate(key, now: t0) {
        case .success(let got):
            // Dates went through secondsSince1970 encoding — compare seconds.
            try expectEq(got.tier, .pro)
            try expectEq(got.licensee, license.licensee)
            try expectClose(got.issued.timeIntervalSince1970,
                            license.issued.timeIntervalSince1970, accuracy: 1)
            try expectNil(got.expires)
            try expect(got.tier.unlocksProBackends)
        case .failure(let e):
            throw CheckFailure(description: "expected valid, got \(e)")
        }
    }

    c.check("tampered payload and wrong key both fail closed") {
        let key = try mint(License(tier: .plus, licensee: "A", issued: t0))
        // Upgrade attack: swap the payload for a pro one, keep the signature.
        let proKey = try mint(License(tier: .pro, licensee: "A", issued: t0))
        let forged = key.split(separator: ".")[0] + "."
            + proKey.split(separator: ".")[1] + "."
            + key.split(separator: ".")[2]
        try expectEq(verifier.validate(String(forged), now: t0),
                     .failure(.badSignature))
        // A key minted by a DIFFERENT private key (e.g. a keygen) never passes.
        let attacker = Curve25519.Signing.PrivateKey()
        let fake = try LicenseSigner.key(License(tier: .enterprise, licensee: "x", issued: t0),
                                         privateKey: attacker.rawRepresentation)
        try expectEq(verifier.validate(fake, now: t0), .failure(.badSignature))
    }

    c.check("expiry honoured; perpetual keys never expire") {
        let subKey = try mint(License(tier: .pro, licensee: "A", issued: t0,
                                      expires: t0.addingTimeInterval(86_400)))
        switch verifier.validate(subKey, now: t0) {
        case .success: break
        case .failure(let e): throw CheckFailure(description: "in-date key failed: \(e)")
        }
        guard case .failure(.expired) = verifier.validate(
            subKey, now: t0.addingTimeInterval(200_000)) else {
            throw CheckFailure(description: "expired key must fail")
        }
        let perpetual = try mint(License(tier: .pro, licensee: "A", issued: t0))
        if case .failure = verifier.validate(perpetual,
                                             now: t0.addingTimeInterval(50 * 365 * 86_400)) {
            throw CheckFailure(description: "perpetual key expired")
        }
    }

    c.check("garbage is malformed, not a crash") {
        // Both retired prefixes (AMBI1, ANDE1) must now reject — no dual-accept.
        for junk in ["", "ANDEYE1", "ANDEYE1.x", "ANDEYE1.!!.!!", "WRONG.a.b",
                     "AMBI1.a.b", "ANDE1.a.b",
                     "ANDEYE1.\(LicenseVerifier.base64urlEncode(Data("{}".utf8))).c"] {
            switch verifier.validate(junk, now: t0) {
            case .failure(.malformed), .failure(.badSignature): continue
            case let other: throw CheckFailure(description: "junk '\(junk)' → \(other)")
            }
        }
        // Whitespace around a pasted key is forgiven.
        let key = "  " + (try mint(License(tier: .pro, licensee: "A", issued: t0))) + "\n"
        if case .failure = verifier.validate(key, now: t0) {
            throw CheckFailure(description: "surrounding whitespace must be trimmed")
        }
    }

    c.check("tier ladder: only plus withholds pro backends") {
        try expect(!LicenseTier.plus.unlocksProBackends)
        try expect(LicenseTier.pro.unlocksProBackends)
        try expect(LicenseTier.premium.unlocksProBackends)
        try expect(LicenseTier.enterprise.unlocksProBackends)
    }
    #endif
}
