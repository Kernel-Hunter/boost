import Testing
@testable import BoostKit

/// The header's job is to stop people "fixing" a Mac that is fine. Cached
/// memory is available memory, and swap — not the used figure — is the number
/// that means something is actually wrong.
@Suite("Memory reading")
struct MemoryTests {

    private func stats(usedGB: Double, totalGB: Double = 16, swapGB: Double = 0) -> MemStats {
        var m = MemStats()
        m.total = UInt64(totalGB * 1_073_741_824)
        m.used = UInt64(usedGB * 1_073_741_824)
        m.swapUsed = UInt64(swapGB * 1_073_741_824)
        return m
    }

    @Test("An idle Mac reads as fine")
    func idleIsEasy() {
        #expect(stats(usedGB: 6).level == .easy)
    }

    @Test("Any swap at all is worth noticing, however much RAM is free")
    func anySwapIsNotEasy() {
        // 4 GB of 16 used is nothing, but the machine is paging.
        #expect(stats(usedGB: 4, swapGB: 0.5).level != .easy)
    }

    @Test("Heavy swap is the tight case, and it is swap that decides it")
    func heavySwapIsTight() {
        #expect(stats(usedGB: 4, swapGB: 2).level == .tight)
    }

    @Test("Nearly full RAM is tight even without swap")
    func fullRAMIsTight() {
        #expect(stats(usedGB: 15).level == .tight)
    }

    @Test("Pressure is a fraction and never exceeds one")
    func pressureIsBounded() {
        #expect(stats(usedGB: 8).pressure == 0.5)
        #expect(stats(usedGB: 32).pressure == 1.0)     // more used than installed: clamp
    }

    @Test("Pressure on a zero-total machine does not divide by zero")
    func pressureHandlesZeroTotal() {
        #expect(MemStats().pressure == 0)
    }
}

@Suite("Byte formatting")
struct ByteFormatTests {

    @Test("Scales to the unit a person would use", arguments: [
        (UInt64(512), "512 B"),
        (UInt64(1_048_576), "1 MB"),
        (UInt64(157_286_400), "150 MB"),
        (UInt64(1_073_741_824), "1.00 GB"),
        (UInt64(3_435_973_836), "3.20 GB"),
    ])
    func formats(bytes: UInt64, expected: String) {
        #expect(fmtBytes(bytes) == expected)
    }

    @Test("Zero reads as zero, not as a blank or a crash")
    func formatsZero() {
        #expect(fmtBytes(0) == "0 B")
    }
}
