import Foundation
import Testing
@testable import SXMBrowserAppCore
import SXMBrowserCore

private let automaticConfiguration = SelectedRenderConfiguration(
    channel: "Z",
    direction: .fwd,
    processing: .lineLinear,
    palette: .gwyddionNet,
    invert: false,
    histogramBins: 256,
    scale: .automatic
)

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
