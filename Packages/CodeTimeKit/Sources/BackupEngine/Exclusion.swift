import Foundation
import SharedModels

public struct ExclusionMatch: Hashable, Sendable {
    public var pattern: String
    public var note: String?
    public var isNegated: Bool

    public init(pattern: String, note: String? = nil, isNegated: Bool = false) {
        self.pattern = pattern
        self.note = note
        self.isNegated = isNegated
    }
}

public enum ExclusionPresets {
    public static func load() -> [ExclusionPreset] {
        guard let url = Bundle.module.url(
            forResource: "default-presets",
            withExtension: "json",
            subdirectory: "ExclusionPresets"
        ), let data = try? Data(contentsOf: url),
           let presets = try? JSONDecoder().decode([ExclusionPreset].self, from: data) else {
            return fallback
        }
        return presets
    }

    public static func defaultRules(enabledPresetIDs: Set<String>? = nil) -> [ExclusionRule] {
        load()
            .filter { enabledPresetIDs == nil || enabledPresetIDs!.contains($0.id) }
            .flatMap(\.exclusionRules)
    }

    public static func ruleSet(for presetIDs: Set<String>) -> [ExclusionRule] {
        load().filter { presetIDs.contains($0.id) }.flatMap(\.exclusionRules)
    }

    private static let fallback: [ExclusionPreset] = [
        ExclusionPreset(id: "node", name: "Node.js", summary: "依赖与构建产物", rules: ["node_modules/", "dist/", "build/", "*.log"]),
        ExclusionPreset(id: "java", name: "Java", summary: "构建输出", rules: ["target/", ".gradle/", "*.class"]),
        ExclusionPreset(id: "python", name: "Python", summary: "虚拟环境", rules: [".venv/", "__pycache__/", "*.pyc"]),
        ExclusionPreset(id: "swift", name: "Swift", summary: "Xcode 构建目录", rules: ["DerivedData/", ".build/"]),
        ExclusionPreset(id: "common", name: "通用", summary: "系统与日志文件", rules: ["*.log", ".DS_Store", "*.tmp"]),
    ]
}

public enum KopiaIgnore {
    /// Reads project-level `.kopiaignore` so previews match what Kopia will skip.
    /// Kopia still reads the file itself; CodeTime only mirrors the patterns.
    public static func rules(at root: URL) -> [ExclusionRule] {
        let url = root.appendingPathComponent(".kopiaignore")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return ExclusionRule(pattern: trimmed, preset: "kopiaignore", note: "来自 .kopiaignore")
        }
    }
}

public struct ExclusionMatcher: Sendable {
    public static let protectedFileNames: Set<String> = [
        "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "pom.xml", "build.gradle",
        "build.gradle.kts", "settings.gradle", "settings.gradle.kts", "Package.swift",
        "Package.resolved", "Podfile", "Podfile.lock", "Cargo.lock", "go.mod", "go.sum",
        "requirements.txt", "pyproject.toml", "Gemfile", "Gemfile.lock", ".gitignore",
        ".gitattributes", ".kopiaignore", "LICENSE", "NOTICE",
    ]

    public struct CompiledRule: @unchecked Sendable {
        public var rule: ExclusionRule
        public var regex: NSRegularExpression?
        public var anchored: Bool
    }

    public let compiled: [CompiledRule]
    public let includeEnvFiles: Bool
    public let includeGitDirectory: Bool

    public init(
        rules: [ExclusionRule],
        includeEnvFiles: Bool = false,
        includeGitDirectory: Bool = true
    ) {
        self.includeEnvFiles = includeEnvFiles
        self.includeGitDirectory = includeGitDirectory

        var all = rules
        if !includeGitDirectory {
            all.append(ExclusionRule(pattern: ".git/", preset: "__git", note: "已关闭 .git 备份"))
        }
        if !includeEnvFiles {
            // Kopia 的忽略规则不支持 "!" 取反，因此这里只列出确定的敏感文件名，
            // 保留 .env.example / .env.sample / .env.template。
            for pattern in [".env", ".env.local", ".env.development", ".env.production",
                            ".env.staging", ".env.test", ".env.*.local"] {
                all.append(ExclusionRule(pattern: pattern, preset: "__security", note: "敏感配置文件默认不备份"))
            }
        }

        self.compiled = all.filter(\.isEnabled).map { rule in
            var pattern = rule.normalizedPattern
            let anchored = pattern.contains("/") || rule.pattern.hasPrefix("/")
            let hadLeadingSlash = pattern.hasPrefix("/")
            if hadLeadingSlash { pattern.removeFirst() }
            let regex = Self.makeRegex(pattern: pattern, anchored: anchored)
            return CompiledRule(
                rule: ExclusionRule(
                    id: rule.id,
                    pattern: (hadLeadingSlash ? "/" : "") + pattern + (rule.isDirectoryOnly ? "/" : ""),
                    isEnabled: true,
                    preset: rule.preset,
                    note: rule.note
                ),
                regex: regex,
                anchored: anchored
            )
        }
    }

    public init(
        patterns: [String],
        includeEnvFiles: Bool = false,
        includeGitDirectory: Bool = true
    ) {
        self.init(
            rules: patterns.map { ExclusionRule(pattern: $0) },
            includeEnvFiles: includeEnvFiles,
            includeGitDirectory: includeGitDirectory
        )
    }

    public func match(relativePath: String, isDirectory: Bool) -> ExclusionMatch? {
        var path = relativePath
        while path.hasPrefix("./") { path.removeFirst(2) }
        while path.hasPrefix("/") { path.removeFirst() }
        guard !path.isEmpty else { return nil }

        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty else { return nil }

        if includeGitDirectory, components.contains(".git") {
            return nil
        }

        var prefixes: [String] = []
        var running: [String] = []
        for (index, component) in components.enumerated() {
            running.append(component)
            let isLast = index == components.count - 1
            if isLast && !isDirectory { continue }
            prefixes.append(running.joined(separator: "/"))
        }

        let basename = components.last ?? path
        var decision: ExclusionMatch? = nil

        for compiledRule in compiled {
            let isDirectoryRule = compiledRule.rule.isDirectoryOnly
            var matched = false

            if isDirectoryRule {
                matched = prefixes.contains { prefix in
                    guard let regex = compiledRule.regex else { return false }
                    return regex.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) != nil
                }
            } else if let regex = compiledRule.regex {
                matched = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
                if !matched, !compiledRule.anchored {
                    matched = regex.firstMatch(in: basename, range: NSRange(basename.startIndex..., in: basename)) != nil
                }
            }

            guard matched else { continue }

            if compiledRule.rule.preset != nil,
               Self.protectedFileNames.contains(basename) {
                continue
            }

            decision = ExclusionMatch(pattern: compiledRule.rule.pattern, note: compiledRule.rule.note)
        }
        return decision
    }

    public func isExcluded(relativePath: String, isDirectory: Bool) -> Bool {
        guard let match = match(relativePath: relativePath, isDirectory: isDirectory) else { return false }
        return !match.isNegated
    }

    private static func makeRegex(pattern: String, anchored: Bool) -> NSRegularExpression? {
        var body = ""
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    while index < characters.count, characters[index] == "*" { index += 1 }
                    if index < characters.count, characters[index] == "/" {
                        body += "(?:.*/)?"
                        index += 1
                    } else {
                        body += ".*"
                    }
                    continue
                } else {
                    body += "[^/]*"
                }
            case "?":
                body += "[^/]"
            case "[":
                var cls = "["
                index += 1
                if index < characters.count, characters[index] == "!" {
                    cls += "^"
                    index += 1
                }
                while index < characters.count, characters[index] != "]" {
                    cls.append(characters[index])
                    index += 1
                }
                cls += "]"
                body += cls
            default:
                body += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        let prefix = anchored ? "^" : "^(?:.*/)?"
        let expression = prefix + body + "$"
        return try? NSRegularExpression(pattern: expression, options: [.caseInsensitive])
    }
}

public enum ExclusionScanner {
    public static func preview(
        root: URL,
        matcher: ExclusionMatcher,
        maxFiles: Int = 500_000,
        sampleLimit: Int = 40
    ) -> ExclusionPreview {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .nameKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return ExclusionPreview()
        }

        let rootPath = root.standardizedFileURL.path
        var result = ExclusionPreview()
        var filesSeen = 0
        var samples: [ExcludedSample] = []

        while let object = enumerator.nextObject() {
            if filesSeen >= maxFiles { break }
            guard let url = object as? URL else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory ?? false
            let isSymlink = values?.isSymbolicLink ?? false
            let size = Int64(values?.fileSize ?? 0)

            var path = url.standardizedFileURL.path
            if path.hasPrefix(rootPath) {
                path = String(path.dropFirst(rootPath.count))
                if path.hasPrefix("/") { path.removeFirst() }
            }
            let relative = path

            if let match = matcher.match(relativePath: relative, isDirectory: isDirectory), !match.isNegated {
                if isDirectory {
                    enumerator.skipDescendants()
                } else {
                    result.excludedFiles += 1
                    result.excludedBytes += size
                    if samples.count < sampleLimit {
                        samples.append(ExcludedSample(path: relative, pattern: match.pattern, size: size))
                    }
                }
                continue
            }

            if isDirectory {
                continue
            }
            filesSeen += 1
            result.includedFiles += 1
            result.includedBytes += size
            if isSymlink { continue }
        }

        result.samples = samples
        return result
    }
}
