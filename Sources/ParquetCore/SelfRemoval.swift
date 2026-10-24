import Foundation

public enum ParquetSelfRemoval {
    public static let shellPath = "/bin/sh"

    // The bundle path is handed to the shell as a positional parameter so it is never
    // parsed as shell syntax, whatever characters the install location contains.
    public static func shellArguments(forRemovingBundleAt path: String) -> [String] {
        ["-c", "(sleep 1; rm -rf -- \"$1\") >/dev/null 2>&1 &", "sh", path]
    }
}
