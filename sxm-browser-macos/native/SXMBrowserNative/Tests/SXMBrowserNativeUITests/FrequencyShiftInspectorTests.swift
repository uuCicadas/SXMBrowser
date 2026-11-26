import Foundation
import SXMBrowserAppCore
import SXMBrowserCore
import Testing
@testable import SXMBrowserNativeUI

private actor MatrixLoadRecorder {
    private(set) var requests: [MatrixKey] = []

    func record(_ key: MatrixKey) {
        requests.append(key)
    }

    func count(for key: MatrixKey) -> Int {
        requests.filter { $0 == key }.count
    }

    var totalCount: Int {
        requests.count
    }
}

private struct RecordingMatrixReader: SXMMatrixReading {
    let matrices: [MatrixKey: Matrix]
    let recorder: MatrixLoadRecorder

    func loadMatrix(
        _ metadata: SXMMetadata,
        key: MatrixKey
    ) async throws -> Matrix {
        await recorder.record(key)
        guard let matrix = matrices[key] else {
            throw SXMParserError.matrixNotFound(
                metadata.path,
                channel: key.channel,
                direction: key.direction
            )
        }
        return matrix
    }
}

private func makeFrequencyShiftSXM(
    filename: String = "afm_test.sxm",
    includeBackward: Bool = true
) -> SXMMetadata {
    let directions: [ScanDirection] = includeBackward ? [.fwd, .bwd] : [.fwd]
    return SXMMetadata(
        path: URL(fileURLWithPath: "/tmp/sxm-test/\(filename)"),
        filename: filename,
        header: [:],
        recordedTime: nil,
        modifiedTime: Date(timeIntervalSince1970: 1_700_000_000),
        pixels: (width: 2, height: 2),
        scanRange: (x: 4e-9, y: 4e-9),
        scanOffset: (x: 0, y: 0),
        scanAngle: 0,
        scanDir: "down",
        zControllerOn: false,
        channels: [
            SXMChannel(
                name: "Z",
                unit: "m",
                directions: [.fwd, .bwd],
                kind: .topography
            ),
            SXMChannel(
                name: "OC_D1_Amplitude",
                unit: "m",
                directions: [.fwd],
                kind: .afm
            ),
            SXMChannel(
                name: "OC_M1_Freq._Shift",
                unit: "Hz",
                directions: directions,
                kind: .afm
            ),
        ],
        defaultChannel: "OC_M1_Freq._Shift"
    )
}

@Test
func formattedFrequencyShiftUsesOneDecimalAndAvoidsNegativeZero() {
    #expect(AppTheme.formattedFrequencyShift(-12.34) == "-12.3 Hz")
    #expect(AppTheme.formattedFrequencyShift(4.024) == "4.0 Hz")
    #expect(AppTheme.formattedFrequencyShift(0.3) == "0.3 Hz")
    #expect(AppTheme.formattedFrequencyShift(-0.04) == "0.0 Hz")
    #expect(AppTheme.formattedFrequencyShift(0.0) == "0.0 Hz")
    #expect(AppTheme.formattedFrequencyShift(5.26, unit: "") == "5.3 Hz")
    #expect(AppTheme.formattedFrequencyShift(5.26, unit: "   ") == "5.3 Hz")
    #expect(AppTheme.formattedFrequencyShift(5.26, unit: "kHz") == "5.3 kHz")
    #expect(AppTheme.formattedFrequencyShift(.nan) == "—")
    #expect(AppTheme.formattedFrequencyShift(.infinity) == "—")
}

@MainActor
@Test
func frequencyShiftBoundsLoadPerDirectionCacheHitsIgnoreScaleChangesAndInvalidate() async throws {
    let fwdKey = MatrixKey(channel: "OC_M1_Freq._Shift", direction: .fwd)
    let bwdKey = MatrixKey(channel: "OC_M1_Freq._Shift", direction: .bwd)
    let zKey = MatrixKey(channel: "Z", direction: .fwd)

    let fwdMatrix = Matrix(width: 2, height: 2, values: [-10.25, -2.0, .nan, 1.34])
    let bwdMatrix = Matrix(width: 2, height: 2, values: [-11.5, 0.22, -4.1, .infinity])
    let zMatrix = Matrix(width: 2, height: 2, values: [1e-10, 2e-10, 3e-10, 4e-10])

    let recorder = MatrixLoadRecorder()
    let coordinator = RenderCoordinator(
        matrixReader: RecordingMatrixReader(
            matrices: [
                fwdKey: fwdMatrix,
                bwdKey: bwdMatrix,
                zKey: zMatrix,
            ],
            recorder: recorder
        )
    )
    let model = AppModel(renderCoordinator: coordinator)
    let file = makeFrequencyShiftSXM()

    model.dataset.files = [file]
    model.mode = .grid
    model.select(file)

    #expect(model.selectedChannel == "OC_M1_Freq._Shift")
    #expect(model.selectedDirection == .fwd)

    // Non-frequency-shift channels do not produce bounds keys or trigger matrix loads.
    #expect(model.frequencyShiftBoundsKey(for: file, channel: "Z", direction: .fwd) == nil)
    #expect(model.frequencyShiftBoundsKey(for: file, channel: "OC_D1_Amplitude", direction: .fwd) == nil)
    let bogusNonFreqKey = FrequencyShiftBoundsKey(
        datasetRevision: coordinator.datasetRevision,
        fileID: file.id,
        path: file.path,
        modifiedTime: file.modifiedTime,
        channel: "Z",
        direction: .fwd
    )
    #expect(await model.loadFrequencyShiftBounds(for: file, key: bogusNonFreqKey) == nil)
    #expect(await recorder.totalCount == 0)

    // Grid mode loads raw forward bounds and caches the result.
    let gridFwdKey = try #require(
        model.frequencyShiftBoundsKey(
            for: file,
            channel: model.selectedChannel,
            direction: model.selectedDirection
        )
    )
    #expect(model.cachedFrequencyShiftBounds(for: gridFwdKey) == nil)
    let gridFwdBounds = try #require(await model.loadFrequencyShiftBounds(for: file, key: gridFwdKey))
    #expect(abs(gridFwdBounds.min - Double(Float(-10.25))) < 1e-6)
    #expect(abs(gridFwdBounds.max - Double(Float(1.34))) < 1e-6)
    #expect(model.cachedFrequencyShiftBounds(for: gridFwdKey) == gridFwdBounds)
    #expect(await recorder.count(for: fwdKey) == 1)

    // Repeating the load uses the cache without reading the matrix again.
    let repeatedFwdBounds = try #require(await model.loadFrequencyShiftBounds(for: file, key: gridFwdKey))
    #expect(repeatedFwdBounds == gridFwdBounds)
    #expect(await recorder.count(for: fwdKey) == 1)

    // Backward direction loads independently.
    model.selectedDirection = .bwd
    let bwdBoundsKey = try #require(
        model.frequencyShiftBoundsKey(
            for: file,
            channel: model.selectedChannel,
            direction: model.selectedDirection
        )
    )
    let bwdBounds = try #require(await model.loadFrequencyShiftBounds(for: file, key: bwdBoundsKey))
    #expect(abs(bwdBounds.min - Double(Float(-11.5))) < 1e-6)
    #expect(abs(bwdBounds.max - Double(Float(0.22))) < 1e-6)
    #expect(await recorder.count(for: bwdKey) == 1)

    // Switching to Single mode and changing contrast scale must not alter raw matrix bounds.
    model.selectedDirection = .fwd
    model.setMode(.single)
    for _ in 0..<50 where model.selectedStats == nil {
        await Task.yield()
    }
    model.updateScale(min: -5.0, max: 0.0)
    model.setPercentileScale()
    let singleFwdBounds = try #require(await model.loadFrequencyShiftBounds(for: file, key: gridFwdKey))
    #expect(singleFwdBounds == gridFwdBounds)

    // removeCachedData invalidates both matrix cache and bounds cache for that path.
    model.removeCachedData(for: file.path)
    #expect(model.cachedFrequencyShiftBounds(for: gridFwdKey) == nil)
    let reloadedFwdBounds = try #require(await model.loadFrequencyShiftBounds(for: file, key: gridFwdKey))
    #expect(reloadedFwdBounds == gridFwdBounds)
    #expect(await recorder.count(for: fwdKey) == 2)

    // New dataset revision isolates keys and clears bounds cache.
    coordinator.beginDataset(revision: UUID())
    model.viewer.clearFrequencyShiftBoundsCache()
    let postResetKey = try #require(
        model.frequencyShiftBoundsKey(
            for: file,
            channel: model.selectedChannel,
            direction: model.selectedDirection
        )
    )
    #expect(postResetKey != gridFwdKey)
    #expect(model.cachedFrequencyShiftBounds(for: postResetKey) == nil)
}

@MainActor
@Test
func frequencyShiftBoundsCachesUnavailableForAllNonFiniteMatrices() async throws {
    let fwdKey = MatrixKey(channel: "OC_M1_Freq._Shift", direction: .fwd)
    let nanMatrix = Matrix(width: 2, height: 2, values: [.nan, .infinity, -.infinity, .nan])
    let recorder = MatrixLoadRecorder()
    let coordinator = RenderCoordinator(
        matrixReader: RecordingMatrixReader(
            matrices: [fwdKey: nanMatrix],
            recorder: recorder
        )
    )
    let model = AppModel(renderCoordinator: coordinator)
    let file = makeFrequencyShiftSXM(filename: "nan_afm.sxm", includeBackward: false)

    model.dataset.files = [file]
    model.select(file)

    let boundsKey = try #require(
        model.frequencyShiftBoundsKey(
            for: file,
            channel: model.selectedChannel,
            direction: model.selectedDirection
        )
    )
    #expect(await model.loadFrequencyShiftBounds(for: file, key: boundsKey) == nil)
    #expect(model.cachedFrequencyShiftBounds(for: boundsKey) == nil)
    #expect(await recorder.count(for: fwdKey) == 1)

    // Second request hits the `.unavailable` cache entry and avoids re-reading the matrix.
    #expect(await model.loadFrequencyShiftBounds(for: file, key: boundsKey) == nil)
    #expect(await recorder.count(for: fwdKey) == 1)
}
