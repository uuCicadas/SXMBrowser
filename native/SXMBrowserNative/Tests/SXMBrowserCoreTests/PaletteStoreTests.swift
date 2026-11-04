import CryptoKit
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
        store.stops(for: .gray) == [
            PaletteStop(0.00, 0.000, 0.000, 0.000),
            PaletteStop(1.00, 1.000, 1.000, 1.000),
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
func selectedSTMPalettesMatchApprovedPreviews() {
    // Fingerprints cover every Double in the selected preview's stops, in order:
    // position, r, g, b, encoded as little-endian IEEE 754 values.
    // Approved refinement: design/stm-palette-refinement/further-five-percent/candidate-blue-violet.json
    // B4: design/stm-palette-preview/saved/B4-deep-blue/palette.json
    let approvedFingerprints: [(PaletteName, String)] = [
        (.blueViolet, "e5e5c9cedc4ccbe03466a04129edd1b4e5128d85ca98f4b1ccb6c52347240c0e"),
        (.deepBlue, "a48576bd35d240d1b2cbc3b4c4ce6e31c690dbe1b963a77762a7770bbe4b1805"),
    ]

    for (palette, expected) in approvedFingerprints {
        let stops = PaletteStore.shared.stops(for: palette)
        #expect(stops.count == 257)
        var data = Data()
        for stop in stops {
            for value in [stop.position, stop.r, stop.g, stop.b] {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }
        let fingerprint = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(fingerprint == expected)
    }
}

@Test
func rendererUsesBundledPaletteAndPreservesInversion() {
    let matrix = Matrix(width: 3, height: 1, values: [0, 0.5, 1])
    let normal = SXMRenderer.colorize(
        matrix: matrix,
        palette: .gray,
        vmin: 0,
        vmax: 1,
        invert: false
    )
    let inverted = SXMRenderer.colorize(
        matrix: matrix,
        palette: .gray,
        vmin: 0,
        vmax: 1,
        invert: true
    )

    #expect(
        normal == [
            0, 0, 0, 255,
            128, 128, 128, 255,
            255, 255, 255, 255,
        ]
    )
    #expect(
        inverted == [
            255, 255, 255, 255,
            128, 128, 128, 255,
            0, 0, 0, 255,
        ]
    )
}

@Test
func paletteLookupMatchesLinearReferenceAtStopsAndBetweenThem() {
    for palette in PaletteName.allCases {
        let stops = PaletteStore.shared.stops(for: palette)
        var values: [Float] = [-0.25, 0, 1, 1.25, .nan, .infinity]
        for stop in stops {
            let value = Float(stop.position)
            values.append(contentsOf: [value.nextDown, value, value.nextUp])
        }
        for (a, b) in zip(stops, stops.dropFirst()) {
            values.append(Float((a.position + b.position) / 2))
        }
        let matrix = Matrix(width: values.count, height: 1, values: values)

        for invert in [false, true] {
            let actual = SXMRenderer.colorize(
                matrix: matrix,
                palette: palette,
                vmin: 0,
                vmax: 1,
                invert: invert
            )
            let expected = values.flatMap { value -> [UInt8] in
                let normalized = value.isFinite ? min(1, max(0, Double(value))) : 0
                return referenceLinearRGBA(
                    stops: stops,
                    at: invert ? 1 - normalized : normalized
                )
            }
            #expect(actual == expected, "\(palette.rawValue), invert: \(invert)")
        }
    }
}

// Retain an independent linear-search reference for the binary-search renderer.
private func referenceLinearRGBA(stops: [PaletteStop], at value: Double) -> [UInt8] {
    func rgba(_ r: Double, _ g: Double, _ b: Double) -> [UInt8] {
        [r, g, b].map { UInt8(min(255, max(0, round($0 * 255)))) } + [255]
    }

    let first = stops[0]
    let last = stops[stops.count - 1]
    if value <= first.position { return rgba(first.r, first.g, first.b) }
    if value >= last.position { return rgba(last.r, last.g, last.b) }
    for (a, b) in zip(stops, stops.dropFirst()) {
        if value >= a.position && value <= b.position {
            let t = (value - a.position) / max(1e-12, b.position - a.position)
            return rgba(
                a.r * (1 - t) + b.r * t,
                a.g * (1 - t) + b.g * t,
                a.b * (1 - t) + b.b * t
            )
        }
    }
    return rgba(last.r, last.g, last.b)
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
    missingEntries.removeAll { ($0["name"] as? String) == PaletteName.flame.rawValue }
    missing["palettes"] = missingEntries
    #expect(
        capturedPaletteError(missing)
            == .missingPalettes([.flame])
    )

    var duplicate = completePaletteCatalog()
    var duplicateEntries = try #require(duplicate["palettes"] as? [[String: Any]])
    let grayEntry = try #require(duplicateEntries.first {
        ($0["name"] as? String) == PaletteName.gray.rawValue
    })
    duplicateEntries.append(grayEntry)
    duplicate["palettes"] = duplicateEntries
    #expect(
        capturedPaletteError(duplicate)
            == .duplicatePalette(.gray)
    )

    var unordered = completePaletteCatalog()
    var unorderedEntries = try #require(unordered["palettes"] as? [[String: Any]])
    let unorderedGrayIndex = try #require(unorderedEntries.firstIndex {
        ($0["name"] as? String) == PaletteName.gray.rawValue
    })
    unorderedEntries[unorderedGrayIndex]["stops"] = [
        stop(position: 0, r: 0, g: 0, b: 0),
        stop(position: 0, r: 1, g: 1, b: 1),
        stop(position: 1, r: 1, g: 1, b: 1),
    ]
    unordered["palettes"] = unorderedEntries
    #expect(
        capturedPaletteError(unordered)
            == .unorderedStops(.gray, index: 1)
    )

    var outOfRange = completePaletteCatalog()
    var rangeEntries = try #require(outOfRange["palettes"] as? [[String: Any]])
    let rangeGrayIndex = try #require(rangeEntries.firstIndex {
        ($0["name"] as? String) == PaletteName.gray.rawValue
    })
    rangeEntries[rangeGrayIndex]["stops"] = [
        stop(position: 0, r: 0, g: 0, b: 0),
        stop(position: 1, r: 1.01, g: 1, b: 1),
    ]
    outOfRange["palettes"] = rangeEntries
    #expect(
        capturedPaletteError(outOfRange)
            == .outOfRangeStop(.gray, index: 1)
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
