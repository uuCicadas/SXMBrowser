import Foundation
import Testing
@testable import SXMBrowserCore

@Test
func bundledPaletteCatalogCoversEveryPalette() {
    let store = PaletteStore.shared

    for palette in PaletteName.allCases {
        let stops = store.stops(for: palette)
        #expect(stops.count >= 2)
        #expect(stops.first?.position == 0)
        #expect(stops.last?.position == 1)
        #expect(stops.allSatisfy {
            [$0.position, $0.r, $0.g, $0.b].allSatisfy {
                $0.isFinite && (0...1).contains($0)
            }
        })
        #expect(zip(stops, stops.dropFirst()).allSatisfy { pair in
            pair.0.position < pair.1.position
        })
    }
}

@Test
func bundledPaletteCatalogUsesVersionControlledStops() {
    let store = PaletteStore.shared

    #expect(
        store.stops(for: .gwyddionNet) == [
            PaletteStop(0.00, 0.000, 0.000, 0.000),
            PaletteStop(0.18, 0.075, 0.090, 0.420),
            PaletteStop(0.36, 0.000, 0.445, 0.720),
            PaletteStop(0.54, 0.000, 0.650, 0.360),
            PaletteStop(0.72, 0.850, 0.720, 0.120),
            PaletteStop(1.00, 1.000, 1.000, 1.000),
        ]
    )
    #expect(
        store.stops(for: .gold) == [
            PaletteStop(0.00, 0.000, 0.000, 0.000),
            PaletteStop(0.35, 0.280, 0.110, 0.020),
            PaletteStop(0.72, 0.850, 0.560, 0.160),
            PaletteStop(1.00, 1.000, 0.950, 0.650),
        ]
    )
    #expect(
        store.stops(for: .flame) == [
            PaletteStop(0.000000, 0.000000, 0.000000, 0.000000),
            PaletteStop(0.007843, 0.003921, 0.006274, 0.022352),
            PaletteStop(0.101960, 0.003921, 0.082352, 0.290196),
            PaletteStop(0.200000, 0.003921, 0.341176, 0.584313),
            PaletteStop(0.337254, 0.003921, 0.996078, 0.996078),
            PaletteStop(0.666666, 0.950980, 0.003921, 0.003921),
            PaletteStop(0.682352, 0.996078, 0.050588, 0.003921),
            PaletteStop(1.000000, 0.996078, 0.996078, 0.003921),
        ]
    )
}

@Test
func rendererUsesBundledPaletteAndPreservesInversion() {
    let matrix = Matrix(width: 3, height: 1, values: [0, 0.5, 1])
    let normal = SXMRenderer.colorize(
        matrix: matrix,
        palette: .viridis,
        vmin: 0,
        vmax: 1,
        invert: false
    )
    let inverted = SXMRenderer.colorize(
        matrix: matrix,
        palette: .viridis,
        vmin: 0,
        vmax: 1,
        invert: true
    )

    #expect(
        normal == [
            68, 1, 84, 255,
            33, 145, 141, 255,
            253, 231, 37, 255,
        ]
    )
    #expect(
        inverted == [
            253, 231, 37, 255,
            33, 145, 141, 255,
            68, 1, 84, 255,
        ]
    )
}

@Test
func immutablePaletteStoreSupportsConcurrentReads() async {
    let expected = Dictionary(
        uniqueKeysWithValues: PaletteName.allCases.map {
            ($0, PaletteStore.shared.stops(for: $0))
        }
    )

    let matches = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for _ in 0..<128 {
            group.addTask {
                PaletteName.allCases.allSatisfy {
                    PaletteStore.shared.stops(for: $0) == expected[$0]
                }
            }
        }

        var results: [Bool] = []
        for await result in group {
            results.append(result)
        }
        return results
    }

    #expect(matches.count == 128)
    #expect(matches.allSatisfy { $0 })
}

@Test
func paletteCatalogRejectsStructuralAndRangeErrors() throws {
    var unsupported = completePaletteCatalog()
    unsupported["schemaVersion"] = 2
    #expect(
        capturedPaletteError(unsupported)
            == .unsupportedSchemaVersion(2)
    )

    var missing = completePaletteCatalog()
    var missingEntries = try #require(missing["palettes"] as? [[String: Any]])
    missingEntries.removeLast()
    missing["palettes"] = missingEntries
    #expect(
        capturedPaletteError(missing)
            == .missingPalettes([.flame])
    )

    var duplicate = completePaletteCatalog()
    var duplicateEntries = try #require(duplicate["palettes"] as? [[String: Any]])
    duplicateEntries.append(duplicateEntries[0])
    duplicate["palettes"] = duplicateEntries
    #expect(
        capturedPaletteError(duplicate)
            == .duplicatePalette(.gwyddionNet)
    )

    var unordered = completePaletteCatalog()
    var unorderedEntries = try #require(unordered["palettes"] as? [[String: Any]])
    unorderedEntries[0]["stops"] = [
        stop(position: 0, r: 0, g: 0, b: 0),
        stop(position: 0, r: 1, g: 1, b: 1),
        stop(position: 1, r: 1, g: 1, b: 1),
    ]
    unordered["palettes"] = unorderedEntries
    #expect(
        capturedPaletteError(unordered)
            == .unorderedStops(.gwyddionNet, index: 1)
    )

    var outOfRange = completePaletteCatalog()
    var rangeEntries = try #require(outOfRange["palettes"] as? [[String: Any]])
    rangeEntries[0]["stops"] = [
        stop(position: 0, r: 0, g: 0, b: 0),
        stop(position: 1, r: 1.01, g: 1, b: 1),
    ]
    outOfRange["palettes"] = rangeEntries
    #expect(
        capturedPaletteError(outOfRange)
            == .outOfRangeStop(.gwyddionNet, index: 1)
    )
}

private func capturedPaletteError(_ object: [String: Any]) -> PaletteCatalogError? {
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        _ = try PaletteStore(data: data)
        return nil
    } catch let error as PaletteCatalogError {
        return error
    } catch {
        Issue.record("Expected PaletteCatalogError, received \(error)")
        return nil
    }
}

private func completePaletteCatalog() -> [String: Any] {
    [
        "schemaVersion": 1,
        "palettes": PaletteName.allCases.map {
            [
                "name": $0.rawValue,
                "stops": [
                    stop(position: 0, r: 0, g: 0, b: 0),
                    stop(position: 1, r: 1, g: 1, b: 1),
                ],
            ] as [String: Any]
        },
    ]
}

private func stop(position: Double, r: Double, g: Double, b: Double) -> [String: Double] {
    [
        "position": position,
        "r": r,
        "g": g,
        "b": b,
    ]
}
