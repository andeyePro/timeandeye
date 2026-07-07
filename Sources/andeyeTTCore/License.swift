import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Paid tiers. Community is the absence of a licence, not a tier — the app is
/// fully functional without one; a licence only ADDS (the ability to register
/// entitlement-bearing Pro connectors).
///
/// rawValues are FROZEN strings — they cross the wire inside signed payloads;
/// renaming one invalidates issued keys. The ladder order below is likewise
/// part of the cross-repo contract (andeyePro mirrors it): a connector's
/// class floor is a single `key.tier >= connector.requiredTier` comparison.
public enum LicenseTier: String, Codable, Sendable, CaseIterable, Comparable {
    case plus, pro, premium, enterprise

    /// The contract's ladder, written out explicitly rather than derived from
    /// case order so an innocent reorder of the cases can never silently
    /// reverse every entitlement gate. Pinned by a check on BOTH repos.
    private static let ladder: [LicenseTier] = [.plus, .pro, .premium, .enterprise]

    public static func < (a: LicenseTier, b: LicenseTier) -> Bool {
        ladder.firstIndex(of: a)! < ladder.firstIndex(of: b)!
    }
}

/// The signed payload inside a licence key — schema v2 (spec
///  §1, the locked
/// cross-repo contract; andeyePro's generator mirrors it VERBATIM).
///
/// ALL nine fields are REQUIRED — there are no optionals, so a payload
/// missing any field fails the decode and the verifier returns `.malformed`:
/// fail closed. In particular a lost/omitted `expires` can never become a
/// perpetual key; LIFETIME is an explicit far-future date (`issued + 200y`)
/// minted only by the generator's `--lifetime` flag, never an absence.
public struct License: Codable, Equatable, Sendable {
    /// Payload schema version. 2 is the only accepted value; there was never
    /// a real v1 key (the flat shape existed only in dev/checks).
    public var v: Int
    /// KEY ID — selects which embedded public key verifies this key.
    public var kid: String
    /// Per-key serial, unique across ALL mint channels (ULID or kid-prefixed
    /// serial). Names a single key for the denylist.
    public var jti: String
    public var tier: LicenseTier
    /// Who it was issued to (shown in Settings; part of the signed payload so
    /// keys aren't anonymous pastebin currency).
    public var licensee: String
    public var issued: Date
    /// REQUIRED. A lease carries ~35 days; a lifetime key carries
    /// `issued + 200y`. The verifier has NO lifetime concept — it only checks
    /// that this is present and in the future.
    public var expires: Date
    /// Product/app id (aka `aud`) — matched against the verifier's own
    /// `productID`, so a Time-andeye key can't validate in a sibling app.
    public var product: String
    /// Explicit connector-id allowlist — authoritative for connector IDENTITY
    /// and COUNT (a plus key carries exactly one id). The tier supplies only
    /// the per-connector class floor. Ids are frozen for the life of every
    /// issued key; `*` and ids containing `:` are reserved, never minted.
    public var connectors: [String]

    public init(v: Int = 2, kid: String, jti: String, tier: LicenseTier,
                licensee: String, issued: Date, expires: Date,
                product: String, connectors: [String]) {
        self.v = v
        self.kid = kid
        self.jti = jti
        self.tier = tier
        self.licensee = licensee
        self.issued = issued
        self.expires = expires
        self.product = product
        self.connectors = connectors
    }
}

public enum LicenseError: Error, Equatable {
    /// Not `ANDEYE1.<payload>.<sig>`, bad base64url, or ANY required field
    /// absent/undecodable (incl. expires, product, connectors, an unknown
    /// tier rawValue) — the decode itself fails closed.
    case malformed
    /// `kid` not in the verifier's key set — a retired keypair is dead.
    case unknownKeyID
    case badSignature
    /// `v` absent or != 2 (no silent v1 accept; no real v1 key ever issued).
    case unsupportedVersion
    /// Payload `product` differs from this app's own productID.
    case wrongProduct
    /// jti is on the shipped denylist (carries the jti).
    case revoked(String)
    /// Valid key, past its expiry (expires is always present in v2).
    case expired(Date)
    /// Reserved for the monotonic high-water-mark mitigation (spec §3.2,
    /// deliberately NOT in the v1 verify path — the case ships so the enum
    /// is stable when it lands).
    case clockRollback
    /// Platform without CryptoKit (Linux CI) — never valid.
    case unsupported
}

/// Offline verification of `ANDEYE1.<base64url payload>.<base64url sig>` keys
/// (dot-separated, JWT-style — "-" and "_" belong to base64url itself).
/// Ed25519 over the exact payload bytes; the private keys live ONLY in the
/// pro repo's channels (Martin's password manager; the web-sales function's
/// secret store) — this side can verify but never mint. Verification is pure
/// and offline: no phone-home, works forever, works air-gapped. Absence of
/// network never denies a good key.
public struct LicenseVerifier: Sendable {
    /// kid → raw 32-byte Ed25519 public key. Multiple kids so a compromised
    /// channel keypair can be dropped in an app update without touching the
    /// other channels' keys.
    public let keys: [String: Data]
    /// This app's own product id — a key minted for a sibling andeye app
    /// never validates here.
    public let productID: String
    /// Revoked jtis, shipped statically in the binary (spec open Q1: v1 is
    /// the in-binary list; a signed-blob refresh can arrive later with no
    /// format change).
    public let denylist: Set<String>

    public init(keys: [String: Data], productID: String, denylist: Set<String> = []) {
        self.keys = keys
        self.productID = productID
        self.denylist = denylist
    }

    /// PENDING Martin's lock of spec open Q3 — proposal `"time.andeye"`.
    public static let timeAndeyeProductID = "time.andeye"
    /// Direct/manual + lifetime sales keypair id.
    public static let directKID = "direct-2026"
    /// Cloudflare-Function web-sales keypair id (public half not yet minted;
    /// added to `production.keys` when the pro repo mints it).
    public static let webKID = "web-2026"

    /// The production key set. The direct pair was ROTATED 2026-07-02
    /// (Martin minted it himself; private half lives only in Apple
    /// Passwords). The first pair was retired unused after transiting a
    /// plaintext file. The web-2026 public half lands here when the pro
    /// repo's Cloudflare channel mints its keypair.
    public static let production = LicenseVerifier(
        keys: [directKID: Data(base64Encoded: "hGcCOyMchBHEdj3xgNJJplJQwv1oK+Gseju7ZaCnf1w=")!],
        productID: timeAndeyeProductID,
        denylist: [])

    public static let keyPrefix = "ANDEYE1"   // AMBI1 → ANDE1 → ANDEYE1 (2026-07-07, lockstep with the pro generator); still BEFORE any real key was issued, so no dual-accept needed

    /// Minimal pre-verification probe: only `kid` (to select the key) and
    /// `v` (to distinguish version errors) are read from the UNVERIFIED
    /// payload; nothing else is trusted before the signature check.
    private struct Probe: Codable {
        var kid: String?
        var v: Int?
    }

    /// Verify + decode + gate a pasted key. Order matters and is part of the
    /// spec: signature before trusting any field, then version, then product,
    /// then revocation, then expiry. Fail closed at every branch.
    public func validate(_ key: String, now: Date = Date()) -> Result<License, LicenseError> {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".").map(String.init)
        guard parts.count == 3, parts[0] == Self.keyPrefix,
              let payload = Self.base64urlDecode(parts[1]),
              let signature = Self.base64urlDecode(parts[2]) else {
            return .failure(.malformed)
        }
        #if canImport(CryptoKit)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let probe = try? decoder.decode(Probe.self, from: payload),
              let kid = probe.kid else {
            return .failure(.malformed)   // includes the old v1 flat shape
        }
        guard let keyData = keys[kid] else {
            return .failure(.unknownKeyID)   // a retired keypair is dead
        }
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              pub.isValidSignature(signature, for: payload) else {
            return .failure(.badSignature)
        }
        // Signature is good — fields are now trustworthy.
        guard probe.v == 2 else {
            return .failure(.unsupportedVersion)
        }
        guard let license = try? decoder.decode(License.self, from: payload) else {
            return .failure(.malformed)   // any missing/undecodable required field
        }
        guard license.product == productID else {
            return .failure(.wrongProduct)
        }
        if denylist.contains(license.jti) {
            return .failure(.revoked(license.jti))
        }
        if now > license.expires {
            return .failure(.expired(license.expires))
        }
        return .success(license)
        #else
        return .failure(.unsupported)
        #endif
    }

    // MARK: - base64url (RFC 4648 §5, no padding — keys survive email/chat)

    static func base64urlDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }

    public static func base64urlEncode(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

#if canImport(CryptoKit)
/// Key MINTING — checks-and-generator only. The production private keys never
/// ship in any app build (they aren't in this repo at all); this helper exists
/// so the pro repo's generator and this repo's checks share one signer.
/// Signs the EXACT encoded bytes; the encoder settings are a mint-side
/// convenience, not a verify-side requirement (the verifier never re-encodes).
public enum LicenseSigner {
    public static func key(_ license: License, privateKey: Data) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]   // stable, diffable payloads
        let payload = try encoder.encode(license)
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        let sig = try priv.signature(for: payload)
        return [LicenseVerifier.keyPrefix,
                LicenseVerifier.base64urlEncode(payload),
                LicenseVerifier.base64urlEncode(sig)].joined(separator: ".")
    }
}
#endif
