import CryptoKit
import Foundation

public enum LicenseActivationError: Error, LocalizedError, Equatable, Sendable {
    case invalidFormat
    case invalidEncoding
    case invalidPayload
    case invalidSignature
    case unsupportedVersion

    public var errorDescription: String? {
        switch self {
        case .invalidFormat: return "The license key format is invalid."
        case .invalidEncoding: return "The license key contains invalid Base32."
        case .invalidPayload: return "The license details are invalid."
        case .invalidSignature: return "The license signature could not be verified."
        case .unsupportedVersion: return "This license version is unsupported."
        }
    }
}

public final class LicenseManager: ProEntitlementProviding {
    // Placeholder public key. Replace with PUBLIC_KEY_BASE64 from the owner's
    // scripts/generate_license.swift --keygen before issuing licenses.
    public static let defaultPublicKeyBase64: String = "9w6ejcTNXhUUu8Bpg8f1Lka9yzJjNPQIYRM+j4lthX4="

    private static let prefix = "WTPRO-"
    private static let signatureLength = 64
    private static let trialDuration: TimeInterval = 14 * 86_400
    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
    private static let lock = NSLock()

    private let publicKey: Curve25519.Signing.PublicKey
    private let defaults: UserDefaults
    private let trialStartedAtKey: String
    private let trialConsumedKey: String
    private let licenseKey: String
    private let nowProvider: () -> Date

    public init(
        publicKey: Curve25519.Signing.PublicKey = LicenseManager.loadDefaultPublicKey(),
        defaults: UserDefaults = .standard,
        keyPrefix: String = "WordTailPro",
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.publicKey = publicKey
        self.defaults = defaults
        self.trialStartedAtKey = "\(keyPrefix).TrialStartedAt"
        self.trialConsumedKey = "\(keyPrefix).TrialConsumed"
        self.licenseKey = "\(keyPrefix).LicenseKey"
        self.nowProvider = nowProvider
    }

    public static func loadDefaultPublicKey() -> Curve25519.Signing.PublicKey {
        guard let raw = Data(base64Encoded: defaultPublicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            preconditionFailure("WordTail's embedded license public key is invalid.")
        }
        return key
    }

    public var entitlementState: ProEntitlementState {
        let now = nowProvider()
        return Self.lock.withLock {
            if let license = verifiedStoredLicense() {
                return .licensed(license.payload)
            }
            guard let startedAt = defaults.object(forKey: trialStartedAtKey) as? Date,
                  now >= startedAt else {
                return .free
            }
            let expiresAt = startedAt.addingTimeInterval(Self.trialDuration)
            let remaining = expiresAt.timeIntervalSince(now)
            guard remaining > 0 else { return .free }
            return .trial(daysRemaining: Int(ceil(remaining / 86_400)), expiresAt: expiresAt)
        }
    }

    public var hasUsedTrial: Bool {
        Self.lock.withLock { trialWasConsumed }
    }

    public var activeLicenseKey: String? {
        Self.lock.withLock { verifiedStoredLicense()?.key }
    }

    @discardableResult
    public func startLocalTrial() -> Bool {
        let now = nowProvider()
        return Self.lock.withLock {
            guard !trialWasConsumed, verifiedStoredLicense() == nil else { return false }
            defaults.set(now, forKey: trialStartedAtKey)
            defaults.set(true, forKey: trialConsumedKey)
            return true
        }
    }

    @discardableResult
    public func activate(licenseKey: String) -> Result<ProLicensePayload, LicenseActivationError> {
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = verify(key)
        if case .success = result {
            Self.lock.withLock { defaults.set(key, forKey: self.licenseKey) }
        }
        return result
    }

    public func deactivateLicense() {
        Self.lock.withLock { defaults.removeObject(forKey: licenseKey) }
    }

    public static func sign(
        payload: ProLicensePayload,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payloadBytes = try encoder.encode(payload)
        guard let length = UInt16(exactly: payloadBytes.count) else {
            throw LicenseActivationError.invalidPayload
        }
        var packet = Data([UInt8(length >> 8), UInt8(truncatingIfNeeded: length)])
        packet.append(payloadBytes)
        packet.append(try privateKey.signature(for: payloadBytes))
        return prefix + encodeBase32(packet)
    }

    private var trialWasConsumed: Bool {
        defaults.bool(forKey: trialConsumedKey) || defaults.object(forKey: trialStartedAtKey) != nil
    }

    private func verifiedStoredLicense() -> (key: String, payload: ProLicensePayload)? {
        guard let key = defaults.string(forKey: licenseKey),
              case .success(let payload) = verify(key) else { return nil }
        return (key, payload)
    }

    private func verify(_ key: String) -> Result<ProLicensePayload, LicenseActivationError> {
        guard key.hasPrefix(Self.prefix) else { return .failure(.invalidFormat) }
        guard let packet = Self.decodeBase32(key.dropFirst(Self.prefix.count)) else {
            return .failure(.invalidEncoding)
        }
        guard packet.count > 2 + Self.signatureLength else { return .failure(.invalidFormat) }
        let length = (Int(packet[0]) << 8) | Int(packet[1])
        guard packet.count == 2 + length + Self.signatureLength else {
            return .failure(.invalidFormat)
        }
        let payloadBytes = packet[2..<(2 + length)]
        guard publicKey.isValidSignature(packet.suffix(Self.signatureLength), for: payloadBytes) else {
            return .failure(.invalidSignature)
        }
        guard let payload = try? JSONDecoder().decode(ProLicensePayload.self, from: payloadBytes) else {
            return .failure(.invalidPayload)
        }
        guard payload.version == 1 else { return .failure(.unsupportedVersion) }
        guard payload.tier == "pro", payload.plan == "lifetime",
              !payload.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.licenseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.invalidPayload)
        }
        return .success(payload)
    }

    private static func encodeBase32(_ packet: Data) -> String {
        var symbols: [UInt8] = []
        var buffer = 0
        var bits = 0
        for byte in packet {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                symbols.append(base32Alphabet[buffer >> bits])
                buffer &= (1 << bits) - 1
            }
        }
        if bits > 0 {
            symbols.append(base32Alphabet[buffer << (5 - bits)])
        }
        return stride(from: 0, to: symbols.count, by: 5).map { start in
            String(decoding: symbols[start..<min(start + 5, symbols.count)], as: UTF8.self)
        }.joined(separator: "-")
    }

    private static func decodeBase32(_ encoded: Substring) -> Data? {
        var packet = Data()
        var buffer = 0
        var bits = 0
        for character in encoded.unicodeScalars {
            if character == "-" || CharacterSet.whitespacesAndNewlines.contains(character) { continue }
            let value: Int
            switch character.value {
            case 65...90: value = Int(character.value - 65)
            case 50...55: value = Int(character.value - 50) + 26
            default: return nil
            }
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                packet.append(UInt8(buffer >> bits))
                buffer &= (1 << bits) - 1
                guard packet.count <= 2 + Int(UInt16.max) + signatureLength else { return nil }
            }
        }
        // Valid unpadded Base32 leaves at most four zero padding bits.
        return bits < 5 && buffer == 0 ? packet : nil
    }
}
