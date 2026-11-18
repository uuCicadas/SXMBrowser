import Testing
@testable import SXMBrowserAppCore

@Test
func scientificPlotTicksUsesCleanNiceStepsAndFormatsCompactly() {
    let unitTicks = ScientificPlotTicks.ticks(min: 0.0, max: 1.0, targetCount: 5)
    #expect(unitTicks.count >= 3 && unitTicks.count <= 7)
    #expect(unitTicks.first?.value == 0.0)
    #expect(unitTicks.last?.value == 1.0)
    #expect(unitTicks.allSatisfy { $0.fraction >= 0.0 && $0.fraction <= 1.0 })

    let symmetricTicks = ScientificPlotTicks.ticks(min: -1.4, max: 1.4, targetCount: 5)
    #expect(symmetricTicks.contains { $0.value == 0.0 && $0.label == "0" })
    #expect(symmetricTicks.allSatisfy { $0.fraction >= 0.0 && $0.fraction <= 1.0 })

    let scientificTicks = ScientificPlotTicks.ticks(min: -2.5e-10, max: 2.5e-10, targetCount: 5)
    #expect(scientificTicks.count >= 3)
    #expect(scientificTicks.contains { $0.label == "0" })
    #expect(scientificTicks.contains { $0.label.contains("e-10") })
}

@Test
func scientificPlotTicksHandlesDegenerateAndNonFiniteRanges() {
    #expect(ScientificPlotTicks.ticks(min: .nan, max: 1.0).isEmpty)
    #expect(ScientificPlotTicks.ticks(min: 2.0, max: 1.0).isEmpty)

    let flat = ScientificPlotTicks.ticks(min: 3.25, max: 3.25, targetCount: 5)
    #expect(flat.count == 1)
    #expect(flat[0].fraction == 0.5)
    #expect(flat[0].label == "3.25")
}
