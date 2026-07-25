import Foundation
import SXMBrowserCore

public struct SingleSpectroscopyState: Equatable, Sendable {
    public static let defaultHeight = 260.0
    public static let heightRange = 180.0...420.0

    public private(set) var isExpanded: Bool
    public private(set) var height: Double
    public private(set) var activeGroupID: String?
    public private(set) var focusedSpectrumID: SpectroscopyFile.ID?

    public init(
        isExpanded: Bool = true,
        height: Double = Self.defaultHeight,
        activeGroupID: String? = nil,
        focusedSpectrumID: SpectroscopyFile.ID? = nil
    ) {
        self.isExpanded = isExpanded
        self.height = Self.clampedHeight(height)
        self.activeGroupID = activeGroupID
        self.focusedSpectrumID = focusedSpectrumID
    }

    public mutating func setExpanded(_ value: Bool) {
        isExpanded = value
    }

    public mutating func setHeight(_ value: Double) {
        guard value.isFinite else { return }
        height = Self.clampedHeight(value)
    }

    public mutating func activateGroup(_ id: String?) {
        guard activeGroupID != id else { return }
        activeGroupID = id
        focusedSpectrumID = nil
    }

    public mutating func focusSpectrum(
        _ id: SpectroscopyFile.ID?
    ) {
        focusedSpectrumID = id
    }

    public mutating func reconcile(
        with groups: [PresentedSpectroscopyGroup]
    ) {
        guard !groups.isEmpty else {
            activeGroupID = nil
            focusedSpectrumID = nil
            return
        }

        let retainedGroup = groups.first {
            $0.id == activeGroupID
        }
        let activeGroup = retainedGroup ?? groups[0]
        let retainedActiveGroup = retainedGroup != nil
        activeGroupID = activeGroup.id

        guard !activeGroup.visibleSpectra.isEmpty else {
            focusedSpectrumID = nil
            return
        }

        if retainedActiveGroup,
           let focusedSpectrumID,
           activeGroup.visibleSpectra.contains(where: {
               $0.id == focusedSpectrumID
           }) {
            return
        }

        if retainedActiveGroup,
           let focusedSpectrumID,
           let focusedIndex = activeGroup.allSpectra.firstIndex(
               where: { $0.id == focusedSpectrumID }
           ) {
            let visibleIDs = Set(
                activeGroup.visibleSpectra.map(\.id)
            )
            if let next = activeGroup.allSpectra[
                activeGroup.allSpectra.index(
                    after: focusedIndex
                )...
            ].first(where: { visibleIDs.contains($0.id) }) {
                self.focusedSpectrumID = next.id
                return
            }
            if let previous = activeGroup.allSpectra[
                ..<focusedIndex
            ].last(where: { visibleIDs.contains($0.id) }) {
                self.focusedSpectrumID = previous.id
                return
            }
        }

        focusedSpectrumID = activeGroup.visibleSpectra.first?.id
    }

    public static func clampedHeight(_ value: Double) -> Double {
        guard value.isFinite else { return defaultHeight }
        return min(
            heightRange.upperBound,
            max(heightRange.lowerBound, value)
        )
    }

    public static func resizedHeight(
        startingAt height: Double,
        verticalTranslation: Double
    ) -> Double {
        clampedHeight(height - verticalTranslation)
    }
}
