import Foundation
import SharedModels

/// Pre-flight checks before a directory may become a backup source.
///
/// Two failure modes matter most: choosing a directory that contains another
/// project (Kopia would snapshot the same tree twice under two roots) and choosing
/// a directory inside CodeTime's own data or cloud mirror, where every backup would
/// then include the previous backup. Path comparison uses resolved real paths and
/// path components, never `hasPrefix`, so `/a/b` does not match `/a/bc`.
public enum ProjectPathValidator {
    public struct Result: Sendable {
        public var resolvedURL: URL
        public var issues: [PathValidationIssue]

        public var isAcceptable: Bool { issues.isEmpty }
    }

    public static func validate(
        url: URL,
        existingProjects: [Project],
        appRoot: URL,
        mirrorPath: String?,
        iCloudMirrorPath: String? = nil
    ) -> Result {
        let fileManager = FileManager.default
        var issues: [PathValidationIssue] = []

        let resolved = url
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            issues.append(PathValidationIssue(
                path: resolved.path,
                reason: "目录不存在或不是文件夹",
                suggestion: "选择一个已存在的项目根目录"
            ))
            return Result(resolvedURL: resolved, issues: issues)
        }

        if !fileManager.isReadableFile(atPath: resolved.path) {
            issues.append(PathValidationIssue(
                path: resolved.path,
                reason: "当前账户无法读取该目录",
                suggestion: "在 Finder 中确认权限，或更换为可读取的目录"
            ))
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let forbidden: Set<String> = [
            "/", "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin",
            "/etc", "/var", "/private", "/Volumes", "/dev", "/cores",
        ]
        if forbidden.contains(resolved.path) || resolved.path == home.path {
            issues.append(PathValidationIssue(
                path: resolved.path,
                reason: "系统目录或个人主目录本身不能作为备份项目",
                suggestion: "请选择具体的项目文件夹，例如 ~/Code/my-app"
            ))
        }

        var protectedRoots: [(URL, String)] = [
            (appRoot, "CodeTime 数据目录"),
            (appRoot.appendingPathComponent("repositories", isDirectory: true), "CodeTime 备份仓库"),
            (appRoot.appendingPathComponent("recovery", isDirectory: true), "CodeTime 保护副本目录"),
        ]
        if let mirrorPath, !mirrorPath.isEmpty {
            protectedRoots.append((URL(fileURLWithPath: mirrorPath, isDirectory: true), "本地镜像目录"))
        }
        if let iCloudMirrorPath, !iCloudMirrorPath.isEmpty {
            protectedRoots.append((URL(fileURLWithPath: iCloudMirrorPath, isDirectory: true), "iCloud 镜像目录"))
        }
        for (root, label) in protectedRoots {
            let realRoot = root
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            if isSameOrDescendant(resolved, of: realRoot) || isSameOrDescendant(realRoot, of: resolved) {
                issues.append(PathValidationIssue(
                    path: resolved.path,
                    reason: "该目录与\(label)重叠，会造成递归备份",
                    suggestion: "选择 \(label) 之外的目录"
                ))
            }
        }

        for project in existingProjects where project.lifecycle == .active {
            let other = URL(fileURLWithPath: project.rootPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            if resolved.path == other.path {
                issues.append(PathValidationIssue(
                    path: resolved.path,
                    reason: "该目录已在备份列表中（\(project.name)）",
                    suggestion: "无需重复添加"
                ))
            } else if isSameOrDescendant(resolved, of: other) {
                issues.append(PathValidationIssue(
                    path: resolved.path,
                    reason: "该目录位于项目「\(project.name)」内部，会被递归备份",
                    suggestion: "选择项目根目录之外的目录"
                ))
            } else if isSameOrDescendant(other, of: resolved) {
                issues.append(PathValidationIssue(
                    path: resolved.path,
                    reason: "项目「\(project.name)」位于该目录内部，两个项目会重叠",
                    suggestion: "选择更精确的项目根目录"
                ))
            }
        }

        return Result(resolvedURL: resolved, issues: issues)
    }

    /// True when `candidate` equals `root` or lives below it. Component-wise
    /// comparison prevents `/Users/a/CodeTime2` from matching `/Users/a/CodeTime`.
    public static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
