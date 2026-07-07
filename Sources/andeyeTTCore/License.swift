import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Paid tiers. Community is the absence of a licence, not a tier — the app is
/// fully functional without one; a licence only ADDS (pro backends etc.).
public enum LicenseTier: String, Codable, Sendable, CaseIterable {
    case plus, pro, premium, enterprise

    /// Whether this tier unlocks the paid backend plugins (Xero, ...).
    public var unlocksProBackends: Bool {
        switch self {
        case .plus: return false
        case .pro, .premium, .enterprise: return true
        }
    }
}

/// The signed payload inside a licence key. Deliberately small and flat; new
/// optional fields decode leniently so old keys survive new builds.
public struct License: Codable, Equatable, Sendable {
    public var tier: LicenseTier
    /// Who it was issued to (shown in Settings; part of the signed payload so
    /// keys aren't anonymous pastebin currency).
    public var licensee: String
    public var issued: Date
    /// nil = perpetual. Subscription-style keys carry an expiry; validation
    /// compares against `now`.
    public var expires: Date?

    public init(tier: LicenseTier, licensee: String, issued: Date, expires: Date? = nil) {
        self.tier = tier
        self.licensee = licensee
        self.issued = issued
        self.expires = expires
    }
}

public enum LicenseError: Error, Equatable {
    case malformed          // not ANDEYE1.<payload>.<signature>
    case badSignature       // cryptographic verification failed
    case expired(Date)      // valid key, but past its expiry
    case unsupported        // platform without CryptoKit (Linux CI) — never valid
}

/// Offline verification of `ANDEYE1.<base64url payload>.<base64url sig>` keys
/// (dot-separated, JWT-style — "-" and "_" belong to base64url itself).
/// Ed25519 over the exact payload bytes; the private key lives ONLY in the
/// pro repo's generator (and Martin's password manager) — this side can
/// verify but never mint. Verification is pure and offline: no phone-home,
/// works forever, works air-gapped.
public struct LicenseVerifier: Sendable {
    /// Raw 32-byte Ed25519 public key.
    public let publicKey: Data

    public init(publicKey: Data) {
        self.publicKey = publicKey
    }

    /// The production signing identity — ROTATED 2026-07-02 (Martin minted
    /// the pair himself; private key lives only in Apple Passwords). The
    /// first pair was retired unused after transiting a plaintext file.
    public static let production = LicenseVerifier(
        publicKey: Data(base64Encoded: "hGcCOyMchBHEdj3xgNJJplJQwv1oK+Gseju7ZaCnf1w=")!)

    public static let keyPrefix = "ANDEYE1"   // AMBI1 → ANDE1 → ANDEYE1 (2026-07-07, lockstep with the pro generator's make-license.swift); still BEFORE any real key was issued, so no dual-accept needed

    /// Verify + decode + expiry-check a pasted key.
    public func validate(_ key: String, now: Date = Date()) -> Result<License, LicenseError> {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".").map(String.init)
        guard parts.count == 3, parts[0] == Self.keyPrefix,
              let payload = Self.base64urlDecode(parts[1]),
              let signature = Self.base64urlDecode(parts[2]) else {
            return .failure(.malformed)
        }
        #if canImport(CryptoKit)
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey),
              pub.isValidSignature(signature, for: payload) else {
            return .failure(.badSignature)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let license = try? decoder.decode(License.self, from: payload) else {
            return .failure(.malformed)
        }
        if let expires = license.expires, now > expires {
            return .failure(.expired(expires))
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
/// Key MINTING — checks-and-generator only. The production private key never
/// ships in any app build (it isn't in this repo at all); this helper exists
/// so the pro repo's generator and this repo's checks share one signer.
public enum LicenseSigner {
    public static func key(_ license: License, privateKey: Data) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]   // canonical payload bytes
        let payload = try encoder.encode(license)
        let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        let sig = try priv.signature(for: payload)
        return [LicenseVerifier.keyPrefix,
                LicenseVerifier.base64urlEncode(payload),
                LicenseVerifier.base64urlEncode(sig)].joined(separator: ".")
    }
}
#endif
