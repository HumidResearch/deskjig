import Testing
@testable import DeskJigShared

struct ProcessIDIndexTests {
    @Test("PID index builder ignores invalid PIDs and deduplicates repeated PIDs deterministically")
    func buildIgnoresInvalidAndDuplicatePIDs() {
        let result = ProcessIDIndexBuilder.build([
            .init(processID: -1, sortKey: "invalid", value: "ignored-invalid"),
            .init(processID: 42, sortKey: "z-second", value: "second"),
            .init(processID: 42, sortKey: "a-first", value: "first"),
            .init(processID: 7, sortKey: "only", value: "only")
        ])

        #expect(result.invalidProcessIDCount == 1)
        #expect(result.duplicateProcessIDs == [42])
        #expect(result.valuesByProcessID[42] == "first")
        #expect(result.valuesByProcessID[7] == "only")
        #expect(result.valuesByProcessID.count == 2)
    }
}
