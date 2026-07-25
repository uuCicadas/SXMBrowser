public struct SpectrumRGBColor:
    Equatable,
    Hashable,
    Sendable
{
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(
        red: UInt8,
        green: UInt8,
        blue: UInt8
    ) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var normalizedRed: Double {
        Double(red) / 255
    }

    public var normalizedGreen: Double {
        Double(green) / 255
    }

    public var normalizedBlue: Double {
        Double(blue) / 255
    }
}

public enum SpectrumLinePattern:
    Int,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case solid
    case dashed
    case dotted
    case dashDot

    public var dashPattern: [Double] {
        switch self {
        case .solid:
            []
        case .dashed:
            [8, 4]
        case .dotted:
            [1, 3]
        case .dashDot:
            [8, 3, 1, 3]
        }
    }
}

public struct SpectrumVisualStyle:
    Equatable,
    Hashable,
    Sendable
{
    public static let palette: [SpectrumRGBColor] = [
        SpectrumRGBColor(red: 0x00, green: 0x72, blue: 0xB2),
        SpectrumRGBColor(red: 0xD5, green: 0x5E, blue: 0x00),
        SpectrumRGBColor(red: 0x00, green: 0x9E, blue: 0x73),
        SpectrumRGBColor(red: 0xCC, green: 0x79, blue: 0xA7),
        SpectrumRGBColor(red: 0xE6, green: 0x9F, blue: 0x00),
        SpectrumRGBColor(red: 0x56, green: 0xB4, blue: 0xE9),
        SpectrumRGBColor(red: 0x00, green: 0x00, blue: 0x00),
    ]

    public static let patterns: [SpectrumLinePattern] = [
        .solid,
        .dashed,
        .dotted,
        .dashDot,
    ]

    public static let cycleLength =
        palette.count * patterns.count

    public let cycleIndex: Int
    public let paletteIndex: Int
    public let patternIndex: Int
    public let color: SpectrumRGBColor
    public let pattern: SpectrumLinePattern

    public init(index: Int) {
        let cycleIndex = Self.euclideanModulo(
            index,
            modulus: Self.cycleLength
        )
        let paletteIndex = Self.euclideanModulo(
            index,
            modulus: Self.palette.count
        )
        let patternIndex = Self.euclideanModulo(
            index,
            modulus: Self.patterns.count
        )

        self.cycleIndex = cycleIndex
        self.paletteIndex = paletteIndex
        self.patternIndex = patternIndex
        color = Self.palette[paletteIndex]
        pattern = Self.patterns[patternIndex]
    }

    public static func resolve(
        index: Int
    ) -> SpectrumVisualStyle {
        SpectrumVisualStyle(index: index)
    }

    static func euclideanModulo(
        _ value: Int,
        modulus: Int
    ) -> Int {
        precondition(modulus > 0)
        let remainder = value % modulus
        return remainder >= 0
            ? remainder
            : remainder + modulus
    }
}
