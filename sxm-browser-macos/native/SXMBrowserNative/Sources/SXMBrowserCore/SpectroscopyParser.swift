import Foundation

public enum SpectroscopyParserError: LocalizedError, Sendable {
    case cannotRead(URL)
    case fileTooLarge(URL, byteCount: UInt64, maximumByteCount: UInt64)
    case missingData(URL)
    case missingColumns(URL)
    case insufficientValidRows(URL, validRowCount: Int, badLineCount: Int)

    public var errorDescription: String? {
        switch self {
        case .cannotRead(let url): "Cannot read spectroscopy file: \(url.lastPathComponent)"
        case .fileTooLarge(let url, let byteCount, let maximumByteCount):
            "Spectroscopy file is too large (\(byteCount) bytes; maximum \(maximumByteCount) bytes): \(url.lastPathComponent)"
        case .missingData(let url): "No [DATA] section found: \(url.lastPathComponent)"
        case .missingColumns(let url): "No plottable columns found: \(url.lastPathComponent)"
        case .insufficientValidRows(let url, let validRowCount, let badLineCount):
            "Only \(validRowCount) complete data row\(validRowCount == 1 ? "" : "s") found; at least 2 are required and \(badLineCount) malformed row\(badLineCount == 1 ? "" : "s") were ignored: \(url.lastPathComponent)"
        }
    }

    var badLineCount: Int? {
        switch self {
        case .insufficientValidRows(_, _, let badLineCount):
            badLineCount
        default:
            nil
        }
    }
}

public final class SpectroscopyParser: Sendable {
    public static let maximumFileByteCount: UInt64 = 64 * 1_024 * 1_024
    private static let headerSniffByteCount = 262_144
    private static let dataMarkerBytes = Data("[DATA]".utf8)

    public init() {}

    public func scanFolder(_ folder: URL) throws -> ScanReport<SpectroscopyFile> {
        try Task.checkCancellation()
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let spectroscopyURLs = urls
            .filter { $0.pathExtension.lowercased() == "dat" }
            .sorted(by: spectroscopyScanURLOrderedBefore)

        var output: [SpectroscopyFile] = []
        var issues: [ScanIssue] = []
        for url in spectroscopyURLs {
            try Task.checkCancellation()
            do {
                let parsed = try loadFileWithDiagnostics(url)
                output.append(parsed.file)
                if parsed.badLineCount > 0 {
                    issues.append(
                        ScanIssue(
                            file: url,
                            stage: .spectroscopyRows,
                            reason: "Ignored \(parsed.badLineCount) malformed data row\(parsed.badLineCount == 1 ? "" : "s").",
                            badLineCount: parsed.badLineCount
                        )
                    )
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                let badLineCount = (error as? SpectroscopyParserError)?.badLineCount
                issues.append(
                    ScanIssue(
                        file: url,
                        stage: .spectroscopyFile,
                        reason: error.localizedDescription,
                        badLineCount: badLineCount
                    )
                )
            }
        }
        return ScanReport(items: output, issues: issues)
    }

    public func loadFile(_ url: URL) throws -> SpectroscopyFile {
        try Task.checkCancellation()
        return try loadFileWithDiagnostics(url).file
    }

    private func loadFileWithDiagnostics(
        _ url: URL
    ) throws -> (file: SpectroscopyFile, badLineCount: Int) {
        try Task.checkCancellation()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SpectroscopyParserError.cannotRead(url)
        }
        defer { try? handle.close() }

        let byteCount = try handle.seekToEnd()
        guard byteCount <= Self.maximumFileByteCount else {
            throw SpectroscopyParserError.fileTooLarge(
                url,
                byteCount: byteCount,
                maximumByteCount: Self.maximumFileByteCount
            )
        }

        try handle.seek(toOffset: 0)
        let prefixLimit = min(Int(byteCount), Self.headerSniffByteCount)
        let prefix = try readUpTo(handle, count: prefixLimit)
        try Task.checkCancellation()

        let markerRange = prefix.range(of: Self.dataMarkerBytes)
        let nulSearchSlice = markerRange.map { prefix[..<$0.lowerBound] } ?? prefix[...]
        if nulSearchSlice.contains(0x00) {
            throw SpectroscopyParserError.missingData(url)
        }
        if byteCount > UInt64(Self.headerSniffByteCount), markerRange == nil {
            throw SpectroscopyParserError.missingData(url)
        }

        var data = prefix
        let totalBytes = Int(byteCount)
        if data.count < totalBytes {
            data.reserveCapacity(totalBytes)
            let chunkSize = 1_048_576
            while data.count < totalBytes {
                try Task.checkCancellation()
                let chunk = try readUpTo(handle, count: min(chunkSize, totalBytes - data.count))
                if chunk.isEmpty { break }
                data.append(chunk)
            }
        }

        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SpectroscopyParserError.cannotRead(url)
        }
        try Task.checkCancellation()
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
        var badLineCount = 0
        for (lineIndex, line) in dataLines.dropFirst().enumerated() {
            if lineIndex.isMultiple(of: 256) {
                try Task.checkCancellation()
            }
            let values = splitSpectroscopyLine(line)
            guard values.count == columns.count else {
                badLineCount += 1
                continue
            }
            var parsedValues: [Double] = []
            parsedValues.reserveCapacity(columns.count)
            var isCompleteRow = true
            for index in columns.indices {
                guard let value = parseEngineeringDouble(values[index]),
                      value.isFinite else {
                    isCompleteRow = false
                    break
                }
                parsedValues.append(value)
            }
            guard isCompleteRow else {
                badLineCount += 1
                continue
            }
            for (index, column) in columns.enumerated() {
                valuesByColumn[column, default: []].append(parsedValues[index])
            }
        }
        try Task.checkCancellation()
        let xs = valuesByColumn[columns[xIndex]] ?? []
        let ys = valuesByColumn[columns[yIndex]] ?? []
        guard xs.count >= 2, ys.count == xs.count else {
            throw SpectroscopyParserError.insufficientValidRows(
                url,
                validRowCount: min(xs.count, ys.count),
                badLineCount: badLineCount
            )
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

        return (
            SpectroscopyFile(
                path: url,
                filename: url.lastPathComponent,
                kind: kind,
                experiment: header["Experiment"] ?? kind.label,
                experimentIdentity:
                    SpectroscopyExperimentIdentity.make(
                        experiment: header["Experiment"],
                        fallbackKind: kind
                    ),
                modifiedTime: modifiedTime,
                savedTime: parseSpectroscopyDate(header["Saved Date"]),
                position: parsePosition(header),
                xLabel: xLabel,
                yLabel: yLabel,
                colorIndex: stableSpectrumColorIndex(for: url.lastPathComponent),
                curve: curve
            ),
            badLineCount
        )
    }
}

private func spectroscopyScanURLOrderedBefore(_ lhs: URL, _ rhs: URL) -> Bool {
    let filenameOrder = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
    if filenameOrder != .orderedSame {
        return filenameOrder == .orderedAscending
    }
    return lhs.standardizedFileURL.path.compare(
        rhs.standardizedFileURL.path,
        options: .literal
    ) == .orderedAscending
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
    // Reserve literal labels, including numbered labels appearing later in the header.
    let reserved = Set(columns)
    var nextSuffix: [String: Int] = [:]
    return columns.map { column in
        let name = column.isEmpty ? "Column" : column
        guard var suffix = nextSuffix[name] else {
            nextSuffix[name] = 2
            return name
        }

        var candidate: String
        repeat {
            candidate = "\(name) (\(suffix))"
            suffix += 1
        } while reserved.contains(candidate)
        nextSuffix[name] = suffix
        return candidate
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

private let spectroscopyDateParser = POSIXDateParser(formats: [
    "dd.MM.yyyy HH:mm:ss",
    "dd.MM.yy HH:mm:ss",
    "yyyy-MM-dd HH:mm:ss",
])

private func parseSpectroscopyDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return spectroscopyDateParser.date(from: trimmed)
}

private func readUpTo(_ handle: FileHandle, count: Int) throws -> Data {
    guard count > 0 else { return Data() }
    return try handle.read(upToCount: count) ?? Data()
}

public func parseEngineeringDouble(_ raw: String) -> Double? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.uppercased() != "N/A" else { return nil }
    let normalized = trimmed.replacingOccurrences(of: "E", with: "e")
    let multipliers: [(String, Double)] = [
        ("f", 1e-15), ("p", 1e-12), ("n", 1e-9), ("u", 1e-6), ("µ", 1e-6),
        ("m", 1e-3), ("k", 1e3), ("M", 1e6), ("G", 1e9)
    ]
    if let direct = Double(normalized) {
        return direct.isFinite ? direct : nil
    }
    for (suffix, multiplier) in multipliers {
        if normalized.hasSuffix(suffix) {
            let numberPart = normalized.dropLast(suffix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = Double(numberPart) {
                let scaled = value * multiplier
                return scaled.isFinite ? scaled : nil
            }
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
