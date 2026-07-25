import Foundation
import SXMBrowserCore
import Testing
@testable import SXMBrowserAppCore

private func inspectorMetadata(
    pixels: (width: Int, height: Int) = (512, 256),
    scanRange: (x: Double, y: Double)? =
        (80e-9, 40e-9),
    scanOffset: (x: Double, y: Double)? =
        (2e-9, -3e-9),
    scanAngle: Double? = 17.5
) -> SXMMetadata {
    SXMMetadata(
        path: URL(fileURLWithPath: "/tmp/inspector.sxm"),
        filename: "inspector.sxm",
        header: [:],
        recordedTime: Date(timeIntervalSince1970: 100),
        modifiedTime: Date(timeIntervalSince1970: 200),
        pixels: pixels,
        scanRange: scanRange,
        scanOffset: scanOffset,
        scanAngle: scanAngle,
        scanDir: "down",
        zControllerOn: true,
        channels: [
            SXMChannel(
                name: "Z",
                unit: "m",
                directions: [.fwd, .bwd],
                kind: .stm
            ),
            SXMChannel(
                name: "Current",
                unit: "A",
                directions: [.fwd],
                kind: .stm
            ),
        ],
        defaultChannel: "Z"
    )
}

@Test
func inspectorPresentationKeepsFileMetadataAndSelectedChannelUnit() {
    let metadata = inspectorMetadata()
    let presentation = InspectorMetadataPresentation(
        metadata: metadata,
        selectedChannelName: "Current"
    )

    #expect(
        presentation.recordedTime
            == Date(timeIntervalSince1970: 100)
    )
    #expect(
        presentation.modifiedTime
            == Date(timeIntervalSince1970: 200)
    )
    #expect(presentation.pixelWidth == 512)
    #expect(presentation.pixelHeight == 256)
    #expect(
        presentation.scanRangeMeters
            == InspectorCoordinatePair(
                x: 80e-9,
                y: 40e-9
            )
    )
    #expect(
        presentation.scanOffsetMeters
            == InspectorCoordinatePair(
                x: 2e-9,
                y: -3e-9
            )
    )
    #expect(presentation.scanAngleDegrees == 17.5)
    #expect(presentation.channelName == "Current")
    #expect(presentation.channelUnit == "A")
}

@Test
func inspectorPresentationRejectsInvalidPhysicalMetadata() {
    let metadata = inspectorMetadata(
        pixels: (width: -1, height: 0),
        scanRange: (x: .nan, y: -1),
        scanOffset: (x: .infinity, y: 0),
        scanAngle: .nan
    )
    let presentation = InspectorMetadataPresentation(
        metadata: metadata,
        selectedChannelName: "Missing raw name"
    )

    #expect(presentation.pixelWidth == 0)
    #expect(presentation.pixelHeight == 0)
    #expect(presentation.scanRangeMeters == nil)
    #expect(presentation.scanOffsetMeters == nil)
    #expect(presentation.scanAngleDegrees == nil)
    #expect(presentation.channelName == "Missing raw name")
    #expect(presentation.channelUnit.isEmpty)
}
