import Foundation

public struct PaletteStop: Codable, Equatable, Sendable {
    public let position: Double
    public let r: Double
    public let g: Double
    public let b: Double

    public init(_ position: Double, _ r: Double, _ g: Double, _ b: Double) {
        self.position = position
        self.r = r
        self.g = g
        self.b = b
    }
}

enum PaletteCatalogError: LocalizedError, Equatable, Sendable {
    case decodingFailed
    case unsupportedSchemaVersion(Int)
    case unknownPalette(String)
    case duplicatePalette(PaletteName)
    case missingPalettes([PaletteName])
    case insufficientStops(PaletteName)
    case nonFiniteStop(PaletteName, index: Int)
    case outOfRangeStop(PaletteName, index: Int)
    case unorderedStops(PaletteName, index: Int)
    case incompleteRange(PaletteName)

    var errorDescription: String? {
        switch self {
        case .decodingFailed:
            "The embedded palette catalog could not be decoded."
        case .unsupportedSchemaVersion(let version):
            "Palette catalog schema version \(version) is not supported."
        case .unknownPalette(let name):
            "Palette catalog contains unknown palette “\(name)”."
        case .duplicatePalette(let palette):
            "Palette catalog contains duplicate palette “\(palette.rawValue)”."
        case .missingPalettes(let palettes):
            "Palette catalog is missing: \(palettes.map(\.rawValue).joined(separator: ", "))."
        case .insufficientStops(let palette):
            "Palette “\(palette.rawValue)” must contain at least two stops."
        case .nonFiniteStop(let palette, let index):
            "Palette “\(palette.rawValue)” stop \(index) contains a non-finite value."
        case .outOfRangeStop(let palette, let index):
            "Palette “\(palette.rawValue)” stop \(index) is outside the 0...1 range."
        case .unorderedStops(let palette, let index):
            "Palette “\(palette.rawValue)” stop \(index) is not strictly increasing."
        case .incompleteRange(let palette):
            "Palette “\(palette.rawValue)” must span exactly 0...1."
        }
    }
}

public struct PaletteLookup: Sendable {
    public let stops: [PaletteStop]
    public let isUniformUnitGrid: Bool
    private let segmentCount: Int
    private let segmentScale: Double

    public init(stops: [PaletteStop]) {
        self.stops = stops
        let count = stops.count - 1
        self.segmentCount = max(0, count)
        self.segmentScale = Double(max(1, count))
        if count >= 1, (count & (count - 1)) == 0 {
            let scale = Double(count)
            self.isUniformUnitGrid = stops.enumerated().allSatisfy { index, stop in
                stop.position == Double(index) / scale
            }
        } else {
            self.isUniformUnitGrid = false
        }
    }

    @inline(__always)
    public func color(at value: Double) -> (r: Double, g: Double, b: Double) {
        guard let first = stops.first, let last = stops.last else {
            return (value, value, value)
        }
        if value <= first.position { return (first.r, first.g, first.b) }
        if value >= last.position { return (last.r, last.g, last.b) }
        guard value.isFinite else { return (last.r, last.g, last.b) }

        if isUniformUnitGrid {
            let index = min(segmentCount - 1, max(0, Int(value * segmentScale)))
            let a = stops[index]
            let b = stops[index + 1]
            let t = (value - a.position) * segmentScale
            return (
                a.r * (1 - t) + b.r * t,
                a.g * (1 - t) + b.g * t,
                a.b * (1 - t) + b.b * t
            )
        }

        // Binary search fallback for arbitrary non-uniform stop spacing.
        var lower = 1
        var upper = stops.count - 1
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if value <= stops[middle].position {
                upper = middle
            } else {
                lower = middle + 1
            }
        }
        let a = stops[lower - 1]
        let b = stops[lower]
        let span = max(1e-12, b.position - a.position)
        let t = (value - a.position) / span
        return (
            a.r * (1 - t) + b.r * t,
            a.g * (1 - t) + b.g * t,
            a.b * (1 - t) + b.b * t
        )
    }
}

public struct PaletteStore: Sendable {
    public static let shared: PaletteStore = {
        do {
            return try PaletteStore(data: Data(PackageResources.palettes_json))
        } catch {
            preconditionFailure("Invalid embedded palette catalog: \(error.localizedDescription)")
        }
    }()

    private let lookupsByPalette: [PaletteName: PaletteLookup]

    init(data: Data) throws {
        let resource: PaletteCatalogResource
        do {
            resource = try JSONDecoder().decode(PaletteCatalogResource.self, from: data)
        } catch {
            throw PaletteCatalogError.decodingFailed
        }

        guard resource.schemaVersion == 1 else {
            throw PaletteCatalogError.unsupportedSchemaVersion(resource.schemaVersion)
        }

        var catalog: [PaletteName: PaletteLookup] = [:]
        catalog.reserveCapacity(PaletteName.allCases.count)

        for entry in resource.palettes {
            guard let palette = PaletteName(rawValue: entry.name) else {
                throw PaletteCatalogError.unknownPalette(entry.name)
            }
            guard catalog[palette] == nil else {
                throw PaletteCatalogError.duplicatePalette(palette)
            }
            try Self.validate(entry.stops, for: palette)
            catalog[palette] = PaletteLookup(stops: entry.stops)
        }

        let missing = PaletteName.allCases.filter { catalog[$0] == nil }
        guard missing.isEmpty else {
            throw PaletteCatalogError.missingPalettes(missing)
        }

        lookupsByPalette = catalog
    }

    public func lookup(for palette: PaletteName) -> PaletteLookup {
        guard let lookup = lookupsByPalette[palette] else {
            preconditionFailure("Validated palette catalog is missing \(palette.rawValue).")
        }
        return lookup
    }

    public func stops(for palette: PaletteName) -> [PaletteStop] {
        lookup(for: palette).stops
    }

    private static func validate(_ stops: [PaletteStop], for palette: PaletteName) throws {
        guard stops.count >= 2 else {
            throw PaletteCatalogError.insufficientStops(palette)
        }

        for (index, stop) in stops.enumerated() {
            let values = [stop.position, stop.r, stop.g, stop.b]
            guard values.allSatisfy(\.isFinite) else {
                throw PaletteCatalogError.nonFiniteStop(palette, index: index)
            }
            guard values.allSatisfy({ (0...1).contains($0) }) else {
                throw PaletteCatalogError.outOfRangeStop(palette, index: index)
            }
            if index > 0, stop.position <= stops[index - 1].position {
                throw PaletteCatalogError.unorderedStops(palette, index: index)
            }
        }

        guard stops.first?.position == 0, stops.last?.position == 1 else {
            throw PaletteCatalogError.incompleteRange(palette)
        }
    }
}

private struct PaletteCatalogResource: Decodable {
    let schemaVersion: Int
    let palettes: [PaletteResource]
}

private struct PaletteResource: Decodable {
    let name: String
    let stops: [PaletteStop]
}
