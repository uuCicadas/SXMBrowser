import Foundation

public struct ScientificAxisTick: Equatable, Sendable {
    public let value: Double
    public let fraction: Double
    public let label: String

    public init(value: Double, fraction: Double, label: String) {
        self.value = value
        self.fraction = fraction
        self.label = label
    }
}

public enum ScientificPlotTicks {
    private static let niceMantissas: [Double] = [1.0, 2.0, 5.0]

    public static func ticks(
        min: Double,
        max: Double,
        targetCount: Int = 5
    ) -> [ScientificAxisTick] {
        guard min.isFinite, max.isFinite, max >= min else { return [] }

        let desiredCount = Swift.max(2, Swift.min(12, targetCount))
        let span = max - min
        let scaleFloor = Swift.max(1.0, Swift.max(abs(min), abs(max)))
        guard span > scaleFloor * 1e-12 else {
            return [
                ScientificAxisTick(
                    value: min,
                    fraction: 0.5,
                    label: formatTickValue(min, step: nil)
                )
            ]
        }

        let idealStep = span / Double(desiredCount - 1)
        let baseExponent = Int(floor(log10(idealStep)))
        var bestStep: Double?
        var bestValues: [Double] = []
        var bestScore = Double.greatestFiniteMagnitude

        for expOffset in -1...2 {
            let power = pow(10.0, Double(baseExponent + expOffset))
            for mantissa in niceMantissas {
                let candidateStep = mantissa * power
                guard candidateStep.isFinite, candidateStep > 0 else { continue }
                let values = generateValues(min: min, max: max, step: candidateStep)
                guard !values.isEmpty else { continue }

                var score = abs(Double(values.count - desiredCount))
                if values.count < 2 {
                    score += 100.0
                } else if values.count > desiredCount + 2 {
                    score += 20.0
                }
                // Tie-break slightly toward cleaner, less crowded steps.
                score += Double(values.count) * 0.01

                if score < bestScore {
                    bestScore = score
                    bestStep = candidateStep
                    bestValues = values
                }
            }
        }

        guard let step = bestStep, !bestValues.isEmpty else {
            return [
                ScientificAxisTick(value: min, fraction: 0.0, label: formatTickValue(min, step: span)),
                ScientificAxisTick(value: max, fraction: 1.0, label: formatTickValue(max, step: span))
            ]
        }

        return bestValues.map { rawValue in
            let snapped = abs(rawValue) < step * 1e-6 ? 0.0 : rawValue
            let fraction = Swift.min(1.0, Swift.max(0.0, (snapped - min) / span))
            return ScientificAxisTick(
                value: snapped,
                fraction: fraction,
                label: formatTickValue(snapped, step: step)
            )
        }
    }

    public static func formatTickValue(_ value: Double, step: Double?) -> String {
        guard value.isFinite else { return "—" }
        let zeroThreshold = Swift.max(1e-30, (step ?? abs(value)) * 1e-6)
        if value == 0 || abs(value) < zeroThreshold {
            return "0"
        }

        let magnitude = abs(value)
        if magnitude >= 1e4 || magnitude < 1e-3 {
            return formatScientific(value, step: step)
        }
        return formatFixed(value, step: step)
    }

    private static func generateValues(
        min: Double,
        max: Double,
        step: Double
    ) -> [Double] {
        let span = max - min
        let epsilon = span * 1e-9
        let startIndexDouble = ceil((min - epsilon) / step)
        let endIndexDouble = floor((max + epsilon) / step)
        guard startIndexDouble.isFinite,
              endIndexDouble.isFinite,
              abs(startIndexDouble) < 1e9,
              abs(endIndexDouble) < 1e9 else {
            return []
        }
        let startIndex = Int(startIndexDouble)
        let endIndex = Int(endIndexDouble)
        guard startIndex <= endIndex else { return [] }
        let count = endIndex - startIndex + 1
        guard count <= 32 else { return [] }

        var values: [Double] = []
        values.reserveCapacity(count)
        for index in startIndex...endIndex {
            let value = Double(index) * step
            if value >= min - epsilon && value <= max + epsilon {
                values.append(value)
            }
        }
        return values
    }

    private static func formatFixed(_ value: Double, step: Double?) -> String {
        let decimalPlaces: Int
        if let step, step > 0 && step.isFinite {
            decimalPlaces = Swift.min(6, Swift.max(0, -Int(floor(log10(step)))))
        } else {
            decimalPlaces = 3
        }

        let formatted = String(format: "%.*f", decimalPlaces, value)
        let trimmed = trimTrailingDecimalZeros(formatted)
        return trimmed == "-0" ? "0" : trimmed
    }

    private static func formatScientific(_ value: Double, step: Double?) -> String {
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)
        let exponent = Int(floor(log10(magnitude)))
        let scaled = magnitude / pow(10.0, Double(exponent))

        var fractionalDigits = 2
        if let step, step > 0, step.isFinite {
            let stepExp = Int(floor(log10(step)))
            fractionalDigits = Swift.min(4, Swift.max(0, exponent - stepExp))
        }

        var mantissaString = String(format: "%.*f", fractionalDigits, scaled)
        var adjustedExponent = exponent
        if let rounded = Double(mantissaString), rounded >= 10.0 {
            adjustedExponent += 1
            mantissaString = String(format: "%.*f", fractionalDigits, rounded / 10.0)
        }
        mantissaString = trimTrailingDecimalZeros(mantissaString)
        return "\(sign)\(mantissaString)e\(adjustedExponent)"
    }

    private static func trimTrailingDecimalZeros(_ text: String) -> String {
        guard text.contains(".") else { return text }
        var result = text
        while result.last == "0" {
            result.removeLast()
        }
        if result.last == "." {
            result.removeLast()
        }
        return result
    }
}
