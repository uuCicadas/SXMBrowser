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
    #expect(PaletteName.allCases == [.blueViolet, .duskViolet, .ember, .gray])
    #expect(PaletteName(rawValue: "flame") == nil)
    #expect(PaletteName(rawValue: "deepBlue") == nil)
}

@Test
func selectedSTMPalettesMatchApprovedPreviews() {
    // Fingerprints cover every Double in the selected preview's stops, in order:
    // position, r, g, b, encoded as little-endian IEEE 754 values.
    // E Ink Violet: design/palette-survey-2026/palettes/E-ink-violet-blueViolet.json
    // H Dusk Violet: design/palette-survey-2026/palettes/H-dusk-violet.json
    // J Ember: design/palette-survey-2026/palettes/J-ember.json
    let approvedFingerprints: [(PaletteName, String)] = [
        (.blueViolet, "eef29bb173702cd500a5668b6de08ace1f332bb0e0c6c0cde0c0f47c7c893528"),
        (.duskViolet, "5c48fafdc3d046448bb10d0388078288382730550bb655bb69419b0ee382dd08"),
        (.ember, "b06bafb7097b0b0cfb6086354dbc40dacc8c9f58fcfa172362e560ff1a35be8d"),
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

@Test
func bundledPalettesUseUniformGridFastLookupAndNonUniformFallsBack() {
    for palette in PaletteName.allCases {
        let lookup = PaletteStore.shared.lookup(for: palette)
        #expect(lookup.isUniformUnitGrid, "Expected uniform grid lookup for \(palette.rawValue)")
    }

    let nonUniformStops = [
        PaletteStop(0.0, 0.0, 0.0, 0.0),
        PaletteStop(0.3, 0.6, 0.3, 0.9),
        PaletteStop(1.0, 1.0, 1.0, 0.2),
    ]
    let nonUniformLookup = PaletteLookup(stops: nonUniformStops)
    #expect(!nonUniformLookup.isUniformUnitGrid)

    let midLow = nonUniformLookup.color(at: 0.15)
    #expect(abs(midLow.r - 0.3) < 1e-12)
    #expect(abs(midLow.g - 0.15) < 1e-12)
    #expect(abs(midLow.b - 0.45) < 1e-12)

    let midHigh = nonUniformLookup.color(at: 0.65)
    #expect(abs(midHigh.r - 0.8) < 1e-12)
    #expect(abs(midHigh.g - 0.65) < 1e-12)
    #expect(abs(midHigh.b - 0.55) < 1e-12)

    let nonPowerOfTwoStops = [
        PaletteStop(0.0, 0.0, 0.0, 0.0),
        PaletteStop(1.0 / 3.0, 0.3, 0.3, 0.3),
        PaletteStop(2.0 / 3.0, 0.6, 0.6, 0.6),
        PaletteStop(1.0, 1.0, 1.0, 1.0),
    ]
    let nonPowerLookup = PaletteLookup(stops: nonPowerOfTwoStops)
    #expect(!nonPowerLookup.isUniformUnitGrid)
    let sample = nonPowerLookup.color(at: 0.5)
    #expect(abs(sample.r - 0.45) < 1e-12)
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
    missingEntries.removeAll { ($0["name"] as? String) == PaletteName.ember.rawValue }
    missing["palettes"] = missingEntries
    #expect(
        capturedPaletteError(missing)
            == .missingPalettes([.ember])
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
