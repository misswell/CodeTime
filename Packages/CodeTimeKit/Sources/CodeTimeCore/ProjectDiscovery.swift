import Foundation

/// CT-146: which home subfolders the first-run wizard may probe for git repos.
///
/// macOS gates `~/Documents`, `~/Desktop` and `~/Downloads` behind TCC. Probing
/// them the moment the wizard opens raises a system privacy prompt the user
/// never asked for — the spec (§3.2) explicitly forbids reading other
/// directories without authorization, and a modal prompt on step 2 also blocks
/// the flow. Only unprotected developer folders are scanned automatically;
/// anything else must come from an explicit NSOpenPanel selection, which grants
/// access to the chosen directory alone.
public enum ProjectDiscovery {
    /// Home subfolders that are safe to scan without a privacy prompt.
    public static let candidateFolders = ["Developer", "Code", "Projects", "src", "work", "dev", "git", "workspace"]

    /// Folders that must never be scanned automatically (TCC-protected or
    /// otherwise not ours to read).
    public static let systemProtectedFolders = ["Documents", "Desktop", "Downloads"]

    public static func isAutoScannable(_ folderName: String) -> Bool {
        !systemProtectedFolders.contains {
            $0.compare(folderName, options: .caseInsensitive) == .orderedSame
        }
    }

    /// The candidates actually usable on this machine, already filtered.
    public static var effectiveCandidates: [String] {
        candidateFolders.filter(isAutoScannable)
    }
}
