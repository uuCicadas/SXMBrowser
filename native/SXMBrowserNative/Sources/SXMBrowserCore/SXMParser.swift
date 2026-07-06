import Foundation

public enum SXMParserError: LocalizedError {
    case markerNotFound(URL)
    case missingPixels(URL)
    case missingChannels(URL)
    case cannotOpen(URL)
    case shortData(URL)

    public var errorDescription: String? {
        switch self {
        case .markerNotFound(let url): "SXM data marker not found: \(url.lastPathComponent)"
        case .missingPixels(let url): "SCAN_PIXELS not found: \(url.lastPathComponent)"
        case .missingChannels(let url): "DATA_INFO has no channels: \(url.lastPathComponent)"
        case .cannotOpen(let url): "Cannot open file: \(url.path)"
        case .shortData(let url): "File ended before all matrices were read: \(url.lastPathComponent)"
        }
    }
}

private let dataMarker = Data([0x1a, 0x04])

struct ChannelSpec: Sendable {
    let name: String
    let unit: String
    let directions: [ScanDirection]
}

public final class SXMParser: Sendable {
    public init() {}

    public func scanFolder(_ folder: URL) throws -> [SXMMetadata] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var output: [SXMMetadata] = []
        for url in urls where url.pathExtension.lowercased() == "sxm" {
            do {
                output.append(try loadMetadata(url))
            } catch {
                // Keep folder scans resilient; malformed files simply do not enter the index.
                continue
            }
        }
        return output
    }

    public func loadMetadata(_ url: URL) throws -> SXMMetadata {
        let headerRead = try readHeader(url)
        let header = parseHeader(headerRead.text)
        return try metadata(from: url, header: header, specs: parseDataInfo(header["DATA_INFO"] ?? ""))
    }

    public func loadFullFile(_ metadata: SXMMetadata) throws -> SXMFullFile {
        let headerRead = try readHeader(metadata.path)
        let specs = parseDataInfo(headerRead.header["DATA_INFO"] ?? "")
        let matrices = try readMatrices(
            url: metadata.path,
            offset: headerRead.bodyOffset,
            width: metadata.pixels.width,
            height: metadata.pixels.height,
            specs: specs
        )
        let channels = channelsFromSpecs(specs, matrices: matrices)
        let refreshed = SXMMetadata(
            id: metadata.id,
            path: metadata.path,
            filename: metadata.filename,
            header: metadata.header,
            recordedTime: metadata.recordedTime,
            modifiedTime: metadata.modifiedTime,
            pixels: metadata.pixels,
            scanRange: metadata.scanRange,
            scanOffset: metadata.scanOffset,
            scanAngle: metadata.scanAngle,
            scanDir: metadata.scanDir,
            zControllerOn: metadata.zControllerOn,
            channels: channels,
            defaultChannel: chooseDefaultChannel(channels, zControllerOn: metadata.zControllerOn)
        )
        return SXMFullFile(metadata: refreshed, matrices: matrices)
    }

    private func metadata(from url: URL, header: [String: String], specs: [ChannelSpec]) throws -> SXMMetadata {
        guard let pixels = parsePixels(header["SCAN_PIXELS"]) else { throw SXMParserError.missingPixels(url) }
        guard !specs.isEmpty else { throw SXMParserError.missingChannels(url) }

        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedTime = resourceValues?.contentModificationDate ?? Date.distantPast
        let zControllerOn = parseZControllerOn(header["Z-CONTROLLER"] ?? "")
        let channels = channelsFromSpecs(specs, matrices: nil)

        return SXMMetadata(
            path: url,
            filename: url.lastPathComponent,
            header: header,
            recordedTime: parseRecordedTime(header),
            modifiedTime: modifiedTime,
            pixels: pixels,
            scanRange: parseFloatPair(header["SCAN_RANGE"]),
            scanOffset: parseFloatPair(header["SCAN_OFFSET"]),
            scanAngle: parseSingleFloat(header["SCAN_ANGLE"]),
            scanDir: cleanSingleLine(header["SCAN_DIR"]),
            zControllerOn: zControllerOn,
            channels: channels,
            defaultChannel: chooseDefaultChannel(channels, zControllerOn: zControllerOn)
        )
    }

    private func readHeader(_ url: URL) throws -> (text: String, header: [String: String], bodyOffset: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SXMParserError.cannotOpen(url)
        }
        defer { try? handle.close() }

        var buffer = Data()
        var totalOffset: UInt64 = 0
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if let range = buffer.range(of: dataMarker) {
                let headerData = buffer.subdata(in: 0..<range.lowerBound)
                let text = String(data: headerData, encoding: .isoLatin1) ?? String(decoding: headerData, as: UTF8.self)
                return (text, parseHeader(text), UInt64(range.upperBound))
            }
            totalOffset += UInt64(chunk.count)
            if totalOffset > 16 * 1024 * 1024 {
                break
            }
        }
        throw SXMParserError.markerNotFound(url)
    }

    private func readMatrices(
        url: URL,
        offset: UInt64,
        width: Int,
        height: Int,
        specs: [ChannelSpec]
    ) throws -> [MatrixKey: Matrix] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SXMParserError.cannotOpen(url)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)

        let itemCount = width * height
        let byteCount = itemCount * 4
        var matrices: [MatrixKey: Matrix] = [:]

        for spec in specs {
            for direction in spec.directions {
                let chunk = try handle.read(upToCount: byteCount) ?? Data()
                if chunk.count < byteCount {
                    throw SXMParserError.shortData(url)
                }
                var values = [Float](repeating: 0, count: itemCount)
                chunk.withUnsafeBytes { rawBuffer in
                    guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                    for idx in 0..<itemCount {
                        let j = idx * 4
                        let bits = (UInt32(bytes[j]) << 24)
                            | (UInt32(bytes[j + 1]) << 16)
                            | (UInt32(bytes[j + 2]) << 8)
                            | UInt32(bytes[j + 3])
                        values[idx] = Float(bitPattern: bits)
                    }
                }
                if direction == .bwd {
                    values = flipHorizontally(values: values, width: width, height: height)
                }
                matrices[MatrixKey(channel: spec.name, direction: direction)] = Matrix(width: width, height: height, values: values)
            }
        }
        return matrices
    }
}

public func parseHeader(_ headerText: String) -> [String: String] {
    var header: [String: String] = [:]
    var currentKey: String?
    var currentLines: [String] = []

    for rawLine in headerText.split(whereSeparator: \.isNewline).map(String.init) {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        if line.hasPrefix(":") && line.hasSuffix(":") && line.count > 2 {
            if let key = currentKey {
                header[key] = currentLines.joined(separator: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            }
            let key = String(line.dropFirst().dropLast())
            if key == "SCANIT_END" {
                currentKey = nil
                currentLines.removeAll()
                break
            }
            currentKey = key
            currentLines.removeAll()
        } else if currentKey != nil {
            currentLines.append(line)
        }
    }

    if let key = currentKey {
        header[key] = currentLines.joined(separator: "\n").trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
    }
    return header
}

func parseDataInfo(_ value: String) -> [ChannelSpec] {
    let lines = value
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard lines.count >= 2 else { return [] }

    let header = splitDataLine(lines[0]).map { $0.lowercased() }
    var specs: [ChannelSpec] = []
    for line in lines.dropFirst() {
        let parts = splitDataLine(line)
        if parts.count < 2 { continue }
        var row: [String: String] = [:]
        for (idx, key) in header.enumerated() where idx < parts.count {
            row[key] = parts[idx]
        }
        let name = row["name"] ?? parts[safe: 1] ?? parts[0]
        let unit = row["unit"] ?? parts[safe: 2] ?? ""
        let directionValue = (row["direction"] ?? parts[safe: 3] ?? "both").lowercased()
        specs.append(ChannelSpec(name: name, unit: unit, directions: directions(for: directionValue)))
    }
    return specs
}

func chooseDefaultChannel(_ channels: [SXMChannel], zControllerOn: Bool?) -> String? {
    guard !channels.isEmpty else { return nil }
    let freq = findChannel(channels, keywords: ["frequency shift", "freq", "df", "delta f", "Δf"])
    if zControllerOn == false, let freq {
        return freq
    }
    if let height = findChannel(channels, keywords: ["z", "height", "topography"]) {
        return height
    }
    if let freq {
        return freq
    }
    return channels[0].name
}

func channelsFromSpecs(_ specs: [ChannelSpec], matrices: [MatrixKey: Matrix]?) -> [SXMChannel] {
    specs.map { spec in
        let dirs: [ScanDirection]
        if let matrices {
            dirs = ScanDirection.allCases.filter { matrices[MatrixKey(channel: spec.name, direction: $0)] != nil }
        } else {
            dirs = spec.directions
        }
        return SXMChannel(name: spec.name, unit: spec.unit, directions: dirs, kind: classifyChannel(spec.name))
    }
}

private func splitDataLine(_ line: String) -> [String] {
    if line.contains("\t") {
        return line.split(separator: "\t").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    return line.split(whereSeparator: \.isWhitespace).map(String.init)
}

private func directions(for value: String) -> [ScanDirection] {
    if ["both", "fwd+bwd", "forward+backward"].contains(value) {
        return [.fwd, .bwd]
    }
    if ["backward", "bwd"].contains(value) {
        return [.bwd]
    }
    return [.fwd]
}

private func parsePixels(_ value: String?) -> (width: Int, height: Int)? {
    guard let value else { return nil }
    let parts = value.split(whereSeparator: \.isWhitespace)
    guard parts.count >= 2, let w = Double(parts[0]), let h = Double(parts[1]) else { return nil }
    return (Int(w), Int(h))
}

private func parseFloatPair(_ value: String?) -> (x: Double, y: Double)? {
    guard let value else { return nil }
    let parts = value.split(whereSeparator: \.isWhitespace)
    guard parts.count >= 2, let x = Double(parts[0]), let y = Double(parts[1]) else { return nil }
    return (x, y)
}

private func parseSingleFloat(_ value: String?) -> Double? {
    guard let value else { return nil }
    return value.split(whereSeparator: \.isWhitespace).first.flatMap { Double($0) }
}

private func parseRecordedTime(_ header: [String: String]) -> Date? {
    guard let dateValue = cleanSingleLine(header["REC_DATE"]) else { return nil }
    let timeValue = cleanSingleLine(header["REC_TIME"]) ?? "00:00:00"
    let raw = "\(dateValue) \(timeValue)"
    let formats = ["dd.MM.yyyy HH:mm:ss", "dd.MM.yy HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "MM/dd/yyyy HH:mm:ss"]
    for format in formats {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if let date = formatter.date(from: raw) {
            return date
        }
    }
    return nil
}

private func parseZControllerOn(_ value: String) -> Bool? {
    let lines = value
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    if lines.count >= 2 {
        let labels = splitDataLine(lines[0]).map { $0.lowercased() }
        let values = splitDataLine(lines[1]).map { $0.lowercased() }
        for (idx, label) in labels.enumerated() where ["on/off", "on", "active"].contains(label) && idx < values.count {
            let token = values[idx]
            if ["1", "on", "true"].contains(token) { return true }
            if ["0", "off", "false"].contains(token) { return false }
        }
    }

    let folded = value.lowercased()
    if folded.contains("off") { return false }
    if folded.contains("on") { return true }
    for line in folded.split(whereSeparator: \.isNewline).map(String.init) {
        if line.contains("controller status") || line.contains("status") {
            if line.contains("off") { return false }
            if line.contains("on") { return true }
        }
    }
    return nil
}

private func cleanSingleLine(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed.split(whereSeparator: \.isNewline).first.map(String.init)
}

private func findChannel(_ channels: [SXMChannel], keywords: [String]) -> String? {
    for channel in channels {
        let folded = channel.name.lowercased()
        if keywords.contains(where: { folded.contains($0.lowercased()) || channel.name.contains($0) }) {
            return channel.name
        }
    }
    return nil
}

private func flipHorizontally(values: [Float], width: Int, height: Int) -> [Float] {
    var output = values
    for y in 0..<height {
        for x in 0..<width {
            output[y * width + x] = values[y * width + (width - 1 - x)]
        }
    }
    return output
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
