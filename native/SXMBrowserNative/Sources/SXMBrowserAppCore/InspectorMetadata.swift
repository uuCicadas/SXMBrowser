import Foundation
import SXMBrowserCore

public struct InspectorCoordinatePair:
    Equatable,
    Sendable
{
    public let x: Double
    public let y: Double

    public init?(x: Double, y: Double) {
        guard x.isFinite, y.isFinite else { return nil }
        self.x = x
        self.y = y
    }
}

public struct InspectorHeaderEntry:
    Equatable,
    Hashable,
    Sendable,
    Identifiable
{
    public let key: String
    public let value: String

    public var id: String { key }

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct InspectorMetadataPresentation:
    Equatable,
    Sendable
{
    public let recordedTime: Date?
    public let modifiedTime: Date
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scanRangeMeters: InspectorCoordinatePair?
    public let scanOffsetMeters: InspectorCoordinatePair?
    public let scanAngleDegrees: Double?
    public let channelName: String
    public let channelUnit: String
    public let sampleBiasVolts: Double?
    public let feedbackControllerName: String?
    public let isFeedbackActive: Bool?
    public let setpointValue: Double?
    public let setpointUnit: String?
    public let setpointRawText: String?
    public let temperatureKelvin: Double?
    public let acquisitionSeconds: Double?
    public let scanSpeedMetersPerSecond: Double?
    public let comment: String?
    public let rawHeaderEntries: [InspectorHeaderEntry]

    public init(
        metadata: SXMMetadata,
        selectedChannelName: String
    ) {
        recordedTime = metadata.recordedTime
        modifiedTime = metadata.modifiedTime
        pixelWidth = max(0, metadata.pixels.width)
        pixelHeight = max(0, metadata.pixels.height)

        if let range = metadata.scanRange,
           range.x > 0,
           range.y > 0 {
            scanRangeMeters = InspectorCoordinatePair(
                x: range.x,
                y: range.y
            )
        } else {
            scanRangeMeters = nil
        }
        if let offset = metadata.scanOffset {
            scanOffsetMeters = InspectorCoordinatePair(
                x: offset.x,
                y: offset.y
            )
        } else {
            scanOffsetMeters = nil
        }
        if let angle = metadata.scanAngle,
           angle.isFinite {
            scanAngleDegrees = angle
        } else {
            scanAngleDegrees = nil
        }

        let selectedChannel = metadata.channels.first {
            $0.name == selectedChannelName
        }
        channelName = selectedChannel?.name
            ?? selectedChannelName
        channelUnit = selectedChannel?.unit ?? ""

        let header = metadata.header
        if let rawBias = Self.headerValue(
            in: header,
            keys: ["BIAS", "Bias>Bias (V)", "Bias>Bias"]
        ), let parsedBias = parseEngineeringDouble(rawBias), parsedBias.isFinite {
            sampleBiasVolts = parsedBias
        } else {
            sampleBiasVolts = nil
        }

        let zRow = Self.parseZControllerRow(
            Self.headerValue(in: header, keys: ["Z-CONTROLLER"])
        )
        feedbackControllerName = Self.headerValue(
            in: header,
            keys: ["Z-Controller>Controller name"]
        ) ?? zRow.name

        if let statusText = Self.headerValue(
            in: header,
            keys: ["Z-Controller>Controller status"]
        ), let parsedStatus = Self.parseBooleanStatus(statusText) {
            isFeedbackActive = parsedStatus
        } else {
            isFeedbackActive = zRow.isActive
        }

        let explicitSetpointText = Self.headerValue(
            in: header,
            keys: ["Z-Controller>Setpoint"]
        )
        let explicitSetpointUnit = Self.headerValue(
            in: header,
            keys: ["Z-Controller>Setpoint unit"]
        )
        if let explicitSetpointText,
           let parsedSetpoint = parseEngineeringDouble(explicitSetpointText),
           parsedSetpoint.isFinite {
            setpointValue = parsedSetpoint
            setpointUnit = explicitSetpointUnit ?? zRow.setpointUnit
            if let unit = setpointUnit, !unit.isEmpty {
                setpointRawText = "\(explicitSetpointText) \(unit)"
            } else {
                setpointRawText = explicitSetpointText
            }
        } else {
            setpointValue = zRow.setpointValue
            setpointUnit = explicitSetpointUnit ?? zRow.setpointUnit
            setpointRawText = zRow.setpointRawText ?? explicitSetpointText
        }

        temperatureKelvin = Self.parsePositiveFinite(
            in: header,
            keys: [
                "Temperature 2>Temperature 2 (K)",
                "Temperature 1>Temperature 1 (K)",
                "REC_TEMP"
            ],
            upperBound: 10_000
        )

        acquisitionSeconds = Self.parsePositiveFinite(
            in: header,
            keys: ["ACQ_TIME", "Acquisition time (s)"],
            upperBound: nil
        )

        scanSpeedMetersPerSecond = Self.parsePositiveFinite(
            in: header,
            keys: [
                "Scan>speed forw. (m/s)",
                "Scan>Speed forw. (m/s)",
                "Scan>speed (m/s)"
            ],
            upperBound: nil
        )

        comment = Self.headerValue(in: header, keys: ["COMMENT", "Comment"])

        var normalizedEntries: [String: String] = [:]
        for (rawKey, rawValue) in header {
            let cleanKey = Self.cleanHeaderKey(rawKey)
            let cleanValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanKey.isEmpty, !cleanValue.isEmpty else { continue }
            if normalizedEntries[cleanKey] == nil || rawKey == cleanKey {
                normalizedEntries[cleanKey] = cleanValue
            }
        }
        rawHeaderEntries = normalizedEntries
            .map { InspectorHeaderEntry(key: $0.key, value: $0.value) }
            .sorted { lhs, rhs in
                let order = lhs.key.localizedCaseInsensitiveCompare(rhs.key)
                if order != .orderedSame {
                    return order == .orderedAscending
                }
                return lhs.key < rhs.key
            }
    }

    public func filteredHeaderEntries(matching query: String) -> [InspectorHeaderEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rawHeaderEntries }
        return rawHeaderEntries.filter { entry in
            entry.key.localizedCaseInsensitiveContains(trimmed)
                || entry.value.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private static func cleanHeaderKey(_ key: String) -> String {
        var trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(":") && trimmed.hasSuffix(":") && trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func headerValue(
        in header: [String: String],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let direct = header[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !direct.isEmpty {
                return direct
            }
            if let wrapped = header[":\(key):"]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !wrapped.isEmpty {
                return wrapped
            }
        }
        return nil
    }

    private static func parsePositiveFinite(
        in header: [String: String],
        keys: [String],
        upperBound: Double?
    ) -> Double? {
        for key in keys {
            guard let text = headerValue(in: header, keys: [key]),
                  let parsed = parseEngineeringDouble(text),
                  parsed.isFinite,
                  parsed > 0 else {
                continue
            }
            if let upperBound, parsed >= upperBound {
                continue
            }
            return parsed
        }
        return nil
    }

    private static func parseBooleanStatus(_ text: String) -> Bool? {
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "on", "true", "yes", "enabled", "active":
            return true
        case "0", "off", "false", "no", "disabled", "inactive":
            return false
        default:
            return nil
        }
    }

    private struct ZControllerRow {
        let name: String?
        let isActive: Bool?
        let setpointValue: Double?
        let setpointUnit: String?
        let setpointRawText: String?
    }

    private static func parseZControllerRow(_ raw: String?) -> ZControllerRow {
        guard let raw, !raw.isEmpty else {
            return ZControllerRow(
                name: nil,
                isActive: nil,
                setpointValue: nil,
                setpointUnit: nil,
                setpointRawText: nil
            )
        }
        let rows = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !rows.isEmpty else {
            return ZControllerRow(
                name: nil,
                isActive: nil,
                setpointValue: nil,
                setpointUnit: nil,
                setpointRawText: nil
            )
        }

        let dataRow: String? = rows.first { row in
            let fields = row.components(separatedBy: "\t").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count >= 3 else { return false }
            let headerLike = fields[0].caseInsensitiveCompare("Name") == .orderedSame
                && fields[1].caseInsensitiveCompare("on") == .orderedSame
            return !headerLike
        }

        guard let dataRow else {
            return ZControllerRow(
                name: nil,
                isActive: nil,
                setpointValue: nil,
                setpointUnit: nil,
                setpointRawText: nil
            )
        }

        let fields = dataRow
            .components(separatedBy: "\t")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let name = fields.indices.contains(0) && !fields[0].isEmpty ? fields[0] : nil
        let isActive = fields.indices.contains(1) ? parseBooleanStatus(fields[1]) : nil
        let rawSetpoint = fields.indices.contains(2) && !fields[2].isEmpty ? fields[2] : nil

        var setpointValue: Double?
        var setpointUnit: String?
        if let rawSetpoint {
            let parts = rawSetpoint.split(maxSplits: 1, omittingEmptySubsequences: true) {
                $0.isWhitespace
            }
            if let numericToken = parts.first,
               let parsed = parseEngineeringDouble(String(numericToken)),
               parsed.isFinite {
                setpointValue = parsed
                if parts.count > 1 {
                    setpointUnit = String(parts[1])
                }
            }
        }

        return ZControllerRow(
            name: name,
            isActive: isActive,
            setpointValue: setpointValue,
            setpointUnit: setpointUnit,
            setpointRawText: rawSetpoint
        )
    }
}
