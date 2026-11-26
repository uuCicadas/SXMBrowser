import Foundation

public enum SXMParserError: LocalizedError, Equatable, Sendable {
    case markerNotFound(URL)
    case missingPixels(URL)
    case invalidPixels(URL, rawValue: String)
    case pixelDimensionsOutOfRange(
        URL,
        width: Int,
        height: Int,
        maximumDimension: Int
    )
    case pixelCountOverflow(URL, width: Int, height: Int)
    case pixelCountExceedsLimit(URL, count: Int, maximumCount: Int)
    case missingChannels(URL)
    case duplicateChannel(URL, name: String)
    case missingScanType(URL)
    case unsupportedScanType(URL, rawValue: String)
    case dataSizeOverflow(URL, pixelCount: Int, matrixCount: Int)
    case matrixNotFound(URL, channel: String, direction: ScanDirection)
    case cannotOpen(URL)
    case shortData(URL, expectedBytes: UInt64, availableBytes: UInt64)

    public var errorDescription: String? {
        switch self {
        case .markerNotFound(let url): "SXM data marker not found: \(url.lastPathComponent)"
        case .missingPixels(let url): "SCAN_PIXELS not found: \(url.lastPathComponent)"
        case .invalidPixels(let url, let rawValue):
            "Invalid SCAN_PIXELS \"\(rawValue)\": \(url.lastPathComponent)"
        case .pixelDimensionsOutOfRange(let url, let width, let height, let maximumDimension):
            "SCAN_PIXELS \(width)×\(height) must be within 1...\(maximumDimension): \(url.lastPathComponent)"
        case .pixelCountOverflow(let url, let width, let height):
            "SCAN_PIXELS \(width)×\(height) overflows the supported size: \(url.lastPathComponent)"
        case .pixelCountExceedsLimit(let url, let count, let maximumCount):
            "SXM has \(count) pixels; maximum is \(maximumCount): \(url.lastPathComponent)"
        case .missingChannels(let url): "DATA_INFO has no channels: \(url.lastPathComponent)"
        case .duplicateChannel(let url, let name):
            "DATA_INFO contains duplicate channel \"\(name)\": \(url.lastPathComponent)"
        case .missingScanType(let url):
            "SCANIT_TYPE not found: \(url.lastPathComponent)"
        case .unsupportedScanType(let url, let rawValue):
            "Unsupported SCANIT_TYPE \"\(rawValue)\": \(url.lastPathComponent)"
        case .dataSizeOverflow(let url, let pixelCount, let matrixCount):
            "Matrix byte size overflows for \(pixelCount) pixels × \(matrixCount) matrices: \(url.lastPathComponent)"
        case .matrixNotFound(let url, let channel, let direction):
            "Matrix \(channel) \(direction.label) is not available: \(url.lastPathComponent)"
        case .cannotOpen(let url): "Cannot open file: \(url.path)"
        case .shortData(let url, let expectedBytes, let availableBytes):
            "File has \(availableBytes) matrix bytes; expected \(expectedBytes): \(url.lastPathComponent)"
        }
    }
}

private let dataMarker = Data([0x1a, 0x04])

private enum SXMStorageEncoding {
    case float32MSBFirst
}

struct ChannelSpec: Sendable {
    let name: String
    let unit: String
    let directions: [ScanDirection]
}

public final class SXMParser: Sendable {
    public static let maximumPixelDimension = 16_384
    public static let maximumPixelCount = 64 * 1024 * 1024
    private static let bytesPerSample = 4

    public init() {}

    public func scanFolder(_ folder: URL) throws -> ScanReport<SXMMetadata> {
        try Task.checkCancellation()
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        let sxmURLs = urls
            .filter { $0.pathExtension.lowercased() == "sxm" }
            .sorted(by: scanURLOrderedBefore)

        var output: [SXMMetadata] = []
        var issues: [ScanIssue] = []
        for url in sxmURLs {
            try Task.checkCancellation()
            do {
                output.append(try loadMetadata(url))
            } catch let error as CancellationError {
                throw error
            } catch {
                issues.append(
                    ScanIssue(
                        file: url,
                        stage: .sxmMetadata,
                        reason: error.localizedDescription
                    )
                )
            }
        }
        return ScanReport(items: output, issues: issues)
    }

    public func loadMetadata(_ url: URL) throws -> SXMMetadata {
        try Task.checkCancellation()
        let headerRead = try readHeader(url)
        try Task.checkCancellation()
        return try metadata(
            from: url,
            header: headerRead.header,
            specs: try parseDataInfo(
                headerRead.header["DATA_INFO"] ?? "",
                cancellation: .task
            )
        )
    }

    public func loadFullFile(_ metadata: SXMMetadata) throws -> SXMFullFile {
        try Task.checkCancellation()
        let headerRead = try readHeader(metadata.path)
        try Task.checkCancellation()
        let specs = try parseDataInfo(
            headerRead.header["DATA_INFO"] ?? "",
            cancellation: .task
        )
        let currentMetadata = try self.metadata(
            from: metadata.path,
            header: headerRead.header,
            specs: specs,
            id: metadata.id
        )
        let encoding = try storageEncoding(
            headerRead.header["SCANIT_TYPE"],
            url: metadata.path
        )
        try Task.checkCancellation()
        let matrices = try readMatrices(
            url: metadata.path,
            offset: headerRead.bodyOffset,
            width: currentMetadata.pixels.width,
            height: currentMetadata.pixels.height,
            specs: specs,
            scanDir: currentMetadata.scanDir,
            encoding: encoding
        )
        try Task.checkCancellation()
        let channels = channelsFromSpecs(specs, matrices: matrices)
        let refreshed = SXMMetadata(
            id: metadata.id,
            path: metadata.path,
            filename: metadata.filename,
            header: currentMetadata.header,
            recordedTime: currentMetadata.recordedTime,
            modifiedTime: currentMetadata.modifiedTime,
            pixels: currentMetadata.pixels,
            scanRange: currentMetadata.scanRange,
            scanOffset: currentMetadata.scanOffset,
            scanAngle: currentMetadata.scanAngle,
            scanDir: currentMetadata.scanDir,
            zControllerOn: currentMetadata.zControllerOn,
            channels: channels,
            defaultChannel: chooseDefaultChannel(
                channels,
                zControllerOn: currentMetadata.zControllerOn
            )
        )
        return SXMFullFile(metadata: refreshed, matrices: matrices)
    }

    public func loadMatrix(
        _ metadata: SXMMetadata,
        key: MatrixKey
    ) throws -> Matrix {
        try Task.checkCancellation()
        let headerRead = try readHeader(metadata.path)
        try Task.checkCancellation()
        let specs = try parseDataInfo(
            headerRead.header["DATA_INFO"] ?? "",
            cancellation: .task
        )
        let currentMetadata = try self.metadata(
            from: metadata.path,
            header: headerRead.header,
            specs: specs,
            id: metadata.id
        )
        let encoding = try storageEncoding(
            headerRead.header["SCANIT_TYPE"],
            url: metadata.path
        )
        let layout = try matrixLayout(
            url: metadata.path,
            width: currentMetadata.pixels.width,
            height: currentMetadata.pixels.height,
            specs: specs
        )
        guard let matrixIndex = matrixIndex(for: key, specs: specs) else {
            throw SXMParserError.matrixNotFound(
                metadata.path,
                channel: key.channel,
                direction: key.direction
            )
        }
        try Task.checkCancellation()
        return try readMatrix(
            url: metadata.path,
            payloadOffset: headerRead.bodyOffset,
            layout: layout,
            matrixIndex: matrixIndex,
            direction: key.direction,
            scanDir: currentMetadata.scanDir,
            encoding: encoding
        )
    }

    private func metadata(
        from url: URL,
        header: [String: String],
        specs: [ChannelSpec],
        id: UUID = UUID()
    ) throws -> SXMMetadata {
        try Task.checkCancellation()
        let pixels = try parsePixels(header["SCAN_PIXELS"], url: url)
        guard !specs.isEmpty else { throw SXMParserError.missingChannels(url) }
        var channelNames: Set<String> = []
        for spec in specs where !channelNames.insert(spec.name).inserted {
            throw SXMParserError.duplicateChannel(url, name: spec.name)
        }
        try Task.checkCancellation()
        _ = try storageEncoding(header["SCANIT_TYPE"], url: url)

        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedTime = resourceValues?.contentModificationDate ?? Date.distantPast
        let zControllerOn = parseZControllerOn(header["Z-CONTROLLER"] ?? "")
        let channels = channelsFromSpecs(specs, matrices: nil)

        return SXMMetadata(
            id: id,
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
        try Task.checkCancellation()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SXMParserError.cannotOpen(url)
        }
        defer { try? handle.close() }

        var buffer = Data()
        var totalOffset: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            if let range = buffer.range(of: dataMarker) {
                let headerData = buffer.subdata(in: 0..<range.lowerBound)
                let text = String(data: headerData, encoding: .isoLatin1) ?? String(decoding: headerData, as: UTF8.self)
                try Task.checkCancellation()
                return (
                    text,
                    try parseHeader(text, cancellation: .task),
                    UInt64(range.upperBound)
                )
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
        specs: [ChannelSpec],
        scanDir: String?,
        encoding: SXMStorageEncoding
    ) throws -> [MatrixKey: Matrix] {
        try Task.checkCancellation()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SXMParserError.cannotOpen(url)
        }
        defer { try? handle.close() }

        let layout = try matrixLayout(
            url: url,
            width: width,
            height: height,
            specs: specs
        )
        try validateFileLength(handle, url: url, payloadOffset: offset, layout: layout)
        try handle.seek(toOffset: offset)

        var matrices: [MatrixKey: Matrix] = [:]
        var consumedPayloadBytes = 0

        for spec in specs {
            for direction in spec.directions {
                try Task.checkCancellation()
                let chunk = try readExactly(handle, count: layout.byteCount)
                if chunk.count < layout.byteCount {
                    throw SXMParserError.shortData(
                        url,
                        expectedBytes: UInt64(layout.expectedPayloadBytes),
                        availableBytes: UInt64(consumedPayloadBytes + chunk.count)
                    )
                }
                consumedPayloadBytes += chunk.count
                let values = try decodeValues(
                    chunk,
                    itemCount: layout.itemCount,
                    width: layout.width,
                    height: layout.height,
                    direction: direction,
                    scanDir: scanDir,
                    encoding: encoding
                )
                try Task.checkCancellation()
                matrices[MatrixKey(channel: spec.name, direction: direction)] = Matrix(width: width, height: height, values: values)
            }
        }
        return matrices
    }

    private struct MatrixLayout {
        let width: Int
        let height: Int
        let itemCount: Int
        let byteCount: Int
        let matrixCount: Int
        let expectedPayloadBytes: Int
    }

    private func matrixLayout(
        url: URL,
        width: Int,
        height: Int,
        specs: [ChannelSpec]
    ) throws -> MatrixLayout {
        let (itemCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else {
            throw SXMParserError.pixelCountOverflow(
                url,
                width: width,
                height: height
            )
        }
        let (byteCount, matrixByteOverflow) = itemCount.multipliedReportingOverflow(
            by: Self.bytesPerSample
        )
        guard !matrixByteOverflow else {
            throw SXMParserError.dataSizeOverflow(
                url,
                pixelCount: itemCount,
                matrixCount: 1
            )
        }

        var matrixCount = 0
        for spec in specs {
            try Task.checkCancellation()
            let (nextCount, overflowed) = matrixCount.addingReportingOverflow(
                spec.directions.count
            )
            guard !overflowed else {
                throw SXMParserError.dataSizeOverflow(
                    url,
                    pixelCount: itemCount,
                    matrixCount: matrixCount
                )
            }
            matrixCount = nextCount
        }
        let (expectedPayloadBytes, payloadOverflow) = byteCount
            .multipliedReportingOverflow(by: matrixCount)
        guard !payloadOverflow else {
            throw SXMParserError.dataSizeOverflow(
                url,
                pixelCount: itemCount,
                matrixCount: matrixCount
            )
        }
        return MatrixLayout(
            width: width,
            height: height,
            itemCount: itemCount,
            byteCount: byteCount,
            matrixCount: matrixCount,
            expectedPayloadBytes: expectedPayloadBytes
        )
    }

    private func matrixIndex(
        for key: MatrixKey,
        specs: [ChannelSpec]
    ) -> Int? {
        var index = 0
        for spec in specs {
            for direction in spec.directions {
                if spec.name == key.channel, direction == key.direction {
                    return index
                }
                index += 1
            }
        }
        return nil
    }

    private func validateFileLength(
        _ handle: FileHandle,
        url: URL,
        payloadOffset: UInt64,
        layout: MatrixLayout
    ) throws {
        try Task.checkCancellation()
        let fileLength = try handle.seekToEnd()
        let availablePayloadBytes = fileLength >= payloadOffset
            ? fileLength - payloadOffset
            : 0
        let expectedPayloadBytes = UInt64(layout.expectedPayloadBytes)
        guard availablePayloadBytes >= expectedPayloadBytes else {
            throw SXMParserError.shortData(
                url,
                expectedBytes: expectedPayloadBytes,
                availableBytes: availablePayloadBytes
            )
        }
    }

    private func readMatrix(
        url: URL,
        payloadOffset: UInt64,
        layout: MatrixLayout,
        matrixIndex: Int,
        direction: ScanDirection,
        scanDir: String?,
        encoding: SXMStorageEncoding
    ) throws -> Matrix {
        try Task.checkCancellation()
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SXMParserError.cannotOpen(url)
        }
        defer { try? handle.close() }

        try validateFileLength(
            handle,
            url: url,
            payloadOffset: payloadOffset,
            layout: layout
        )
        let (relativeOffset, offsetOverflow) = layout.byteCount
            .multipliedReportingOverflow(by: matrixIndex)
        guard !offsetOverflow,
              let relativeOffset64 = UInt64(exactly: relativeOffset) else {
            throw SXMParserError.dataSizeOverflow(
                url,
                pixelCount: layout.itemCount,
                matrixCount: layout.matrixCount
            )
        }
        let (matrixOffset, matrixOffsetOverflow) = payloadOffset
            .addingReportingOverflow(relativeOffset64)
        guard !matrixOffsetOverflow else {
            throw SXMParserError.dataSizeOverflow(
                url,
                pixelCount: layout.itemCount,
                matrixCount: layout.matrixCount
            )
        }
        try handle.seek(toOffset: matrixOffset)
        let chunk = try readExactly(handle, count: layout.byteCount)
        guard chunk.count == layout.byteCount else {
            let matrixBytesBefore = relativeOffset
            throw SXMParserError.shortData(
                url,
                expectedBytes: UInt64(layout.expectedPayloadBytes),
                availableBytes: UInt64(matrixBytesBefore + chunk.count)
            )
        }
        let values = try decodeValues(
            chunk,
            itemCount: layout.itemCount,
            width: layout.width,
            height: layout.height,
            direction: direction,
            scanDir: scanDir,
            encoding: encoding
        )
        return Matrix(
            width: layout.width,
            height: layout.height,
            values: values
        )
    }

    private func decodeValues(
        _ chunk: Data,
        itemCount: Int,
        width: Int,
        height: Int,
        direction: ScanDirection,
        scanDir: String?,
        encoding: SXMStorageEncoding
    ) throws -> [Float] {
        var values = [Float](repeating: 0, count: itemCount)
        try chunk.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            for idx in 0..<itemCount {
                if idx.isMultiple(of: 4_096) {
                    try Task.checkCancellation()
                }
                let byteIndex = idx * Self.bytesPerSample
                let bits: UInt32
                switch encoding {
                case .float32MSBFirst:
                    bits = (UInt32(bytes[byteIndex]) << 24)
                        | (UInt32(bytes[byteIndex + 1]) << 16)
                        | (UInt32(bytes[byteIndex + 2]) << 8)
                        | UInt32(bytes[byteIndex + 3])
                }
                values[idx] = Float(bitPattern: bits)
            }
        }
        if direction == .bwd {
            values = try flipHorizontally(
                values: values,
                width: width,
                height: height
            )
        }
        if isUpwardScanDirection(scanDir) {
            values = try flipVertically(
                values: values,
                width: width,
                height: height
            )
        }
        try Task.checkCancellation()
        return values
    }

    private func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        var output = Data()
        output.reserveCapacity(count)
        while output.count < count {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: count - output.count) ?? Data()
            guard !chunk.isEmpty else { break }
            output.append(chunk)
        }
        return output
    }
}

private func scanURLOrderedBefore(_ lhs: URL, _ rhs: URL) -> Bool {
    let filenameOrder = lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
    if filenameOrder != .orderedSame {
        return filenameOrder == .orderedAscending
    }
    return lhs.standardizedFileURL.path.compare(
        rhs.standardizedFileURL.path,
        options: .literal
    ) == .orderedAscending
}

public func parseHeader(_ headerText: String) -> [String: String] {
    try! parseHeader(headerText, cancellation: .none)
}

private func parseHeader(
    _ headerText: String,
    cancellation: CancellationCheckpoint
) throws -> [String: String] {
    try cancellation.check()
    var header: [String: String] = [:]
    var currentKey: String?
    var currentLines: [String] = []

    for (lineIndex, rawLine) in headerText
        .split(whereSeparator: \.isNewline)
        .enumerated() {
        if lineIndex.isMultiple(of: 128) {
            try cancellation.check()
        }
        let rawLine = String(rawLine)
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
    try cancellation.check()
    return header
}

func parseDataInfo(_ value: String) -> [ChannelSpec] {
    try! parseDataInfo(value, cancellation: .none)
}

private func parseDataInfo(
    _ value: String,
    cancellation: CancellationCheckpoint
) throws -> [ChannelSpec] {
    try cancellation.check()
    let lines = value
        .split(whereSeparator: \.isNewline)
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard lines.count >= 2 else { return [] }

    let header = splitDataLine(lines[0]).map { $0.lowercased() }
    var specs: [ChannelSpec] = []
    for (lineIndex, line) in lines.dropFirst().enumerated() {
        if lineIndex.isMultiple(of: 128) {
            try cancellation.check()
        }
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
    try cancellation.check()
    return specs
}

func chooseDefaultChannel(_ channels: [SXMChannel], zControllerOn: Bool?) -> String? {
    guard !channels.isEmpty else { return nil }
    let freq = channels.first(where: { isFrequencyShiftChannel($0.name) })?.name
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

private func parsePixels(
    _ value: String?,
    url: URL
) throws -> (width: Int, height: Int) {
    guard let value else { throw SXMParserError.missingPixels(url) }
    let parts = value.split(whereSeparator: \.isWhitespace)
    guard parts.count == 2,
          let width = Int(parts[0]),
          let height = Int(parts[1]) else {
        throw SXMParserError.invalidPixels(url, rawValue: value)
    }

    let (pixelCount, overflowed) = width.multipliedReportingOverflow(by: height)
    guard !overflowed else {
        throw SXMParserError.pixelCountOverflow(
            url,
            width: width,
            height: height
        )
    }
    guard (1...SXMParser.maximumPixelDimension).contains(width),
          (1...SXMParser.maximumPixelDimension).contains(height) else {
        throw SXMParserError.pixelDimensionsOutOfRange(
            url,
            width: width,
            height: height,
            maximumDimension: SXMParser.maximumPixelDimension
        )
    }
    guard pixelCount <= SXMParser.maximumPixelCount else {
        throw SXMParserError.pixelCountExceedsLimit(
            url,
            count: pixelCount,
            maximumCount: SXMParser.maximumPixelCount
        )
    }
    return (width, height)
}

private func storageEncoding(
    _ value: String?,
    url: URL
) throws -> SXMStorageEncoding {
    guard let value,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw SXMParserError.missingScanType(url)
    }
    let tokens = value
        .split(whereSeparator: \.isWhitespace)
        .map { $0.uppercased() }
    guard tokens == ["FLOAT", "MSBFIRST"] else {
        throw SXMParserError.unsupportedScanType(url, rawValue: value)
    }
    return .float32MSBFirst
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

private let sxmRecordedTimeParser = POSIXDateParser(formats: [
    "dd.MM.yyyy HH:mm:ss",
    "dd.MM.yy HH:mm:ss",
    "yyyy-MM-dd HH:mm:ss",
    "MM/dd/yyyy HH:mm:ss",
])

private func parseRecordedTime(_ header: [String: String]) -> Date? {
    guard let dateValue = cleanSingleLine(header["REC_DATE"]) else { return nil }
    let timeValue = cleanSingleLine(header["REC_TIME"]) ?? "00:00:00"
    return sxmRecordedTimeParser.date(from: "\(dateValue) \(timeValue)")
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

private func flipHorizontally(
    values: [Float],
    width: Int,
    height: Int
) throws -> [Float] {
    var output = values
    for y in 0..<height {
        try Task.checkCancellation()
        for x in 0..<width {
            if x.isMultiple(of: 4_096) {
                try Task.checkCancellation()
            }
            output[y * width + x] = values[y * width + (width - 1 - x)]
        }
    }
    return output
}

private func flipVertically(
    values: [Float],
    width: Int,
    height: Int
) throws -> [Float] {
    guard height > 1, width > 0 else { return values }
    var output = [Float](repeating: 0, count: values.count)
    for y in 0..<height {
        try Task.checkCancellation()
        let srcStart = (height - 1 - y) * width
        let dstStart = y * width
        output[dstStart..<(dstStart + width)] = values[srcStart..<(srcStart + width)]
    }
    return output
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
