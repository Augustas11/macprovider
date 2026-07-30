import CryptoKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fputs("usage: verify-ed25519-signature.swift PUBLIC_KEY_B64 SIGNATURE_B64 FILE\n", stderr)
    exit(2)
}

guard let publicKey = Data(base64Encoded: CommandLine.arguments[1]),
      publicKey.count == 32,
      let signature = Data(base64Encoded: CommandLine.arguments[2]),
      signature.count == 64 else {
    fputs("invalid Ed25519 public key or signature encoding\n", stderr)
    exit(2)
}

do {
    let payload = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]))
    let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    exit(verifier.isValidSignature(signature, for: payload) ? 0 : 1)
} catch {
    fputs("Ed25519 verification failed: \(error)\n", stderr)
    exit(2)
}
