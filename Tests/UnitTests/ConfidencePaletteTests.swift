import Testing
import Render

@Test func paletteIsTotalOverEveryRawValue() {
    for value in UInt8.min...UInt8.max {
        #expect(ConfidencePalette.table.contains(ConfidencePalette.color(for: value)))
    }
}

@Test func documentedLevelsMapInSensorOrder() {
    #expect(ConfidencePalette.color(for: 0) == ConfidencePalette.low)
    #expect(ConfidencePalette.color(for: 1) == ConfidencePalette.medium)
    #expect(ConfidencePalette.color(for: 2) == ConfidencePalette.high)
}

@Test func everyUndocumentedValueGetsTheAlarmColor() {
    for value in UInt8(3)...UInt8.max {
        #expect(ConfidencePalette.color(for: value) == ConfidencePalette.outOfDomain)
    }
}

/// Distinctness is the palette's one job; four colors that collide would
/// make two confidence levels indistinguishable by construction.
@Test func theFourColorsAreDistinct() {
    #expect(Set(ConfidencePalette.table).count == 4)
}

@Test func theTableAndTheFunctionAgree() {
    for value in UInt8.min...UInt8.max {
        #expect(ConfidencePalette.table[Int(min(value, 3))] == ConfidencePalette.color(for: value))
    }
}
