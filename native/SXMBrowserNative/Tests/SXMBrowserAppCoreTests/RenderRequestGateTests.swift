import Foundation
import Testing
@testable import SXMBrowserAppCore
import SXMBrowserCore

private let automaticConfiguration = SelectedRenderConfiguration(
    channel: "Z",
    direction: .fwd,
    processing: .lineLinear,
    palette: .ember,
    invert: false,
    histogramBins: 256,
    scale: .automatic
)

private func configuration(
    channel: String = "Z",
    direction: ScanDirection = .fwd,
    processing: ProcessingMode = .lineLinear,
    palette: PaletteName = .ember,
    invert: Bool = false,
    histogramBins: Int = 256,
    scale: RenderScaleRequest = .automatic
) -> SelectedRenderConfiguration {
    SelectedRenderConfiguration(
        channel: channel,
        direction: direction,
        processing: processing,
        palette: palette,
        invert: invert,
        histogramBins: histogramBins,
        scale: scale
    )
}

@Test
func onlyNewestOfOneHundredRenderRequestsIsAccepted() throws {
    var gate = RenderRequestGate<UUID>(datasetRevision: UUID())
    var requests: [RenderRequestIdentity<UUID>] = []

    for _ in 0..<100 {
        requests.append(
            gate.begin(fileID: UUID(), configuration: automaticConfiguration)
        )
    }

    let newest = try #require(requests.last)
    for request in requests.dropLast() {
        #expect(
            !gate.accepts(
                request,
                currentFileID: newest.fileID,
                currentConfiguration: automaticConfiguration
            )
        )
    }
    #expect(
        gate.accepts(
            newest,
            currentFileID: newest.fileID,
            currentConfiguration: automaticConfiguration
        )
    )
}

@Test
func staleConfigurationCannotPublishForSameFile() {
    let fileID = UUID()
    var gate = RenderRequestGate<UUID>()
    let oldRequest = gate.begin(
        fileID: fileID,
        configuration: automaticConfiguration
    )
    let newConfiguration = SelectedRenderConfiguration(
        channel: "Z",
        direction: .bwd,
        processing: .raw,
        palette: .gray,
        invert: true,
        histogramBins: 512,
        scale: .locked(min: -1, max: 1)
    )
    let newRequest = gate.begin(
        fileID: fileID,
        configuration: newConfiguration
    )

    #expect(
        !gate.accepts(
            oldRequest,
            currentFileID: fileID,
            currentConfiguration: newConfiguration
        )
    )
    #expect(
        gate.accepts(
            newRequest,
            currentFileID: fileID,
            currentConfiguration: newConfiguration
        )
    )
}

@Test
func datasetChangeAndInvalidationRejectOldResults() {
    let fileID = UUID()
    var gate = RenderRequestGate<UUID>(datasetRevision: UUID())
    let oldRequest = gate.begin(
        fileID: fileID,
        configuration: automaticConfiguration
    )

    gate.beginNewDataset(revision: UUID())
    #expect(
        !gate.accepts(
            oldRequest,
            currentFileID: fileID,
            currentConfiguration: automaticConfiguration
        )
    )

    let currentRequest = gate.begin(
        fileID: fileID,
        configuration: automaticConfiguration
    )
    gate.invalidate()
    #expect(
        !gate.accepts(
            currentRequest,
            currentFileID: fileID,
            currentConfiguration: automaticConfiguration
        )
    )
}

@Test
func histogramBinsDoNotInvalidateImageRenderIdentity() {
    let fileID = UUID()
    var gate = RenderRequestGate<UUID>()
    let request = gate.begin(
        fileID: fileID,
        configuration: automaticConfiguration
    )
    let rebinned = configuration(histogramBins: 1024)

    #expect(
        gate.accepts(
            request,
            currentFileID: fileID,
            currentConfiguration: rebinned
        )
    )
    #expect(
        automaticConfiguration.imageConfiguration
            == rebinned.imageConfiguration
    )
    #expect(
        automaticConfiguration.histogramConfiguration
            != rebinned.histogramConfiguration
    )
}

@Test
func paletteInvertAndScaleReuseProcessedDataAndHistogram() {
    let displayChanged = configuration(
        palette: .gray,
        invert: true,
        scale: .locked(min: -2, max: 3)
    )

    #expect(
        automaticConfiguration.processedConfiguration
            == displayChanged.processedConfiguration
    )
    #expect(
        automaticConfiguration.histogramConfiguration
            == displayChanged.histogramConfiguration
    )
    #expect(
        automaticConfiguration.imageConfiguration
            != displayChanged.imageConfiguration
    )
}

@Test
func dataSelectionsProduceDistinctProcessedKeys() {
    let revision = UUID()
    let fileID = UUID()
    let baseline = ProcessedRenderKey(
        datasetRevision: revision,
        fileID: fileID,
        configuration: automaticConfiguration.processedConfiguration
    )

    let changedConfigurations = [
        configuration(channel: "Current").processedConfiguration,
        configuration(direction: .bwd).processedConfiguration,
        configuration(processing: .raw).processedConfiguration,
    ]
    for changed in changedConfigurations {
        #expect(
            baseline != ProcessedRenderKey(
                datasetRevision: revision,
                fileID: fileID,
                configuration: changed
            )
        )
    }
    #expect(
        baseline != ProcessedRenderKey(
            datasetRevision: revision,
            fileID: UUID(),
            configuration: automaticConfiguration.processedConfiguration
        )
    )
}

@Test
func onlyNewestOfOneHundredHistogramRequestsIsAccepted() throws {
    let fileID = UUID()
    var gate = HistogramRequestGate<UUID>(datasetRevision: UUID())
    var requests: [HistogramRequestIdentity<UUID>] = []
    var configurations: [SelectedRenderConfiguration] = []

    for index in 0..<100 {
        let current = configuration(histogramBins: 64 + index)
        configurations.append(current)
        requests.append(
            gate.begin(fileID: fileID, configuration: current)
        )
    }

    let newestRequest = try #require(requests.last)
    let newestConfiguration = try #require(configurations.last)
    for request in requests.dropLast() {
        #expect(
            !gate.accepts(
                request,
                currentFileID: fileID,
                currentConfiguration: newestConfiguration
            )
        )
    }
    #expect(
        gate.accepts(
            newestRequest,
            currentFileID: fileID,
            currentConfiguration: newestConfiguration
        )
    )
}

@Test
func histogramIdentityIgnoresImageOnlyChanges() {
    let fileID = UUID()
    var gate = HistogramRequestGate<UUID>()
    let request = gate.begin(
        fileID: fileID,
        configuration: automaticConfiguration
    )
    let displayChanged = configuration(
        palette: .gray,
        invert: true,
        scale: .locked(min: 0, max: 1)
    )

    #expect(
        gate.accepts(
            request,
            currentFileID: fileID,
            currentConfiguration: displayChanged
        )
    )
}
