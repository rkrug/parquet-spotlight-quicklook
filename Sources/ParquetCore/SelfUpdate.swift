import CryptoKit
import Foundation

// In-app update: the app downloads the release ZIP and its Ed25519 signature, verifies the
// signature against the public key in its Info.plist, and swaps itself via a helper shell
// that runs after the app quits. Releases are only ad-hoc signed and downloads made by the
// app are not quarantined, so this signature is what proves an update comes from us.
public enum ParquetSelfUpdate {
    public static let publicKeyInfoKey = "ParquetUpdatePublicKey"

    // Asset names attached to each release by .github/workflows/release.yml.
    public static func zipAssetName(version: String) -> String {
        "Parquet-Spotlight-\(version).zip"
    }

    public static func signatureAssetName(version: String) -> String {
        zipAssetName(version: version) + ".sig"
    }

    // `signatureBase64` and `publicKeyBase64` are raw Ed25519 values, base64-encoded
    // (as written by scripts/sign_update.swift).
    public static func isValidSignature(_ signatureBase64: String, for data: Data, publicKeyBase64: String) -> Bool {
        guard
            let keyData = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
            let signature = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else {
            return false
        }
        return key.isValidSignature(signature, for: data)
    }

    public static let shellPath = "/bin/sh"

    // Waits for the app ($1 = pid) to quit, moves the installed app ($2) aside to $4, moves the
    // new app ($3) into its place, and relaunches when $5 is 1. If either move fails, the old
    // app stays (or is put back) and is relaunched. Paths are positional parameters, never
    // parsed as shell syntax.
    public static let swapScript = """
    ( while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
      if ! mv -- "$2" "$4"; then
        if [ "$5" = 1 ]; then open "$2"; fi
        exit 1
      fi
      if mv -- "$3" "$2"; then
        if [ "$5" = 1 ]; then open "$2"; fi
      else
        mv -- "$4" "$2"
        if [ "$5" = 1 ]; then open "$2"; fi
      fi ) >/dev/null 2>&1 &
    """

    public static func shellArguments(
        waitingForPID pid: Int32,
        installedAppPath: String,
        newAppPath: String,
        trashPath: String,
        relaunch: Bool
    ) -> [String] {
        ["-c", swapScript, "sh", String(pid), installedAppPath, newAppPath, trashPath, relaunch ? "1" : "0"]
    }
}
