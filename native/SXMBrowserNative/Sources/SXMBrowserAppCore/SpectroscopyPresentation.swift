import SXMBrowserCore

public struct PresentedSpectroscopyGroup:
    Identifiable,
    Equatable,
    Sendable
{
    public let group: SpectroscopyGroup
    public let visibleSpectra: [SpectroscopyFile]

    public init(
        group: SpectroscopyGroup,
        visibleSpectra: [SpectroscopyFile]
    ) {
        self.group = group
        self.visibleSpectra = visibleSpectra
    }

    public var id: String {
        group.id
    }

    public var allSpectra: [SpectroscopyFile] {
        group.spectra
    }

    public var shouldShowGridCard: Bool {
        !visibleSpectra.isEmpty
    }

    public var visibleCurveCountText: String {
        visibleSpectra.count == 1
            ? "1 curve"
            : "\(visibleSpectra.count) curves"
    }

    public var renderID: String {
        group.id
            + "|"
            + visibleSpectra.map { $0.id.uuidString }
                .joined(separator: ",")
    }
}

public struct SpectroscopyPresentationProjection:
    Equatable,
    Sendable
{
    public let groups: [PresentedSpectroscopyGroup]

    public init(
        groups: [SpectroscopyGroup],
        hiddenSpectrumIDs: Set<SpectroscopyFile.ID>
    ) {
        self.groups = groups.map { group in
            PresentedSpectroscopyGroup(
                group: group,
                visibleSpectra: group.spectra.filter {
                    !hiddenSpectrumIDs.contains($0.id)
                }
            )
        }
    }

    public var gridGroups: [PresentedSpectroscopyGroup] {
        groups.filter(\.shouldShowGridCard)
    }

    public var markerSpectra: [SpectroscopyFile] {
        groups.flatMap(\.visibleSpectra)
    }
}
