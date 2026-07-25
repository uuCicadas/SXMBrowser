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
    }
}
