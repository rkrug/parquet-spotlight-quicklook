// Ed25519 signing for in-app updates (verified by ParquetSelfUpdate in the app).
//
//   swift scripts/sign_update.swift keygen
//       Prints a new private key (keep secret; GitHub secret PARQUET_UPDATE_SIGNING_KEY) and
//       its public key (ParquetUpdatePublicKey in preview/app/Info.plist), both base64.
//   PARQUET_UPDATE_SIGNING_KEY=<base64> swift scripts/sign_update.swift sign <file>
//       Writes <file>.sig (base64 signature over the file's bytes).
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    print("private: \(key.rawRepresentation.base64EncodedString())")
    print("public:  \(key.publicKey.rawRepresentation.base64EncodedString())")
case "sign":
    guard args.count == 2, let path = args.last else { fail("usage: sign <file>") }
    guard
        let encoded = ProcessInfo.processInfo.environment["PARQUET_UPDATE_SIGNING_KEY"],
        let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    else { fail("PARQUET_UPDATE_SIGNING_KEY is missing or not a base64 Ed25519 private key") }
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    guard let signature = try? key.signature(for: data) else { fail("signing failed") }
    do {
        try (signature.base64EncodedString() + "\n").write(toFile: path + ".sig", atomically: true, encoding: .utf8)
    } catch {
        fail("cannot write \(path).sig: \(error.localizedDescription)")
    }
    print("signed: \(path).sig (public key \(key.publicKey.rawRepresentation.base64EncodedString()))")
default:
    fail("usage: sign_update.swift keygen | sign <file>")
}
