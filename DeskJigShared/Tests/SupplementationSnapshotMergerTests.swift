//
//  SupplementationSnapshotMergerTests.swift
//  DeskJigSharedTests
//
//  Unit tests for SupplementationSnapshotMerger (#470): overlay windows must
//  replace base windows by ID without disturbing base ordering, overlay-only
//  windows are appended, and snapshot metadata always comes from the base.
//

import Testing
import Foundation
import CoreGraphics
@testable import DeskJigShared

struct SupplementationSnapshotMergerTests {

    // MARK: - Helpers

    private func makeWindow(
        id: CGWindowID,
        bundleId: String = "com.mitchellh.ghostty",
        title: String
    ) -> SnapshotWindow {
        SnapshotWindow(
            windowId: id,
            pid: pid_t(1000 + Int32(truncatingIfNeeded: id)),
            bundleId: bundleId,
            appName: "Ghostty",
            title: title,
            frame: CGRect(x: 100, y: 100, width: 900, height: 600),
            layer: 0,
            isOnScreen: true,
            zOrderIndex: Int(id),
            isAXAccessible: true
        )
    }

    private func makeSnapshot(
        runId: String,
        captureTime: Date = Date(timeIntervalSince1970: 1_000),
        captureDurationMs: Int = 42,
        windows: [SnapshotWindow]
    ) -> SystemSnapshot {
        SystemSnapshot(
            captureTime: captureTime,
            captureDurationMs: captureDurationMs,
            runId: runId,
            displays: [],
            windows: windows
        )
    }

    // MARK: - mergeSupplementationSnapshot

    @Test("Overlay windows replace base windows by ID, preserving base order")
    func overlayReplacesBaseInPlace() {
        let base = makeSnapshot(runId: "base", windows: [
            makeWindow(id: 1, title: "one"),
            makeWindow(id: 2, title: "two"),
            makeWindow(id: 3, title: "three")
        ])
        let overlay = makeSnapshot(runId: "overlay", windows: [
            makeWindow(id: 2, title: "two-supplemented")
        ])

        let merged = SupplementationSnapshotMerger.mergeSupplementationSnapshot(base: base, overlay: overlay)

        #expect(merged.windows.map(\.windowId) == [1, 2, 3])
        #expect(merged.windows.map(\.title) == ["one", "two-supplemented", "three"])
    }

    @Test("Overlay-only windows are appended after base windows")
    func overlayOnlyWindowsAppended() {
        let base = makeSnapshot(runId: "base", windows: [
            makeWindow(id: 1, title: "one"),
            makeWindow(id: 2, title: "two")
        ])
        let overlay = makeSnapshot(runId: "overlay", windows: [
            makeWindow(id: 9, title: "new-window"),
            makeWindow(id: 1, title: "one-supplemented")
        ])

        let merged = SupplementationSnapshotMerger.mergeSupplementationSnapshot(base: base, overlay: overlay)

        #expect(merged.windows.count == 3)
        #expect(merged.windows.prefix(2).map(\.windowId) == [1, 2])
        #expect(merged.windows.last?.windowId == 9)
        #expect(merged.windows.first?.title == "one-supplemented")
    }

    @Test("Empty overlay leaves base windows unchanged")
    func emptyOverlayIsIdentity() {
        let base = makeSnapshot(runId: "base", windows: [
            makeWindow(id: 5, title: "five"),
            makeWindow(id: 6, title: "six")
        ])
        let overlay = makeSnapshot(runId: "overlay", windows: [])

        let merged = SupplementationSnapshotMerger.mergeSupplementationSnapshot(base: base, overlay: overlay)

        #expect(merged.windows.map(\.windowId) == [5, 6])
        #expect(merged.windows.map(\.title) == ["five", "six"])
    }

    @Test("Merged snapshot metadata comes from the base snapshot")
    func metadataComesFromBase() {
        let baseTime = Date(timeIntervalSince1970: 1_000)
        let overlayTime = Date(timeIntervalSince1970: 2_000)
        let base = makeSnapshot(runId: "base-run", captureTime: baseTime, captureDurationMs: 42, windows: [
            makeWindow(id: 1, title: "one")
        ])
        let overlay = makeSnapshot(runId: "overlay-run", captureTime: overlayTime, captureDurationMs: 7, windows: [
            makeWindow(id: 1, title: "one-supplemented")
        ])

        let merged = SupplementationSnapshotMerger.mergeSupplementationSnapshot(base: base, overlay: overlay)

        #expect(merged.runId == "base-run")
        #expect(merged.captureTime == baseTime)
        #expect(merged.captureDurationMs == 42)
    }

    // MARK: - supplementationSnapshot

    @Test("supplementationSnapshot keeps base metadata with the filtered window set")
    func supplementationSnapshotKeepsBaseMetadata() {
        let base = makeSnapshot(runId: "base-run", windows: [
            makeWindow(id: 1, title: "one"),
            makeWindow(id: 2, title: "two"),
            makeWindow(id: 3, title: "three")
        ])
        let subset = [base.windows[1]]

        let filtered = SupplementationSnapshotMerger.supplementationSnapshot(from: base, windows: subset)

        #expect(filtered.runId == "base-run")
        #expect(filtered.captureTime == base.captureTime)
        #expect(filtered.captureDurationMs == base.captureDurationMs)
        #expect(filtered.windows.map(\.windowId) == [2])
    }
}
