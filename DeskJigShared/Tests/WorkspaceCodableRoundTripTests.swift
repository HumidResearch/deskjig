//
//  WorkspaceCodableRoundTripTests.swift
//  DeskJigSharedTests
//
//  Pins the on-disk local persistence format for `Workspace`.
//
//  The app persists every workspace by encoding/decoding the `Workspace` model
//  with a plain, default `JSONEncoder()` / `JSONDecoder()` (see
//  `WorkspaceStorageService.loadWorkspacesFromCache`,
//  `loadWorkspacesFromGlobalCache`, and `saveToLocalCacheRaw`). That on-disk
//  contract is the primary thing that survives the SaaS shutdown / open-sourcing,
//  so a Codable-affecting change (renamed key, added non-optional field, changed
//  date strategy) must produce a loud test signal instead of silently corrupting
//  every user's saved workspaces on upgrade.
//
//  These tests mirror the app path exactly: default `JSONEncoder()` to encode and
//  default `JSONDecoder()` to decode. They cover dates (`createdAt` /
//  `lastActivatedAt` / `updatedAt`), `screens`, `displaySlots`, nested `windows`
//  with `relativeFrame`, and a `WorkspaceKeyboardShortcut`, plus a checked-in JSON
//  fixture that fails if any Codable key is silently renamed.
//

import CoreGraphics
import Foundation
import Testing
@testable import DeskJigShared

struct WorkspaceCodableRoundTripTests {

    // MARK: - Fixed, value-controlled dates
    //
    // The public `Workspace.init` hardcodes `createdAt = .now` / `updatedAt = .now`
    // and `lastActivatedAt = nil`, so it cannot produce a value-controlled instance.
    // We drive the date fields through `Workspace.migrated` (createdAt /
    // lastActivatedAt) and `withUpdatedTime` (updatedAt) instead, using clean
    // integral reference-date offsets that round-trip through JSON exactly.
    private static let createdAt = Date(timeIntervalSinceReferenceDate: 700_000_000)
    private static let lastActivatedAt = Date(timeIntervalSinceReferenceDate: 700_500_000)
    private static let updatedAt = Date(timeIntervalSinceReferenceDate: 701_000_000)

    private func makeFingerprint(vendor: Int, model: Int, serial: Int?, uuid: String?, name: String, size: CGSize) -> DisplayFingerprint {
        DisplayFingerprint(
            vendorID: vendor,
            modelNumber: model,
            serialNumber: serial,
            displayUUID: uuid,
            name: name,
            resolution: size
        )
    }

    private func makeScreens() -> [WorkspaceScreen] {
        let screen0 = WorkspaceScreen(
            displayID: 1,
            name: "Built-in Display",
            resolution: CGSize(width: 2560, height: 1440),
            frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1400),
            isPrimary: true,
            displayFingerprint: makeFingerprint(
                vendor: 610, model: 42, serial: 0, uuid: "FP-BUILTIN",
                name: "Built-in", size: CGSize(width: 2560, height: 1440)
            )
        )
        let screen1 = WorkspaceScreen(
            displayID: 2,
            name: "External Display",
            resolution: CGSize(width: 3840, height: 2160),
            frame: CGRect(x: 2560, y: 0, width: 3840, height: 2160),
            visibleFrame: CGRect(x: 2560, y: 0, width: 3840, height: 2160),
            isPrimary: false,
            displayFingerprint: makeFingerprint(
                vendor: 4, model: 5, serial: 12_345, uuid: "FP-DELL",
                name: "Dell", size: CGSize(width: 3840, height: 2160)
            )
        )
        return [screen0, screen1]
    }

    private func makeSlots() -> [WorkspaceDisplaySlot] {
        let slot0 = WorkspaceDisplaySlot(
            title: "Main",
            displayID: 1,
            displayName: "Built-in Display",
            resolution: CGSize(width: 2560, height: 1440),
            arrangementFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1400),
            isPrimary: true,
            displayFingerprint: makeFingerprint(
                vendor: 610, model: 42, serial: 0, uuid: "FP-BUILTIN",
                name: "Built-in", size: CGSize(width: 2560, height: 1440)
            )
        )
        let slot1 = WorkspaceDisplaySlot(
            title: "Side",
            displayID: 2,
            displayName: "External Display",
            resolution: CGSize(width: 3840, height: 2160),
            arrangementFrame: CGRect(x: 2560, y: 0, width: 3840, height: 2160),
            visibleFrame: CGRect(x: 2560, y: 0, width: 3840, height: 2160),
            isPrimary: false,
            displayFingerprint: makeFingerprint(
                vendor: 4, model: 5, serial: 12_345, uuid: "FP-DELL",
                name: "Dell", size: CGSize(width: 3840, height: 2160)
            )
        )
        return [slot0, slot1]
    }

    private func makeWindows() -> [WorkspaceWindow] {
        let terminal = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: "com.googlecode.iterm2",
            appName: "iTerm2",
            windowTitle: "Terminal",
            terminalKey: "term-1",
            openPath: "/Users/test/project",
            applicationPath: "/Applications/iTerm.app",
            folderGroupID: UUID(),
            folderOrder: 0,
            screenIndex: 0,
            relativeFrame: RelativeWindowFrame(xPercent: 0.1, yPercent: 0.2, widthPercent: 0.3, heightPercent: 0.4)
        )
        let browser = WorkspaceWindow(
            id: UUID(),
            bundleIdentifier: "com.apple.Safari",
            appName: "Safari",
            windowTitle: "Docs",
            screenIndex: 1,
            relativeFrame: RelativeWindowFrame(xPercent: 0.5, yPercent: 0.0, widthPercent: 0.5, heightPercent: 1.0)
        )
        return [terminal, browser]
    }

    private let keyboardShortcut = WorkspaceKeyboardShortcut(key: "1", modifiers: ["command", "shift"])

    // MARK: - Programmatic round-trips

    /// Full-fidelity round-trip for the `screens`-persisting mode (no `displaySlots`).
    ///
    /// When `displaySlots` is nil the encoder writes `screens` directly, so the
    /// whole `Workspace` value survives a default `JSONEncoder()` -> `JSONDecoder()`
    /// round-trip byte-for-value: `decoded == original`.
    @Test("Full Workspace round-trip (screens mode) preserves every field")
    func fullWorkspaceRoundTripScreensMode() throws {
        var workspace = Workspace.migrated(
            id: UUID(),
            name: "Round Trip",
            icon: "star.fill",
            createdAt: Self.createdAt,
            lastActivatedAt: Self.lastActivatedAt,
            windows: makeWindows(),
            displaySlots: nil,
            screens: makeScreens(),
            isFavorite: true
        )
        workspace = workspace.withNewKeyboardShortcut(keyboardShortcut)
        workspace = workspace.withUpdatedTime(Self.updatedAt)

        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)

        // Whole-value equality is the contract for this persistence mode.
        #expect(decoded == workspace)

        // Spell out the load-bearing fields so a regression names the culprit.
        #expect(decoded.id == workspace.id)
        #expect(decoded.name == "Round Trip")
        #expect(decoded.icon == "star.fill")
        #expect(decoded.isFavorite == true)
        #expect(decoded.createdAt == Self.createdAt)
        #expect(decoded.lastActivatedAt == Self.lastActivatedAt)
        #expect(decoded.updatedAt == Self.updatedAt)
        #expect(decoded.keyboardShortcut == keyboardShortcut)
        #expect(decoded.keyboardShortcut?.key == "1")
        #expect(decoded.keyboardShortcut?.modifiers == ["command", "shift"])
        #expect(decoded.screens?.count == 2)
        #expect(decoded.screens == workspace.screens)
        #expect(decoded.displaySlots == nil)
        #expect(decoded.windows == workspace.windows)
        #expect(decoded.windows.count == 2)
        #expect(decoded.windows.first?.relativeFrame == RelativeWindowFrame(xPercent: 0.1, yPercent: 0.2, widthPercent: 0.3, heightPercent: 0.4))
        #expect(decoded.windows.first?.terminalKey == "term-1")
        #expect(decoded.windows.first?.openPath == "/Users/test/project")
        #expect(decoded.windows.first?.folderOrder == 0)
    }

    /// Round-trip for the `displaySlots`-persisting mode.
    ///
    /// Since #566 the encoder always writes `screens` alongside `displaySlots`
    /// (see `Workspace.encode(to:)`) so that a reader which drops the
    /// `displaySlots` key cannot silently lose all display geometry. The
    /// decoder still prefers `displaySlots` and only falls back to re-deriving
    /// `screens` from the slots when the `screens` key is absent (older
    /// persisted documents). With both keys present the whole value - including
    /// the derived-at-init `screens` - survives verbatim.
    @Test("Full Workspace round-trip (displaySlots mode) preserves slots and every non-derived field")
    func fullWorkspaceRoundTripDisplaySlotsMode() throws {
        var workspace = Workspace.migrated(
            id: UUID(),
            name: "Slots Round Trip",
            icon: "rectangle.split.2x1",
            createdAt: Self.createdAt,
            lastActivatedAt: Self.lastActivatedAt,
            windows: makeWindows(),
            displaySlots: makeSlots(),
            screens: nil,
            isFavorite: false
        )
        workspace = workspace.withNewKeyboardShortcut(keyboardShortcut)
        workspace = workspace.withUpdatedTime(Self.updatedAt)

        let data = try JSONEncoder().encode(workspace)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)

        #expect(decoded.id == workspace.id)
        #expect(decoded.name == "Slots Round Trip")
        #expect(decoded.icon == "rectangle.split.2x1")
        #expect(decoded.isFavorite == false)
        #expect(decoded.createdAt == Self.createdAt)
        #expect(decoded.lastActivatedAt == Self.lastActivatedAt)
        #expect(decoded.updatedAt == Self.updatedAt)
        #expect(decoded.keyboardShortcut == keyboardShortcut)
        #expect(decoded.windows == workspace.windows)
        #expect(decoded.displaySlots == workspace.displaySlots)
        #expect(decoded.displaySlots?.count == 2)
        #expect(decoded.displaySlots?.first?.title == "Main")
        #expect(decoded.displaySlots?.last?.displayID == 2)

        // #566: `screens` is persisted alongside `displaySlots`, so it survives
        // the round-trip verbatim (UUIDs included) and must stay consistent with
        // the slots by content.
        #expect(decoded.screens == workspace.screens)
        let derived = try #require(decoded.screens)
        let slots = try #require(workspace.displaySlots)
        #expect(derived.count == slots.count)
        for (screen, slot) in zip(derived, slots) {
            #expect(screen.displayID == slot.displayID)
            #expect(screen.name == slot.displayName)
            #expect(screen.resolution == slot.resolution)
            #expect(screen.frame == slot.arrangementFrame)
            #expect(screen.visibleFrame == slot.visibleFrame)
            #expect(screen.isPrimary == slot.isPrimary)
            #expect(screen.displayFingerprint == slot.displayFingerprint)
        }
    }

    // MARK: - Checked-in fixtures (silent key-rename guards)
    //
    // These are captured from the current default encoder. Renaming any Codable
    // key (or dropping a non-optional field, or changing the date strategy) makes
    // decoding fail or a field come back nil/default, tripping the assertions —
    // the loud upgrade-safety signal this suite exists to provide.

    /// `screens`-mode fixture (no `displaySlots`). Exercises the `screens` key and
    /// its `WorkspaceScreen` sub-keys, plus all non-slot `Workspace`/`WorkspaceWindow`
    /// keys, `RelativeWindowFrame`, and `WorkspaceKeyboardShortcut`.
    private static let screensFixtureJSON = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "Fixture Workspace",
      "icon": "star.fill",
      "keyboardShortcut": { "key": "1", "modifiers": ["command", "shift"] },
      "createdAt": 700000000,
      "lastActivatedAt": 700500000,
      "updatedAt": 701000000,
      "isFavorite": true,
      "windows": [
        {
          "id": "22222222-2222-2222-2222-222222222221",
          "bundleIdentifier": "com.googlecode.iterm2",
          "appName": "iTerm2",
          "windowTitle": "Terminal",
          "terminalKey": "term-1",
          "openPath": "/Users/test/project",
          "applicationPath": "/Applications/iTerm.app",
          "folderGroupID": "33333333-3333-3333-3333-333333333331",
          "folderOrder": 0,
          "screenIndex": 0,
          "relativeFrame": { "xPercent": 0.1, "yPercent": 0.2, "widthPercent": 0.3, "heightPercent": 0.4 }
        },
        {
          "id": "22222222-2222-2222-2222-222222222222",
          "bundleIdentifier": "com.apple.Safari",
          "appName": "Safari",
          "windowTitle": "Docs",
          "screenIndex": 1,
          "relativeFrame": { "xPercent": 0.5, "yPercent": 0.0, "widthPercent": 0.5, "heightPercent": 1.0 }
        }
      ],
      "screens": [
        {
          "id": "44444444-4444-4444-4444-444444444440",
          "displayID": 1,
          "name": "Built-in Display",
          "resolution": [2560, 1440],
          "frame": [[0, 0], [2560, 1440]],
          "visibleFrame": [[0, 0], [2560, 1400]],
          "isPrimary": true,
          "displayFingerprint": {
            "vendorID": 610,
            "modelNumber": 42,
            "serialNumber": 0,
            "displayUUID": "FP-BUILTIN",
            "name": "Built-in",
            "resolution": [2560, 1440]
          }
        },
        {
          "id": "44444444-4444-4444-4444-444444444441",
          "displayID": 2,
          "name": "External Display",
          "resolution": [3840, 2160],
          "frame": [[2560, 0], [3840, 2160]],
          "visibleFrame": [[2560, 0], [3840, 2160]],
          "isPrimary": false,
          "displayFingerprint": {
            "vendorID": 4,
            "modelNumber": 5,
            "serialNumber": 12345,
            "displayUUID": "FP-DELL",
            "name": "Dell",
            "resolution": [3840, 2160]
          }
        }
      ]
    }
    """

    /// `displaySlots`-mode fixture. Exercises the `displaySlots` key and its
    /// `WorkspaceDisplaySlot` sub-keys, plus a window bound to a slot by
    /// `displaySlotID` (so the decoder re-derives its `screenIndex`).
    private static let displaySlotsFixtureJSON = """
    {
      "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
      "name": "Fixture Slots Workspace",
      "icon": "rectangle.split.2x1",
      "keyboardShortcut": { "key": "2", "modifiers": ["option"] },
      "createdAt": 700000000,
      "lastActivatedAt": 700500000,
      "updatedAt": 701000000,
      "isFavorite": false,
      "windows": [
        {
          "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbb1",
          "bundleIdentifier": "com.apple.Safari",
          "appName": "Safari",
          "windowTitle": "Web",
          "displaySlotID": "cccccccc-cccc-cccc-cccc-ccccccccccc2",
          "relativeFrame": { "xPercent": 0.25, "yPercent": 0.25, "widthPercent": 0.5, "heightPercent": 0.5 }
        }
      ],
      "displaySlots": [
        {
          "id": "cccccccc-cccc-cccc-cccc-ccccccccccc1",
          "title": "Main",
          "displayID": 1,
          "displayName": "Built-in Display",
          "resolution": [2560, 1440],
          "arrangementFrame": [[0, 0], [2560, 1440]],
          "visibleFrame": [[0, 0], [2560, 1400]],
          "isPrimary": true,
          "displayFingerprint": {
            "vendorID": 610,
            "modelNumber": 42,
            "serialNumber": 0,
            "displayUUID": "FP-BUILTIN",
            "name": "Built-in",
            "resolution": [2560, 1440]
          }
        },
        {
          "id": "cccccccc-cccc-cccc-cccc-ccccccccccc2",
          "title": "Side",
          "displayID": 2,
          "displayName": "External Display",
          "resolution": [3840, 2160],
          "arrangementFrame": [[2560, 0], [3840, 2160]],
          "visibleFrame": [[2560, 0], [3840, 2160]],
          "isPrimary": false,
          "displayFingerprint": {
            "vendorID": 4,
            "modelNumber": 5,
            "serialNumber": 12345,
            "displayUUID": "FP-DELL",
            "name": "Dell",
            "resolution": [3840, 2160]
          }
        }
      ]
    }
    """

    @Test("Checked-in screens-mode fixture decodes to the pinned values")
    func decodesCheckedInScreensFixture() throws {
        let data = try #require(Self.screensFixtureJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)

        #expect(decoded.id == UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        #expect(decoded.name == "Fixture Workspace")
        #expect(decoded.icon == "star.fill")
        #expect(decoded.isFavorite == true)
        #expect(decoded.createdAt == Date(timeIntervalSinceReferenceDate: 700_000_000))
        #expect(decoded.lastActivatedAt == Date(timeIntervalSinceReferenceDate: 700_500_000))
        #expect(decoded.updatedAt == Date(timeIntervalSinceReferenceDate: 701_000_000))

        // Keyboard shortcut keys.
        #expect(decoded.keyboardShortcut?.key == "1")
        #expect(decoded.keyboardShortcut?.modifiers == ["command", "shift"])

        // Windows + relativeFrame keys.
        #expect(decoded.windows.count == 2)
        let terminal = try #require(decoded.windows.first)
        #expect(terminal.bundleIdentifier == "com.googlecode.iterm2")
        #expect(terminal.appName == "iTerm2")
        #expect(terminal.windowTitle == "Terminal")
        #expect(terminal.terminalKey == "term-1")
        #expect(terminal.openPath == "/Users/test/project")
        #expect(terminal.applicationPath == "/Applications/iTerm.app")
        #expect(terminal.folderGroupID == UUID(uuidString: "33333333-3333-3333-3333-333333333331"))
        #expect(terminal.folderOrder == 0)
        #expect(terminal.screenIndex == 0)
        #expect(terminal.relativeFrame == RelativeWindowFrame(xPercent: 0.1, yPercent: 0.2, widthPercent: 0.3, heightPercent: 0.4))

        // Screens + WorkspaceScreen keys.
        #expect(decoded.displaySlots == nil)
        let screens = try #require(decoded.screens)
        #expect(screens.count == 2)
        let builtIn = screens[0]
        #expect(builtIn.id == UUID(uuidString: "44444444-4444-4444-4444-444444444440"))
        #expect(builtIn.displayID == 1)
        #expect(builtIn.name == "Built-in Display")
        #expect(builtIn.resolution == CGSize(width: 2560, height: 1440))
        #expect(builtIn.frame == CGRect(x: 0, y: 0, width: 2560, height: 1440))
        #expect(builtIn.visibleFrame == CGRect(x: 0, y: 0, width: 2560, height: 1400))
        #expect(builtIn.isPrimary == true)
        #expect(builtIn.displayFingerprint?.vendorID == 610)
        #expect(builtIn.displayFingerprint?.modelNumber == 42)
        #expect(builtIn.displayFingerprint?.displayUUID == "FP-BUILTIN")
        #expect(builtIn.displayFingerprint?.resolution == CGSize(width: 2560, height: 1440))
        #expect(screens[1].displayFingerprint?.serialNumber == 12_345)

        // The fixture re-encodes and decodes back to an equal value (screens mode
        // is whole-value stable), proving the fixture matches the live encoder.
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(Workspace.self, from: reEncoded)
        #expect(reDecoded == decoded)
    }

    @Test("Checked-in displaySlots-mode fixture decodes to the pinned values")
    func decodesCheckedInDisplaySlotsFixture() throws {
        let data = try #require(Self.displaySlotsFixtureJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)

        #expect(decoded.id == UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        #expect(decoded.name == "Fixture Slots Workspace")
        #expect(decoded.icon == "rectangle.split.2x1")
        #expect(decoded.isFavorite == false)
        #expect(decoded.keyboardShortcut?.key == "2")
        #expect(decoded.keyboardShortcut?.modifiers == ["option"])

        // displaySlots + WorkspaceDisplaySlot keys.
        let slots = try #require(decoded.displaySlots)
        #expect(slots.count == 2)
        let main = slots[0]
        #expect(main.id == UUID(uuidString: "cccccccc-cccc-cccc-cccc-ccccccccccc1"))
        #expect(main.title == "Main")
        #expect(main.displayID == 1)
        #expect(main.displayName == "Built-in Display")
        #expect(main.resolution == CGSize(width: 2560, height: 1440))
        #expect(main.arrangementFrame == CGRect(x: 0, y: 0, width: 2560, height: 1440))
        #expect(main.visibleFrame == CGRect(x: 0, y: 0, width: 2560, height: 1400))
        #expect(main.isPrimary == true)
        #expect(main.displayFingerprint?.vendorID == 610)
        #expect(slots[1].displayID == 2)
        #expect(slots[1].title == "Side")

        // Window bound to slot 2 by displaySlotID -> decoder re-derives screenIndex.
        let window = try #require(decoded.windows.first)
        #expect(window.displaySlotID == UUID(uuidString: "cccccccc-cccc-cccc-cccc-ccccccccccc2"))
        #expect(window.screenIndex == 1)
        #expect(window.relativeFrame == RelativeWindowFrame(xPercent: 0.25, yPercent: 0.25, widthPercent: 0.5, heightPercent: 0.5))

        // Screens are re-derived from the slots on decode.
        #expect(decoded.screens?.count == 2)
    }
}
