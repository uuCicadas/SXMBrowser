import Foundation

public struct ScaleBar:
    Equatable,
    Sendable
{
    public static let targetVisibleFraction = 0.25
    public static let preferredMinimumScreenLengthPoints = 48.0
    public static let maximumScreenLengthPoints = 180.0

    public let physicalLengthMeters: Double
    public let screenLengthPoints: Double
    public let label: String

    private init(
        physicalLengthMeters: Double,
        screenLengthPoints: Double,
        label: String
    ) {
        self.physicalLengthMeters = physicalLengthMeters
        self.screenLengthPoints = screenLengthPoints
        self.label = label
    }

    public static func resolve(
        scanRangeX: Double,
        sourcePixelWidth: Int,
        viewerTransform: ViewerTransform,
        availableWidth: Double
    ) -> ScaleBar? {
        guard scanRangeX.isFinite,
              scanRangeX > 0,
              sourcePixelWidth > 0,
              viewerTransform.imageSize.isUsable,
              viewerTransform.viewportSize.isUsable,
              viewerTransform.scale.isFinite,
              viewerTransform.scale > 0,
              availableWidth.isFinite,
              availableWidth > 0 else {
            return nil
        }

        let scaledImageWidth =
            Double(sourcePixelWidth) * viewerTransform.scale
        guard scaledImageWidth.isFinite,
              scaledImageWidth > 0 else {
            return nil
        }
        let visibleImageSpan = min(
            scaledImageWidth,
            availableWidth,
            viewerTransform.viewportSize.width
        )
        guard visibleImageSpan.isFinite,
              visibleImageSpan > 0 else {
            return nil
        }

        let pointsPerMeter = scaledImageWidth / scanRangeX
        guard pointsPerMeter.isFinite,
              pointsPerMeter > 0 else {
            return nil
        }
        let maximumLength = min(
            maximumScreenLengthPoints,
            visibleImageSpan
        )
        let preferredMinimum =
            visibleImageSpan
                >= preferredMinimumScreenLengthPoints
            ? preferredMinimumScreenLengthPoints
            : 0
        let targetLength = min(
            maximumLength,
            max(
                preferredMinimum,
                visibleImageSpan * targetVisibleFraction
            )
        )
        let targetPhysicalLength =
            targetLength / pointsPerMeter
        guard targetPhysicalLength.isFinite,
              targetPhysicalLength > 0 else {
            return nil
        }

        let candidates = niceLengths(
            around: targetPhysicalLength
        ).compactMap { physicalLength -> Candidate? in
            let screenLength =
                physicalLength * pointsPerMeter
            guard screenLength.isFinite,
                  screenLength > 0,
                  screenLength
                    <= maximumLength
                        + comparisonTolerance(
                            for: maximumLength
                        ) else {
                return nil
            }
            return Candidate(
                physicalLength: physicalLength,
                screenLength: screenLength
            )
        }
        guard !candidates.isEmpty else { return nil }

        let preferredCandidates = candidates.filter {
            $0.screenLength
                + comparisonTolerance(
                    for: preferredMinimum
                )
                >= preferredMinimum
        }
        let eligibleCandidates =
            preferredCandidates.isEmpty
            ? candidates
            : preferredCandidates
        guard let selected = eligibleCandidates.min(
            by: {
                isPreferred(
                    $0,
                    over: $1,
                    targetScreenLength: targetLength
                )
            }
        ) else {
            return nil
        }

        return ScaleBar(
            physicalLengthMeters:
                selected.physicalLength,
            screenLengthPoints:
                selected.screenLength,
            label: siLabel(
                for: selected.physicalLength
            )
        )
    }

    private struct Candidate {
        let physicalLength: Double
        let screenLength: Double
    }

    private static func niceLengths(
        around target: Double
    ) -> [Double] {
        let logarithm = log10(target)
        guard logarithm.isFinite else { return [] }
        let centerExponent = floor(logarithm)
        var candidates: [Double] = []
        candidates.reserveCapacity(27)

        for offset in -4...4 {
            let power = pow(
                10,
                centerExponent + Double(offset)
            )
            guard power.isFinite, power > 0 else {
                continue
            }
            for multiplier in [1.0, 2.0, 5.0] {
                let length = multiplier * power
                if length.isFinite, length > 0 {
                    candidates.append(length)
                }
            }
        }
        return candidates
    }

    private static func isPreferred(
        _ lhs: Candidate,
        over rhs: Candidate,
        targetScreenLength: Double
    ) -> Bool {
        let lhsDistance = abs(
            lhs.screenLength - targetScreenLength
        )
        let rhsDistance = abs(
            rhs.screenLength - targetScreenLength
        )
        let tolerance = comparisonTolerance(
            for: targetScreenLength
        )
        if abs(lhsDistance - rhsDistance) <= tolerance {
            return lhs.physicalLength
                > rhs.physicalLength
        }
        return lhsDistance < rhsDistance
    }

    private static func comparisonTolerance(
        for value: Double
    ) -> Double {
        max(1, abs(value))
            * Double.ulpOfOne
            * 32
    }

    private static func siLabel(
        for meters: Double
    ) -> String {
        let prefixes: [(exponent: Int, symbol: String)] = [
            (30, "Q"),
            (27, "R"),
            (24, "Y"),
            (21, "Z"),
            (18, "E"),
            (15, "P"),
            (12, "T"),
            (9, "G"),
            (6, "M"),
            (3, "k"),
            (0, ""),
            (-3, "m"),
            (-6, "µ"),
            (-9, "n"),
            (-12, "p"),
            (-15, "f"),
            (-18, "a"),
            (-21, "z"),
            (-24, "y"),
            (-27, "r"),
            (-30, "q"),
        ]
        let logarithm = log10(meters)
        let engineeringExponent =
            Int(floor(logarithm / 3)) * 3
        let prefix =
            prefixes.first {
                $0.exponent <= engineeringExponent
            }
            ?? prefixes[prefixes.count - 1]
        let divisor = pow(
            10,
            Double(prefix.exponent)
        )
        let value = meters / divisor
        let rounded = value.rounded()
        let tolerance =
            max(1, abs(value))
            * Double.ulpOfOne
            * 64
        let valueText: String
        if rounded.isFinite,
           abs(value - rounded) <= tolerance,
           rounded >= Double(Int.min),
           rounded <= Double(Int.max) {
            valueText = String(Int(rounded))
        } else {
            valueText = String(
                format: "%.3g",
                locale: Locale(identifier: "en_US_POSIX"),
                value
            )
        }
        return "\(valueText) \(prefix.symbol)m"
    }
}
