#!/usr/bin/env swift

import CryptoKit
import Foundation

// Keep the payload schema and packet encoding in sync with WordTailCore.
private struct ProLicensePayload: Encodable {
    let version = 1
    let tier = "pro"
    let plan: String
    let email: String
    let issuedAt = Int64(Date().timeIntervalSince1970)
    let licenseID = UUID().uuidString.lowercased()
}

private func groupedBase32(_ packet: Data) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
    var symbols: [UInt8] = []
    var buffer = 0
    var bits = 0
    for byte in packet {
        buffer = (buffer << 8) | Int(byte)
        bits += 8
        while bits >= 5 {
            bits -= 5
            symbols.append(alphabet[buffer >> bits])
            buffer &= (1 << bits) - 1
        }
    }
    if bits > 0 {
        symbols.append(alphabet[buffer << (5 - bits)])
    }
    return stride(from: 0, to: symbols.count, by: 5).map { start in
        String(decoding: symbols[start..<min(start + 5, symbols.count)], as: UTF8.self)
    }.joined(separator: "-")
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--keygen"] {
    let privateKey = Curve25519.Signing.PrivateKey()
    print("PUBLIC_KEY_BASE64=\(privateKey.publicKey.rawRepresentation.base64EncodedString())")
    print("PRIVATE_KEY_BASE64=\(privateKey.rawRepresentation.base64EncodedString())")
    print("""
    Keep PRIVATE_KEY_BASE64 strictly private. Store it offline in Keychain or supply it
    only to a trusted Creem or 面包多 webhook as WORDTAIL_LICENSE_PRIVATE_KEY.
    Paste PUBLIC_KEY_BASE64 into LicenseManager.defaultPublicKeyBase64.
    """)
} else {
    let usage = "Usage: generate_license.swift --keygen | --sign --email <email> [--plan lifetime]"
    guard arguments.count == 3 || arguments.count == 5,
          arguments[0] == "--sign", arguments[1] == "--email",
          arguments.count == 3 || arguments[3] == "--plan" else {
        fail(usage)
    }
    let email = arguments[2].trimmingCharacters(in: .whitespacesAndNewlines)
    let emailParts = email.split(separator: "@", omittingEmptySubsequences: false)
    guard emailParts.count == 2, emailParts.allSatisfy({ !$0.isEmpty }),
          !email.contains(where: \.isWhitespace) else {
        fail("Supply a valid email address.")
    }
    let plan = arguments.count == 5 ? arguments[4] : "lifetime"
    guard plan == "lifetime" else { fail("Supported plan: lifetime") }
    guard let base64 = ProcessInfo.processInfo.environment["WORDTAIL_LICENSE_PRIVATE_KEY"],
          let raw = Data(base64Encoded: base64),
          let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("WORDTAIL_LICENSE_PRIVATE_KEY must contain a Base64-encoded raw Ed25519 private key.")
    }

    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let payload = try encoder.encode(ProLicensePayload(plan: plan, email: email))
        guard let length = UInt16(exactly: payload.count) else { fail("The license payload is too large.") }
        var packet = Data([UInt8(length >> 8), UInt8(truncatingIfNeeded: length)])
        packet.append(payload)
        packet.append(try privateKey.signature(for: payload))
        print("WTPRO-" + groupedBase32(packet))
    } catch {
        fail("Could not sign the license: \(error.localizedDescription)")
    }
}
