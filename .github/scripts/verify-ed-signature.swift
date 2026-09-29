// Verifies a Sparkle EdDSA (Ed25519) signature against the app's SUPublicEDKey, without the Keychain.
// Usage: swift verify-ed-signature.swift <public-key-base64> <signature-base64> <file>

import CryptoKit
import Foundation

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("verify-ed-signature: \(message)\n".utf8))
    exit(code)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("usage: verify-ed-signature.swift <public-key-base64> <signature-base64> <file>", code: 64)
}
guard let publicKeyData = Data(base64Encoded: arguments[1]),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
    fail("public key is not a base64 Ed25519 key", code: 64)
}
guard let signature = Data(base64Encoded: arguments[2]) else {
    fail("signature is not base64", code: 64)
}
guard let archive = try? Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .alwaysMapped) else {
    fail("cannot read \(arguments[3])", code: 66)
}
guard publicKey.isValidSignature(signature, for: archive) else {
    fail("signature does not match the public key", code: 1)
}
print("verify-ed-signature: signature matches")
