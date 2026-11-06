import Foundation

struct DiffLine: Identifiable {
    enum Kind {
        case context
        case added
        case removed
    }

    let id = UUID()
    var number: Int
    var text: String
    var kind: Kind
}

struct DiffRow: Identifiable {
    let id = UUID()
    var left: DiffLine?
    var right: DiffLine?

    var kind: DiffLine.Kind {
        if left?.kind == .removed { return .removed }
        if right?.kind == .added { return .added }
        return .context
    }
}

enum LineDiff {
    static func rows(from oldText: String, to newText: String) -> [DiffRow] {
        let oldLines = split(oldText)
        let newLines = split(newText)
        let n = oldLines.count
        let m = newLines.count
        if n == 0 && m == 0 { return [] }
        if n == 0 {
            return newLines.enumerated().map { index, line in
                DiffRow(left: nil, right: DiffLine(number: index + 1, text: line, kind: .added))
            }
        }
        if m == 0 {
            return oldLines.enumerated().map { index, line in
                DiffRow(left: DiffLine(number: index + 1, text: line, kind: .removed), right: nil)
            }
        }

        var matrix = [Int](repeating: 0, count: (n + 1) * (m + 1))
        func index(_ i: Int, _ j: Int) -> Int { i * (m + 1) + j }
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    if oldLines[i] == newLines[j] {
                        matrix[index(i, j)] = matrix[index(i + 1, j + 1)] + 1
                    } else {
                        matrix[index(i, j)] = max(matrix[index(i + 1, j)], matrix[index(i, j + 1)])
                    }
                }
            }
        }

        var rows: [DiffRow] = []
        var i = 0
        var j = 0
        while i < n && j < m {
            if oldLines[i] == newLines[j] {
                rows.append(DiffRow(
                    left: DiffLine(number: i + 1, text: oldLines[i], kind: .context),
                    right: DiffLine(number: j + 1, text: newLines[j], kind: .context)
                ))
                i += 1
                j += 1
            } else if matrix[index(i + 1, j)] >= matrix[index(i, j + 1)] {
                rows.append(DiffRow(
                    left: DiffLine(number: i + 1, text: oldLines[i], kind: .removed),
                    right: nil
                ))
                i += 1
            } else {
                rows.append(DiffRow(
                    left: nil,
                    right: DiffLine(number: j + 1, text: newLines[j], kind: .added)
                ))
                j += 1
            }
        }
        while i < n {
            rows.append(DiffRow(left: DiffLine(number: i + 1, text: oldLines[i], kind: .removed), right: nil))
            i += 1
        }
        while j < m {
            rows.append(DiffRow(left: nil, right: DiffLine(number: j + 1, text: newLines[j], kind: .added)))
            j += 1
        }
        return rows
    }

    private static func split(_ text: String) -> [String] {
        if text.isEmpty { return [] }
        return text.components(separatedBy: "\n")
    }
}
