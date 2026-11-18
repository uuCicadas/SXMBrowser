import SXMBrowserCore

public enum SpectrumRowModifier: Equatable, Sendable {
    case plain
    case command
    case shift
}

public struct SpectrumRowInteractionPlan:
    Equatable,
    Sendable
{
    public let associationIDs: Set<SpectroscopyFile.ID>
    public let shouldFocusClickedSpectrum: Bool

    public init(
        existingAssociationIDs: Set<SpectroscopyFile.ID>,
        clickedID: SpectroscopyFile.ID,
        modifier: SpectrumRowModifier,
        clickedIsVisible: Bool
    ) {
        switch modifier {
        case .plain:
            associationIDs = [clickedID]
            shouldFocusClickedSpectrum = clickedIsVisible
        case .command, .shift:
            var updated = existingAssociationIDs
            if updated.contains(clickedID) {
                updated.remove(clickedID)
            } else {
                updated.insert(clickedID)
            }
            associationIDs = updated
            shouldFocusClickedSpectrum = false
        }
    }
}

public struct SpectrumFocusPlan: Equatable, Sendable {
    public let groupID: String
    public let spectrumID: SpectroscopyFile.ID

    public static func resolve(
        spectrumID: SpectroscopyFile.ID,
        groups: [PresentedSpectroscopyGroup]
    ) -> Self? {
        guard let group = groups.first(where: {
            $0.allSpectra.contains(where: {
                $0.id == spectrumID
            })
        }),
              group.visibleSpectra.contains(where: {
                  $0.id == spectrumID
              }) else {
            return nil
        }
        return Self(
            groupID: group.id,
            spectrumID: spectrumID
        )
    }
}
