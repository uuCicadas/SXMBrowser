import Foundation

public enum SpectroscopyParserError: LocalizedError {
    case cannotRead(URL)
    case missingData(URL)
    case missingColumns(URL)

    public var errorDescription: String? {
        switch self {
        case .cannotRead(let url): "Cannot read spectroscopy file: \(url.lastPathComponent)"
        case .missingData(let url): "No [DATA] section found: \(url.lastPathComponent)"
        case .missingColumns(let url): "No plottable columns found: \(url.lastPathComponent)"
        }
    }
}

public final class SpectroscopyParser: Sendable {
    public init() {}

    public func scanFolder(_ folder: URL) throws -> [SpectroscopyFile] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var output: [SpectroscopyFile] = []
        for url in urls where url.pathExtension.lowercased() == "dat" {
            do {
                output.append(try loadFile(url))
            } catch {
                continue
            }
        }
        return output.sorted { lhs, rhs in
            lhs.filename.localizedStandardCompare(rhs.filename) == .orderedAscending
        }
    }

    public func loadFile(_ url: URL) throws -> SpectroscopyFile {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SpectroscopyParserError.cannotRead(url)
        }
        guard let dataRange = text.range(of: "[DATA]") else {
            throw SpectroscopyParserError.missingData(url)
        }

        let headerText = String(text[..<dataRange.lowerBound])
        let dataText = String(text[dataRange.upperBound...])
        let header = parseSpectroscopyHeader(headerText)
        let dataLines = dataText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let columnLine = dataLines.first else {
            throw SpectroscopyParserError.missingColumns(url)
        }

        let columns = makeUniqueColumnNames(trimTrailingEmptyColumns(splitSpectroscopyLine(columnLine)))
        guard columns.count >= 2 else {
            throw SpectroscopyParserError.missingColumns(url)
        }

        let kind = spectroscopyKind(experiment: header["Experiment"], filename: url.lastPathComponent)
        let xIndex = 0
        let yIndex = preferredYColumn(for: kind, columns: columns)
        guard yIndex < columns.count else {
            throw SpectroscopyParserError.missingColumns(url)
        }

        var valuesByColumn = Dictionary(uniqueKeysWithValues: columns.map { ($0, [Double]()) })
        for line in dataLines.dropFirst() {
            let values = splitSpectroscopyLine(line)
            guard values.count >= columns.count else {
                continue
            }
            var parsedValues: [Double] = []
            parsedValues.reserveCapacity(columns.count)
            var isCompleteRow = true
            for index in columns.indices {
                guard let value = parseEngineeringDouble(values[index]) else {
                    isCompleteRow = false
                    break
                }
                parsedValues.append(value)
            }
            guard isCompleteRow else { continue }
            for (index, column) in columns.enumerated() {
                valuesByColumn[column, default: []].append(parsedValues[index])
            }
        }
        let xs = valuesByColumn[columns[xIndex]] ?? []
        let ys = valuesByColumn[columns[yIndex]] ?? []
        guard xs.count >= 2, ys.count == xs.count else {
            throw SpectroscopyParserError.missingColumns(url)
        }

        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedTime = resourceValues?.contentModificationDate ?? Date.distantPast
        let xLabel = columns[xIndex]
        let yLabel = columns[yIndex]
        let curve = SpectroscopyCurve(
            filename: url.lastPathComponent,
            modifiedTime: modifiedTime,
            columns: columns,
            valuesByColumn: valuesByColumn,
            x: xs,
            y: ys
        )

        return SpectroscopyFile(
            path: url,
            filename: url.lastPathComponent,
            kind: kind,
            experiment: header["Experiment"] ?? kind.label,
            modifiedTime: modifiedTime,
            savedTime: parseSpectroscopyDate(header["Saved Date"]),
            position: parsePosition(header),
            xLabel: xLabel,
            yLabel: yLabel,
            colorIndex: stableSpectrumColorIndex(for: url.lastPathComponent),
            curve: curve
        )
    }
}

private func parseSpectroscopyHeader(_ text: String) -> [String: String] {
    var header: [String: String] = [:]
    for rawLine in text.split(whereSeparator: \.isNewline).map(String.init) {
        let parts = splitSpectroscopyLine(rawLine)
        guard parts.count >= 2 else { continue }
        header[parts[0]] = parts[1]
    }
    return header
}

private func splitSpectroscopyLine(_ line: String) -> [String] {
    if line.contains("\t") {
        return line.split(separator: "\t", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    return line.split(whereSeparator: \.isWhitespace).map(String.init)
}

private func makeUniqueColumnNames(_ columns: [String]) -> [String] {
    var counts: [String: Int] = [:]
    return columns.map { column in
        let name = column.isEmpty ? "Column" : column
        let count = counts[name, default: 0]
        counts[name] = count + 1
        return count == 0 ? name : "\(name) (\(count + 1))"
    }
}

private func trimTrailingEmptyColumns(_ columns: [String]) -> [String] {
    var trimmed = columns
    while trimmed.last?.isEmpty == true {
        trimmed.removeLast()
    }
    return trimmed
}

private func spectroscopyKind(experiment: String?, filename: String) -> SpectroscopyKind {
    let folded = "\(experiment ?? "") \(filename)".lowercased()
    if folded.contains("bias") { return .bias }
    if folded.contains("z spectroscopy") || folded.hasPrefix("z-") || folded.contains("/z-") {
        return .z
    }
    return .other
}

private func preferredYColumn(for kind: SpectroscopyKind, columns: [String]) -> Int {
    let preferred: [String]
    switch kind {
    case .z:
        preferred = ["OC M1 Freq. Shift (Hz)", "Frequency Shift", "Current (A)"]
    case .bias:
        preferred = ["Current (A)", "OC M1 Freq. Shift (Hz)"]
    case .other:
        preferred = ["Current (A)", "OC M1 Freq. Shift (Hz)"]
    }

    for name in preferred {
        if let index = columns.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return index
        }
    }
    if let index = columns.firstIndex(where: { !$0.localizedCaseInsensitiveContains("[bwd]") && $0 != columns[0] }) {
        return index
    }
    return min(1, columns.count - 1)
}

private func parsePosition(_ header: [String: String]) -> (x: Double, y: Double)? {
    guard let x = parseEngineeringDouble(header["X (m)"] ?? ""),
          let y = parseEngineeringDouble(header["Y (m)"] ?? "") else {
        return nil
    }
    return (x, y)
}

private func parseSpectroscopyDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let formats = ["dd.MM.yyyy HH:mm:ss", "dd.MM.yy HH:mm:ss", "yyyy-MM-dd HH:mm:ss"]
    for format in formats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if let date = formatter.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return date
        }
    }
    return nil
}

private func parseEngineeringDouble(_ raw: String) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.uppercased() != "N/A" else { return nil }
    let normalized = trimmed.replacingOccurrences(of: "E", with: "e")
    let multipliers: [(String, Double)] = [
        ("f", 1e-15), ("p", 1e-12), ("n", 1e-9), ("u", 1e-6), ("µ", 1e-6),
        ("m", 1e-3), ("k", 1e3), ("M", 1e6), ("G", 1e9)
    ]
    if let direct = Double(normalized) {
        return direct
    }
    for (suffix, multiplier) in multipliers {
        if normalized.hasSuffix(suffix), let value = Double(normalized.dropLast(suffix.count)) {
            return value * multiplier
        }
    }
    return nil
}

private func stableSpectrumColorIndex(for filename: String) -> Int {
    let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
    var digits = ""
    var hasStartedDigits = false
    for character in base.reversed() {
        if character.isNumber {
            digits.insert(character, at: digits.startIndex)
            hasStartedDigits = true
        } else if hasStartedDigits {
            break
        }
    }
    if let value = Int(digits), value > 0 {
        return value - 1
    }
    var hash: UInt32 = 2166136261
    for byte in base.utf8 {
        hash ^= UInt32(byte)
        hash &*= 16777619
    }
    return Int(hash % 8)
}
