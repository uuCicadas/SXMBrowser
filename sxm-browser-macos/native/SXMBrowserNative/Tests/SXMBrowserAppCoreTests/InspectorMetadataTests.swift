import Foundation
import SXMBrowserCore
import Testing
@testable import SXMBrowserAppCore

private func inspectorMetadata(
    header: [String: String] = [:],
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
        header: header,
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
                kind: .topography
            ),
            SXMChannel(
                name: "Current",
                unit: "A",
                directions: [.fwd],
                kind: .conductanceOrCurrent
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

@Test
func inspectorPresentationExtractsAcquisitionParametersAndFiltersRawHeader() {
    let header: [String: String] = [
        "BIAS": "-2.500E-1",
        "Z-CONTROLLER": "Name\ton\tSetpoint\tP-gain\nlog Current\t0\t3.000E-11 A\t5.0E-12 m",
        "Z-Controller>Controller name": "log Current",
        "Z-Controller>Controller status": "OFF",
        "Z-Controller>Setpoint": "30E-12",
        "Z-Controller>Setpoint unit": "A",
        "REC_TEMP": "290.0",
        "Temperature 2>Temperature 2 (K)": "4.07",
        "ACQ_TIME": "496.4",
        "Scan>speed forw. (m/s)": "750.3E-12",
        "COMMENT": "  Au(111) constant height  ",
        "EMPTY_FIELD": "   "
    ]
    let metadata = inspectorMetadata(header: header)
    let presentation = InspectorMetadataPresentation(
        metadata: metadata,
        selectedChannelName: "Z"
    )

    #expect(presentation.sampleBiasVolts == -0.25)
    #expect(presentation.feedbackControllerName == "log Current")
    #expect(presentation.isFeedbackActive == false)
    #expect(presentation.setpointValue == 30e-12)
    #expect(presentation.setpointUnit == "A")
    #expect(presentation.setpointRawText == "30E-12 A")
    #expect(presentation.temperatureKelvin == 4.07)
    #expect(presentation.acquisitionSeconds == 496.4)
    #expect(presentation.scanSpeedMetersPerSecond == 750.3e-12)
    #expect(presentation.comment == "Au(111) constant height")

    #expect(!presentation.rawHeaderEntries.contains { $0.key == "EMPTY_FIELD" })
    #expect(presentation.filteredHeaderEntries(matching: "").count == presentation.rawHeaderEntries.count)
    #expect(
        presentation.filteredHeaderEntries(matching: "constAnt heiGht").map(\.key) == ["COMMENT"]
    )
    #expect(
        presentation.filteredHeaderEntries(matching: "setpoint")
            .map(\.key)
            .contains("Z-Controller>Setpoint")
    )
}

@Test
func inspectorPresentationIdentifiesFrequencyShiftChannels() {
    let metadata = SXMMetadata(
        path: URL(fileURLWithPath: "/tmp/afm.sxm"),
        filename: "afm.sxm",
        header: [:],
        recordedTime: nil,
        modifiedTime: Date(timeIntervalSince1970: 200),
        pixels: (width: 112, height: 112),
        scanRange: (x: 4e-9, y: 4e-9),
        scanOffset: nil,
        scanAngle: nil,
        scanDir: "down",
        zControllerOn: false,
        channels: [
            SXMChannel(name: "Z", unit: "m", directions: [.fwd], kind: .topography),
            SXMChannel(name: "Current", unit: "A", directions: [.fwd], kind: .conductanceOrCurrent),
            SXMChannel(name: "OC_D1_Amplitude", unit: "m", directions: [.fwd], kind: .afm),
            SXMChannel(name: "OC_M1_Freq._Shift", unit: "Hz", directions: [.fwd, .bwd], kind: .afm),
        ],
        defaultChannel: "OC_M1_Freq._Shift"
    )

    let freqPresentation = InspectorMetadataPresentation(
        metadata: metadata,
        selectedChannelName: "OC_M1_Freq._Shift"
    )
    #expect(freqPresentation.isFrequencyShiftChannel)
    #expect(freqPresentation.channelUnit == "Hz")

    let zPresentation = InspectorMetadataPresentation(
        metadata: metadata,
        selectedChannelName: "Z"
    )
    #expect(!zPresentation.isFrequencyShiftChannel)

    let currentPresentation = InspectorMetadataPresentation(
        metadata: metadata,
        selectedChannelName: "Current"
    )
    #expect(!currentPresentation.isFrequencyShiftChannel)

    let amplitudePresentation = InspectorMetadataPresentation(
        metadata: metadata,
        selectedChannelName: "OC_D1_Amplitude"
    )
    #expect(!amplitudePresentation.isFrequencyShiftChannel)
}

@Test
func frequencyShiftBoundsIgnoresNonFiniteHandlesConstantsEmptyAndCancellation() throws {
    let mixed = Matrix(
        width: 3,
        height: 2,
        values: [-12.34, .nan, 4.56, .infinity, -.infinity, 0.0]
    )
    let mixedBounds = try #require(FrequencyShiftBounds.from(matrix: mixed))
    #expect(abs(mixedBounds.min - Double(Float(-12.34))) < 1e-6)
    #expect(abs(mixedBounds.max - Double(Float(4.56))) < 1e-6)

    let constant = Matrix(width: 2, height: 2, values: [-8.5, -8.5, -8.5, -8.5])
    let constantBounds = try #require(FrequencyShiftBounds.from(matrix: constant))
    #expect(constantBounds.min == -8.5)
    #expect(constantBounds.max == -8.5)

    let empty = Matrix(width: 0, height: 0, values: [])
    #expect(FrequencyShiftBounds.from(matrix: empty) == nil)

    let allNonFinite = Matrix(width: 2, height: 1, values: [.nan, .infinity])
    #expect(FrequencyShiftBounds.from(matrix: allNonFinite) == nil)

    let cancelledCheckpoint = CancellationCheckpoint {
        throw CancellationError()
    }
    var didThrowCancellation = false
    do {
        _ = try FrequencyShiftBounds.from(matrix: mixed, cancellation: cancelledCheckpoint)
    } catch is CancellationError {
        didThrowCancellation = true
    }
    #expect(didThrowCancellation)
}
