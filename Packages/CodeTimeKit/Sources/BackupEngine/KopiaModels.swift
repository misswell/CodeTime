import Foundation
import SharedModels

struct KopiaSnapshotJSON: Decodable {
    struct Source: Decodable {
        var host: String?
        var userName: String?
        var path: String
    }

    struct Stats: Decodable {
        var totalSize: Int64?
        var excludedTotalSize: Int64?
        var fileCount: Int?
        var dirCount: Int?
        var excludedFileCount: Int?
        var excludedDirCount: Int?
        var ignoredErrorCount: Int?
        var errorCount: Int?
    }

    var id: String
    var source: Source
    var description: String?
    var startTime: String?
    var endTime: String?
    var rootEntry: KopiaEntryJSON?
    var stats: Stats?
    var tags: [String: String]?
    var retentionReason: [String]?
}

struct KopiaEntryJSON: Decodable {
    struct Summary: Decodable {
        var size: Int64?
        var files: Int?
        var symlinks: Int?
        var dirs: Int?
        var maxTime: String?
        var numFailed: Int?
    }

    var name: String?
    var type: String?
    var mode: String?
    var size: Int64?
    var mtime: String?
    var uid: Int?
    var obj: String?
    var summ: Summary?
}

struct KopiaDirectoryJSON: Decodable {
    var stream: String?
    var entries: [KopiaEntryJSON]?
    var summary: KopiaEntryJSON.Summary?
}

struct KopiaVerifyJSON: Decodable {
    struct Stats: Decodable {
        var processedObjectCount: Int?
        var processedBytes: Int64?
        var readFileCount: Int?
        var readBytes: Int64?
        var expectedTotalObjectCount: Int?
        var expectedTotalFileCount: Int?
        var expectedTotalBytes: Int64?
    }

    var stats: Stats?
    var errorCount: Int?
}

struct KopiaStatusJSON: Decodable {
    var configFile: String?
    var uniqueIDHex: String?
    var storage: Storage?
    struct Storage: Decodable {
        var type: String?
    }
}

enum KopiaDateParser {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = fractional.date(from: string) { return date }
        if let date = plain.date(from: string) { return date }
        // Kopia emits nanosecond precision; ISO8601DateFormatter accepts at most 3 digits.
        if let dot = string.firstIndex(of: "."), let z = string.lastIndex(of: "Z") {
            let head = String(string[..<dot])
            let fraction = String(string[string.index(after: dot)..<z])
            let trimmed = String(fraction.prefix(3))
            return fractional.date(from: head + "." + trimmed + "Z")
        }
        return CodeTimeDateCoding.date(from: string)
    }
}

enum KopiaJSON {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let trimmed = data.drop(while: { $0 == 0x0A || $0 == 0x0D || $0 == 0x20 })
        guard !trimmed.isEmpty else {
            throw CodeTimeError.invalidOutput("空输出")
        }
        do {
            return try JSONDecoder().decode(type, from: Data(trimmed))
        } catch {
            let text = String(data: data, encoding: .utf8)?.prefix(400) ?? ""
            throw CodeTimeError.invalidOutput("\(error.localizedDescription): \(text)")
        }
    }

    static func decodeLastJSONLine<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let lines = String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") } ?? []
        guard let last = lines.last, let lineData = last.data(using: .utf8) else {
            throw CodeTimeError.invalidOutput("没有 JSON 输出")
        }
        return try decode(type, from: lineData)
    }
}
