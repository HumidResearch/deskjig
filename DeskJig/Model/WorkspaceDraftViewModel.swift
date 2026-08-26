//
//  WorkspaceDraftViewModel.swift
//  DeskJig
//
//  Inline workspace creation state for the workspace list.
//

import SwiftUI
import DeskJigShared

@MainActor
@Observable
final class WorkspaceDraftViewModel {
    enum ZoneResizeAxis {
        case vertical
        case horizontal
    }

    enum SplitDirection {
        case vertical
        case horizontal
    }

    // MARK: - Draft Models

    struct DraftScreen: Identifiable, Equatable {
        let id: UUID
        var title: String
        var displayName: String
        var isPrimary: Bool
        var isVirtual: Bool
        var displayID: Int
        var resolution: CGSize
        var frame: CGRect
        var visibleFrame: CGRect
        var displayFingerprint: DisplayFingerprint?
        var screenInfo: FullScreenInfo?
    }

    struct DraftWindow: Identifiable, Equatable {
        let id: UUID
        let appInfo: AppInfo
        let bundleId: String
        var windowTitle: String
        var chromeProfile: String?
        var shouldRestoreTabs: Bool
        var chromeTabs: [String]
        var openPath: String
    }

    struct DraftZone: Identifiable, Equatable {
        let id: UUID
        var frame: RelativeWindowFrame
        var assignedWindowIDs: [UUID]

        private var area: CGFloat { frame.widthPercent * frame.heightPercent }
        private var meetsSplitArea: Bool { area > 0.25 }

        var canSplitVertical: Bool { meetsSplitArea }

        var canSplitHorizontal: Bool { meetsSplitArea }

        var primaryAssignedWindowID: UUID? {
            assignedWindowIDs.first
        }
    }

    struct ZoneSplitRecord: Equatable {
        let parentZone: DraftZone
        let childZoneIds: [UUID]
        let insertIndex: Int
    }

    struct DraftScreenLayout: Equatable {
        var preset: LayoutPreset
        var zones: [DraftZone]
        var splitHistory: [ZoneSplitRecord] = []
    }

    // MARK: - Dependencies

    private let applicationManager: ApplicationManagerProtocol
    private let displayManager: DisplayManager
    private let chromeProfileManager: ChromeProfileManager
    private let workspaceManager: WorkspaceManager

    // MARK: - State

    var workspaceName: String = "New Workspace"
    var workspaceIcon: String = "📁"

    var screens: [DraftScreen] = []
    var layouts: [DraftScreenLayout] = []
    var windowsById: [UUID: DraftWindow] = [:]
    var currentDisplays: [FullScreenInfo] = []
    var screenAssignments: [Int: Int] = [:]

    var selectedScreenIndex: Int = 0
    var selectedWindowId: UUID? = nil
    var selectedZoneId: UUID? = nil
    var selectedDisplayTargetIndex: Int? = nil

    var availableChromeProfiles: [ChromeProfile] = []

    var isSaving: Bool = false
    var isCloningScreenLayout: Bool = false

    var allInstalledApps: [AppInfo] {
        applicationManager.applications
    }

    // MARK: - Constants

    let maxScreens: Int = 6
    let anyChromeWindowMarker = "__ANY_CHROME_WINDOW__"
    private let minimumResizableZoneDimension: CGFloat = 0.12

    init(
        applicationManager: ApplicationManagerProtocol,
        displayManager: DisplayManager,
        chromeProfileManager: ChromeProfileManager,
        workspaceManager: WorkspaceManager
    ) {
        self.applicationManager = applicationManager
        self.displayManager = displayManager
        self.chromeProfileManager = chromeProfileManager
        self.workspaceManager = workspaceManager
    }

    // MARK: - Setup

    func reset() {
        workspaceName = "New Workspace"
        workspaceIcon = "📁"
        selectedWindowId = nil
        selectedZoneId = nil
        selectedDisplayTargetIndex = nil
        windowsById = [:]

        let detectedScreens = refreshCurrentDisplays()
        screens = detectedScreens.enumerated().map { index, screen in
            makeDraftScreen(from: screen, title: "Monitor \(index + 1)")
        }

        if screens.isEmpty {
            // Fallback when no screens are detected
            screens = [
                DraftScreen(
                    id: UUID(),
                    title: "Monitor 1",
                    displayName: "Virtual Display",
                    isPrimary: true,
                    isVirtual: true,
                    displayID: -1,
                    resolution: CGSize(width: 1440, height: 900),
                    frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                    displayFingerprint: nil,
                    screenInfo: nil
                )
            ]
        }

        layouts = screens.map { _ in
            DraftScreenLayout(preset: .fiftyFifty, zones: Self.zones(from: .fiftyFifty))
        }

        selectedScreenIndex = 0
        initializeScreenAssignments()
        refreshChromeProfiles()
    }

    func load(from workspace: Workspace) {
        workspaceName = workspace.name
        workspaceIcon = workspace.icon ?? "📁"
        selectedWindowId = nil
        selectedZoneId = nil
        selectedDisplayTargetIndex = nil
        windowsById = [:]

        let detectedScreens = refreshCurrentDisplays()

        if let savedScreens = workspace.screens, !savedScreens.isEmpty {
            screens = savedScreens.enumerated().map { index, screen in
                makeDraftScreen(
                    from: screen,
                    matching: detectedScreens,
                    title: "Monitor \(index + 1)"
                )
            }
        } else {
            screens = detectedScreens.enumerated().map { index, screen in
                makeDraftScreen(from: screen, title: "Monitor \(index + 1)")
            }
        }

        if screens.isEmpty {
            screens = [
                DraftScreen(
                    id: UUID(),
                    title: "Monitor 1",
                    displayName: "Virtual Display",
                    isPrimary: true,
                    isVirtual: true,
                    displayID: -1,
                    resolution: CGSize(width: 1440, height: 900),
                    frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                    displayFingerprint: nil,
                    screenInfo: nil
                )
            ]
        }

        for window in workspace.windows {
            let bundleId = window.bundleIdentifier
            let appInfo = findAppInfo(bundleOrPath: bundleId)
                ?? AppInfo(
                    name: window.appName,
                    bundleIdentifier: bundleId,
                    path: window.applicationPath ?? bundleId,
                    icon: nil
                )

            let chromeProfile: String?
            if BundleRegistry.isChrome(bundleId) {
                if window.chromeState?.profileMatchMode == .anyWindow {
                    chromeProfile = anyChromeWindowMarker
                } else {
                    chromeProfile = window.chromeState?.profileDirectory
                }
            } else {
                chromeProfile = nil
            }

            let tabs = window.chromeState?.savedTabURLs ?? []
            let shouldRestoreTabs = window.chromeState?.shouldRestoreTabs ?? !tabs.isEmpty

            let draftWindow = DraftWindow(
                id: window.id,
                appInfo: appInfo,
                bundleId: bundleId,
                windowTitle: window.windowTitle,
                chromeProfile: chromeProfile,
                shouldRestoreTabs: shouldRestoreTabs,
                chromeTabs: tabs,
                openPath: window.openPath ?? ""
            )

            windowsById[window.id] = draftWindow
        }

        var windowsByScreen: [Int: [WorkspaceWindow]] = [:]
        for window in workspace.windows {
            let rawIndex = window.screenIndex ?? 0
            let clampedIndex = screens.isEmpty ? 0 : max(0, min(rawIndex, screens.count - 1))
            windowsByScreen[clampedIndex, default: []].append(window)
        }

        layouts = screens.indices.map { index in
            let windowsForScreen = windowsByScreen[index] ?? []
            if windowsForScreen.isEmpty {
                return DraftScreenLayout(preset: .fiftyFifty, zones: Self.zones(from: .fiftyFifty))
            }

            let zones = zonesFromWorkspaceWindows(windowsForScreen)
            let preset = LayoutPreset.allCases.first(where: { $0.windowCount == zones.count }) ?? .fiftyFifty
            return DraftScreenLayout(preset: preset, zones: zones)
        }

        selectedScreenIndex = 0
        initializeScreenAssignments()
        refreshChromeProfiles()
    }

    func load(fromSnapshot windows: [WorkspaceWindow], screens snapshotScreens: [WorkspaceScreen]) {
        workspaceName = "New Workspace"
        workspaceIcon = "📁"
        selectedWindowId = nil
        selectedZoneId = nil
        selectedDisplayTargetIndex = nil
        windowsById = [:]

        let detectedScreens = refreshCurrentDisplays()

        if !snapshotScreens.isEmpty {
            screens = snapshotScreens.enumerated().map { index, screen in
                makeDraftScreen(
                    from: screen,
                    matching: detectedScreens,
                    title: "Monitor \(index + 1)"
                )
            }
        } else {
            screens = detectedScreens.enumerated().map { index, screen in
                makeDraftScreen(from: screen, title: "Monitor \(index + 1)")
            }
        }

        if screens.isEmpty {
            screens = [
                DraftScreen(
                    id: UUID(),
                    title: "Monitor 1",
                    displayName: "Virtual Display",
                    isPrimary: true,
                    isVirtual: true,
                    displayID: -1,
                    resolution: CGSize(width: 1440, height: 900),
                    frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                    visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                    displayFingerprint: nil,
                    screenInfo: nil
                )
            ]
        }

        for window in windows {
            let bundleId = window.bundleIdentifier
            let appInfo = findAppInfo(bundleOrPath: bundleId)
                ?? AppInfo(
                    name: window.appName,
                    bundleIdentifier: bundleId,
                    path: window.applicationPath ?? bundleId,
                    icon: nil
                )

            let chromeProfile: String?
            if BundleRegistry.isChrome(bundleId) {
                if window.chromeState?.profileMatchMode == .anyWindow {
                    chromeProfile = anyChromeWindowMarker
                } else {
                    chromeProfile = window.chromeState?.profileDirectory
                }
            } else {
                chromeProfile = nil
            }

            let tabs = window.chromeState?.savedTabURLs ?? []
            let shouldRestoreTabs = window.chromeState?.shouldRestoreTabs ?? !tabs.isEmpty

            let draftWindow = DraftWindow(
                id: window.id,
                appInfo: appInfo,
                bundleId: bundleId,
                windowTitle: window.windowTitle,
                chromeProfile: chromeProfile,
                shouldRestoreTabs: shouldRestoreTabs,
                chromeTabs: tabs,
                openPath: window.openPath ?? ""
            )

            windowsById[window.id] = draftWindow
        }

        var windowsByScreen: [Int: [WorkspaceWindow]] = [:]
        for window in windows {
            let rawIndex = window.screenIndex ?? 0
            let clampedIndex = screens.isEmpty ? 0 : max(0, min(rawIndex, screens.count - 1))
            windowsByScreen[clampedIndex, default: []].append(window)
        }

        layouts = screens.indices.map { index in
            let windowsForScreen = windowsByScreen[index] ?? []
            if windowsForScreen.isEmpty {
                return DraftScreenLayout(preset: .fiftyFifty, zones: Self.zones(from: .fiftyFifty))
            }

            let zones = zonesFromWorkspaceWindows(windowsForScreen)
            let preset = LayoutPreset.allCases.first(where: { $0.windowCount == zones.count }) ?? .fiftyFifty
            return DraftScreenLayout(preset: preset, zones: zones)
        }

        selectedScreenIndex = 0
        initializeScreenAssignments()
        refreshChromeProfiles()
    }

    func refreshChromeProfiles() {
        availableChromeProfiles = chromeProfileManager.refreshProfilesSync()
    }

    func cloneCurrentDisplayLayout(into screenIndex: Int) async -> Bool {
        guard screens.indices.contains(screenIndex),
              let currentDisplayIndex = currentDisplayIndex(for: screenIndex) else { return false }

        isCloningScreenLayout = true
        defer { isCloningScreenLayout = false }

        let snapshot = await workspaceManager.captureCurrentWindows(
            screenIndices: [currentDisplayIndex],
            minVisibilityOverride: 0.25
        )
        applyClonedLayout(snapshot.windows, to: screenIndex)
        return true
    }

    func saveEdits(to workspace: Workspace) async -> Bool {
        guard canCreateWorkspace else { return false }
        isSaving = true
        defer { isSaving = false }

        let workspaceDisplaySlots = buildWorkspaceDisplaySlots()
        let windows = buildWorkspaceWindows(displaySlots: workspaceDisplaySlots)
        let workspaceScreens = workspaceDisplaySlots.map { $0.asWorkspaceScreen() }
        let trimmedName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let icon = workspaceIcon.trimmingCharacters(in: .whitespacesAndNewlines)

        let updatedName = trimmedName.isEmpty ? workspace.name : trimmedName
        let updatedIcon = icon.isEmpty ? (workspace.icon ?? "📁") : icon

        workspaceManager.updateWorkspaceLayout(
            for: workspace,
            newName: updatedName,
            newIcon: updatedIcon,
            windows: windows,
            screens: workspaceScreens,
            displaySlots: workspaceDisplaySlots
        )

        DeskJigLog.info(.workspace, "Updated workspace layout", fields: ["workspace": workspace.name, "windowCount": windows.count])
        return true
    }

    // MARK: - Screens

    func addVirtualScreen() {
        guard screens.count < maxScreens else { return }
        _ = refreshCurrentDisplays()

        if let availableDisplayIndex = nextUnassignedCurrentDisplayIndex() {
            let availableScreen = currentDisplays[availableDisplayIndex]
            let hasPrimary = screens.contains(where: { $0.isPrimary })
            if let virtualIndex = screens.firstIndex(where: { $0.isVirtual }) {
                let shouldBePrimary = screens[virtualIndex].isPrimary || (availableScreen.isPrimary && !hasPrimary)
                let updatedScreen = DraftScreen(
                    id: screens[virtualIndex].id,
                    title: screens[virtualIndex].title,
                    displayName: availableScreen.name,
                    isPrimary: shouldBePrimary,
                    isVirtual: false,
                    displayID: availableScreen.displayID,
                    resolution: availableScreen.resolution,
                    frame: availableScreen.frame,
                    visibleFrame: availableScreen.visibleFrame,
                    displayFingerprint: availableScreen.displayFingerprint,
                    screenInfo: availableScreen
                )
                screens[virtualIndex] = updatedScreen
                assignScreen(virtualIndex, toCurrentDisplay: availableDisplayIndex)
                selectedScreenIndex = virtualIndex
                refreshScreenTitles()
                return
            }

            let realScreen = DraftScreen(
                id: UUID(),
                title: "Monitor \(screens.count + 1)",
                displayName: availableScreen.name,
                isPrimary: availableScreen.isPrimary && !hasPrimary,
                isVirtual: false,
                displayID: availableScreen.displayID,
                resolution: availableScreen.resolution,
                frame: availableScreen.frame,
                visibleFrame: availableScreen.visibleFrame,
                displayFingerprint: availableScreen.displayFingerprint,
                screenInfo: availableScreen
            )

            screens.append(realScreen)
            screenAssignments[screens.count - 1] = availableDisplayIndex
        } else {
            let baseScreen = screens.first(where: { $0.isPrimary }) ?? screens.first
            let baseFrame = baseScreen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            let rightmostX = screens.map { $0.frame.maxX }.max() ?? baseFrame.maxX
            let virtualFrame = CGRect(x: rightmostX, y: baseFrame.origin.y, width: baseFrame.width, height: baseFrame.height)
            let displayID = -1 - screens.count

            let virtualScreen = DraftScreen(
                id: UUID(),
                title: "Monitor \(screens.count + 1)",
                displayName: "Virtual Display \(screens.count + 1)",
                isPrimary: false,
                isVirtual: true,
                displayID: displayID,
                resolution: baseScreen?.resolution ?? CGSize(width: baseFrame.width, height: baseFrame.height),
                frame: virtualFrame,
                visibleFrame: virtualFrame,
                displayFingerprint: nil,
                screenInfo: nil
            )

            screens.append(virtualScreen)
        }

        layouts.append(DraftScreenLayout(preset: .fiftyFifty, zones: Self.zones(from: .fiftyFifty)))
        selectedScreenIndex = max(0, screens.count - 1)
        refreshScreenTitles()
    }

    func removeScreen(at index: Int) {
        guard screens.indices.contains(index), screens.count > 1 else { return }
        let removedWasPrimary = screens[index].isPrimary
        let removedLayout = layouts[index]
        let removedWindowIds = removedLayout.zones.flatMap(\.assignedWindowIDs)
        screens.remove(at: index)
        layouts.remove(at: index)
        screenAssignments = screenAssignments.reduce(into: [:]) { result, entry in
            guard entry.key != index else { return }
            let adjustedIndex = entry.key > index ? entry.key - 1 : entry.key
            result[adjustedIndex] = entry.value
        }

        for windowId in removedWindowIds {
            unassignWindow(windowId)
        }

        if let selectedZoneId,
           removedLayout.zones.contains(where: { $0.id == selectedZoneId }) {
            self.selectedZoneId = nil
        }

        if selectedScreenIndex > index {
            selectedScreenIndex -= 1
        } else if selectedScreenIndex == index {
            selectedScreenIndex = max(0, min(index, screens.count - 1))
        }

        if removedWasPrimary {
            assignPrimaryToLeftmostConnectedScreen()
        }
        selectedDisplayTargetIndex = currentDisplayIndex(for: selectedScreenIndex)
        refreshScreenTitles()
    }

    func setLayout(_ preset: LayoutPreset, for screenIndex: Int) {
        guard layouts.indices.contains(screenIndex) else { return }
        let existingAssignments = layouts[screenIndex].zones.flatMap(\.assignedWindowIDs)
        var newZones = Self.zones(from: preset)
        for (index, windowId) in existingAssignments.enumerated() where index < newZones.count {
            newZones[index].assignedWindowIDs = [windowId]
        }
        layouts[screenIndex] = DraftScreenLayout(preset: preset, zones: newZones)

        if let selectedZoneId,
           screenIndex == selectedScreenIndex,
           !newZones.contains(where: { $0.id == selectedZoneId }) {
            self.selectedZoneId = nil
        }
    }

    func currentDisplayIndex(for screenIndex: Int) -> Int? {
        screenAssignments[screenIndex]
    }

    func currentDisplay(for screenIndex: Int) -> FullScreenInfo? {
        guard let currentDisplayIndex = currentDisplayIndex(for: screenIndex),
              currentDisplays.indices.contains(currentDisplayIndex) else { return nil }
        return currentDisplays[currentDisplayIndex]
    }

    func assignedScreenIndex(for currentDisplayIndex: Int) -> Int? {
        screenAssignments.first(where: { $0.value == currentDisplayIndex })?.key
    }

    func assignScreen(_ screenIndex: Int, toCurrentDisplay currentDisplayIndex: Int?) {
        guard screens.indices.contains(screenIndex) else { return }

        let previousDisplayIndex = screenAssignments[screenIndex]
        if let currentDisplayIndex {
            guard currentDisplays.indices.contains(currentDisplayIndex) else { return }

            if let displacedScreenIndex = assignedScreenIndex(for: currentDisplayIndex),
               displacedScreenIndex != screenIndex {
                if let previousDisplayIndex, previousDisplayIndex != currentDisplayIndex {
                    screenAssignments[displacedScreenIndex] = previousDisplayIndex
                } else {
                    screenAssignments.removeValue(forKey: displacedScreenIndex)
                }
            }

            screenAssignments[screenIndex] = currentDisplayIndex
            selectedDisplayTargetIndex = currentDisplayIndex
        } else {
            screenAssignments.removeValue(forKey: screenIndex)
            if previousDisplayIndex == selectedDisplayTargetIndex {
                selectedDisplayTargetIndex = nil
            }
        }

        selectedScreenIndex = screenIndex
    }

    func arrangementFrame(for screenIndex: Int) -> CGRect {
        currentDisplay(for: screenIndex)?.frame ?? screens[screenIndex].frame
    }

    func displayName(for screenIndex: Int) -> String {
        currentDisplay(for: screenIndex)?.name ?? screens[screenIndex].displayName
    }

    func resolutionText(for screenIndex: Int) -> String {
        let resolution = currentDisplay(for: screenIndex)?.resolution ?? screens[screenIndex].resolution
        return "\(Int(resolution.width)) x \(Int(resolution.height))"
    }

    func screenDetailText(for screenIndex: Int) -> String {
        if let currentDisplay = currentDisplay(for: screenIndex) {
            return currentDisplay.displayID == screens[screenIndex].displayID
                ? "Connected display"
                : "Assigned to connected display"
        }

        return screens[screenIndex].isVirtual ? "Virtual workspace display" : "Saved workspace display"
    }

    func orderedScreenIndices() -> [Int] {
        screens.indices.sorted { lhs, rhs in
            let lhsFrame = arrangementFrame(for: lhs)
            let rhsFrame = arrangementFrame(for: rhs)
            if lhsFrame.minX != rhsFrame.minX {
                return lhsFrame.minX < rhsFrame.minX
            }
            if lhsFrame.minY != rhsFrame.minY {
                return lhsFrame.minY > rhsFrame.minY
            }
            return lhs < rhs
        }
    }

    func isGhostScreen(_ screenIndex: Int) -> Bool {
        currentDisplayIndex(for: screenIndex) == nil
    }

    // MARK: - Zones

    func zones(for screenIndex: Int) -> [DraftZone] {
        guard layouts.indices.contains(screenIndex) else { return [] }
        return layouts[screenIndex].zones
    }

    func splitZone(zoneId: UUID, direction: SplitDirection, screenIndex: Int) {
        guard layouts.indices.contains(screenIndex),
              let zoneIndex = layouts[screenIndex].zones.firstIndex(where: { $0.id == zoneId }) else { return }

        let zone = layouts[screenIndex].zones[zoneIndex]
        let frame = zone.frame

        let firstAssigned = zone.assignedWindowIDs
        let zone1: DraftZone
        let zone2: DraftZone

        if direction == .vertical, zone.canSplitVertical {
            zone1 = DraftZone(
                id: UUID(),
                frame: RelativeWindowFrame(
                    xPercent: frame.xPercent,
                    yPercent: frame.yPercent,
                    widthPercent: frame.widthPercent / 2,
                    heightPercent: frame.heightPercent
                ),
                assignedWindowIDs: firstAssigned
            )
            zone2 = DraftZone(
                id: UUID(),
                frame: RelativeWindowFrame(
                    xPercent: frame.xPercent + frame.widthPercent / 2,
                    yPercent: frame.yPercent,
                    widthPercent: frame.widthPercent / 2,
                    heightPercent: frame.heightPercent
                ),
                assignedWindowIDs: []
            )
        } else if direction == .horizontal, zone.canSplitHorizontal {
            zone1 = DraftZone(
                id: UUID(),
                frame: RelativeWindowFrame(
                    xPercent: frame.xPercent,
                    yPercent: frame.yPercent,
                    widthPercent: frame.widthPercent,
                    heightPercent: frame.heightPercent / 2
                ),
                assignedWindowIDs: firstAssigned
            )
            zone2 = DraftZone(
                id: UUID(),
                frame: RelativeWindowFrame(
                    xPercent: frame.xPercent,
                    yPercent: frame.yPercent + frame.heightPercent / 2,
                    widthPercent: frame.widthPercent,
                    heightPercent: frame.heightPercent / 2
                ),
                assignedWindowIDs: []
            )
        } else {
            return
        }

        let parentZone = zone
        layouts[screenIndex].zones.remove(at: zoneIndex)
        layouts[screenIndex].zones.insert(contentsOf: [zone1, zone2], at: zoneIndex)
        layouts[screenIndex].splitHistory.append(
            ZoneSplitRecord(
                parentZone: parentZone,
                childZoneIds: [zone1.id, zone2.id],
                insertIndex: zoneIndex
            )
        )
    }

    func resizeZoneBoundary(
        screenIndex: Int,
        axis: ZoneResizeAxis,
        boundary: Double,
        affectedRange: ClosedRange<Double>,
        delta: Double
    ) {
        guard layouts.indices.contains(screenIndex) else { return }

        var zones = layouts[screenIndex].zones
        let boundaryValue = CGFloat(boundary)
        let range = CGFloat(affectedRange.lowerBound)...CGFloat(affectedRange.upperBound)

        switch axis {
        case .vertical:
            let leftIndices = zones.indices.filter { index in
                let frame = zones[index].frame
                return nearlyEqual(frame.xPercent + frame.widthPercent, boundaryValue)
                    && rangesOverlap(
                        CGFloat(frame.yPercent)...CGFloat(frame.yPercent + frame.heightPercent),
                        range
                    )
            }
            let rightIndices = zones.indices.filter { index in
                let frame = zones[index].frame
                return nearlyEqual(frame.xPercent, boundaryValue)
                    && rangesOverlap(
                        CGFloat(frame.yPercent)...CGFloat(frame.yPercent + frame.heightPercent),
                        range
                    )
            }

            guard leftIndices.isEmpty == false, rightIndices.isEmpty == false else { return }

            let lowerBound = leftIndices
                .map { minimumResizableZoneDimension - CGFloat(zones[$0].frame.widthPercent) }
                .max() ?? 0
            let upperBound = rightIndices
                .map { CGFloat(zones[$0].frame.widthPercent) - minimumResizableZoneDimension }
                .min() ?? 0
            let clampedDelta = min(max(CGFloat(delta), lowerBound), upperBound)
            guard abs(clampedDelta) > 0.0001 else { return }

            for index in leftIndices {
                let frame = zones[index].frame
                zones[index].frame = RelativeWindowFrame(
                    xPercent: frame.xPercent,
                    yPercent: frame.yPercent,
                    widthPercent: frame.widthPercent + clampedDelta,
                    heightPercent: frame.heightPercent
                )
            }

            for index in rightIndices {
                let frame = zones[index].frame
                zones[index].frame = RelativeWindowFrame(
                    xPercent: frame.xPercent + clampedDelta,
                    yPercent: frame.yPercent,
                    widthPercent: frame.widthPercent - clampedDelta,
                    heightPercent: frame.heightPercent
                )
            }

        case .horizontal:
            let topIndices = zones.indices.filter { index in
                let frame = zones[index].frame
                return nearlyEqual(frame.yPercent + frame.heightPercent, boundaryValue)
                    && rangesOverlap(
                        CGFloat(frame.xPercent)...CGFloat(frame.xPercent + frame.widthPercent),
                        range
                    )
            }
            let bottomIndices = zones.indices.filter { index in
                let frame = zones[index].frame
                return nearlyEqual(frame.yPercent, boundaryValue)
                    && rangesOverlap(
                        CGFloat(frame.xPercent)...CGFloat(frame.xPercent + frame.widthPercent),
                        range
                    )
            }

            guard topIndices.isEmpty == false, bottomIndices.isEmpty == false else { return }

            let lowerBound = topIndices
                .map { minimumResizableZoneDimension - CGFloat(zones[$0].frame.heightPercent) }
                .max() ?? 0
            let upperBound = bottomIndices
                .map { CGFloat(zones[$0].frame.heightPercent) - minimumResizableZoneDimension }
                .min() ?? 0
            let clampedDelta = min(max(CGFloat(delta), lowerBound), upperBound)
            guard abs(clampedDelta) > 0.0001 else { return }

            for index in topIndices {
                let frame = zones[index].frame
                zones[index].frame = RelativeWindowFrame(
                    xPercent: frame.xPercent,
                    yPercent: frame.yPercent,
                    widthPercent: frame.widthPercent,
                    heightPercent: frame.heightPercent + clampedDelta
                )
            }

            for index in bottomIndices {
                let frame = zones[index].frame
                zones[index].frame = RelativeWindowFrame(
                    xPercent: frame.xPercent,
                    yPercent: frame.yPercent + clampedDelta,
                    widthPercent: frame.widthPercent,
                    heightPercent: frame.heightPercent - clampedDelta
                )
            }
        }

        layouts[screenIndex].zones = zones
    }

    func closeZone(zoneId: UUID, screenIndex: Int) {
        guard layouts.indices.contains(screenIndex),
              let zone = layouts[screenIndex].zones.first(where: { $0.id == zoneId }) else { return }

        if let windowId = selectedWindowId,
           zone.assignedWindowIDs.contains(windowId) {
            unassignWindow(windowId)
            selectedZoneId = zoneId
            selectedScreenIndex = screenIndex
            selectedWindowId = zone.assignedWindowIDs.first(where: { $0 != windowId })
            return
        }

        if let windowId = zone.primaryAssignedWindowID {
            unassignWindow(windowId)
            selectedZoneId = zoneId
            selectedScreenIndex = screenIndex
            return
        }

        mergeZone(zoneId: zoneId, screenIndex: screenIndex)
    }

    func mergeZone(zoneId: UUID, screenIndex: Int) {
        guard layouts.indices.contains(screenIndex) else { return }
        let zones = layouts[screenIndex].zones
        guard let targetIndex = zones.firstIndex(where: { $0.id == zoneId }) else { return }

        let targetZone = zones[targetIndex]
        let targetFrame = targetZone.frame
        let targetLeft = targetFrame.xPercent
        let targetRight = targetFrame.xPercent + targetFrame.widthPercent
        let targetTop = targetFrame.yPercent
        let targetBottom = targetFrame.yPercent + targetFrame.heightPercent

        struct MergeCandidate {
            let index: Int
            let zone: DraftZone
            let sharedEdge: CGFloat
        }

        var candidates: [MergeCandidate] = []

        for (index, zone) in zones.enumerated() where zone.id != zoneId {
            let frame = zone.frame
            let left = frame.xPercent
            let right = frame.xPercent + frame.widthPercent
            let top = frame.yPercent
            let bottom = frame.yPercent + frame.heightPercent

            if (nearlyEqual(right, targetLeft) || nearlyEqual(left, targetRight)),
               nearlyEqual(top, targetTop),
               nearlyEqual(bottom, targetBottom) {
                candidates.append(MergeCandidate(index: index, zone: zone, sharedEdge: targetBottom - targetTop))
            }

            if (nearlyEqual(bottom, targetTop) || nearlyEqual(top, targetBottom)),
               nearlyEqual(left, targetLeft),
               nearlyEqual(right, targetRight) {
                candidates.append(MergeCandidate(index: index, zone: zone, sharedEdge: targetRight - targetLeft))
            }
        }

        guard let neighbor = candidates.max(by: { lhs, rhs in
            if lhs.sharedEdge == rhs.sharedEdge {
                return lhs.index < rhs.index
            }
            return lhs.sharedEdge < rhs.sharedEdge
        }) else { return }

        let mergedFrame = mergedFrame(targetZone.frame, neighbor.zone.frame)
        let mergedZone = DraftZone(
            id: UUID(),
            frame: mergedFrame,
            assignedWindowIDs: targetZone.assignedWindowIDs + neighbor.zone.assignedWindowIDs
        )

        let removalIndices = [targetIndex, neighbor.index].sorted(by: >)
        for index in removalIndices {
            layouts[screenIndex].zones.remove(at: index)
        }

        let insertIndex = min(removalIndices.min() ?? 0, layouts[screenIndex].zones.count)
        layouts[screenIndex].zones.insert(mergedZone, at: insertIndex)

        selectedScreenIndex = screenIndex
        selectedZoneId = mergedZone.id
        selectedWindowId = mergedZone.primaryAssignedWindowID
    }

    // MARK: - App Assignments

    func assignApp(bundleId: String, to zoneId: UUID, screenIndex: Int) {
        guard let appInfo = findAppInfo(bundleOrPath: bundleId) else {
            DeskJigLog.warn(.workspace, "assignApp could not resolve app — assignment dropped", fields: [
                "bundleOrPath": bundleId,
                "zoneId": zoneId.uuidString,
                "screenIndex": "\(screenIndex)"
            ])
            return
        }

        let windowId: UUID
        if supportsMultipleInstances(bundleId) {
            windowId = createWindow(for: appInfo)
        } else if let existing = windowsById.values.first(where: { $0.bundleId == bundleId }) {
            windowId = existing.id
        } else {
            windowId = createWindow(for: appInfo)
        }

        assignWindow(windowId, to: zoneId, screenIndex: screenIndex)
    }

    func assignWindow(_ windowId: UUID, to zoneId: UUID, screenIndex: Int) {
        guard layouts.indices.contains(screenIndex), windowsById[windowId] != nil else { return }

        for index in layouts.indices {
            for zoneIndex in layouts[index].zones.indices {
                layouts[index].zones[zoneIndex].assignedWindowIDs.removeAll { $0 == windowId }
            }
        }

        if let zoneIndex = layouts[screenIndex].zones.firstIndex(where: { $0.id == zoneId }) {
            if !layouts[screenIndex].zones[zoneIndex].assignedWindowIDs.contains(windowId) {
                layouts[screenIndex].zones[zoneIndex].assignedWindowIDs.append(windowId)
            }
        }

        selectedWindowId = windowId
        selectedZoneId = zoneId
        selectedScreenIndex = screenIndex
        selectedDisplayTargetIndex = currentDisplayIndex(for: screenIndex)
    }

    func unassignWindow(_ windowId: UUID) {
        for index in layouts.indices {
            for zoneIndex in layouts[index].zones.indices {
                layouts[index].zones[zoneIndex].assignedWindowIDs.removeAll { $0 == windowId }
            }
        }
        if selectedWindowId == windowId {
            selectedWindowId = nil
        }
    }

    func removeWindow(_ windowId: UUID) {
        unassignWindow(windowId)
        windowsById.removeValue(forKey: windowId)
    }

    // MARK: - Window Config Updates

    func setOpenPath(_ path: String, for windowId: UUID) {
        updateWindow(windowId) { window in
            window.openPath = path
        }
    }

    func setChromeProfile(_ profile: String?, for windowId: UUID) {
        updateWindow(windowId) { window in
            window.chromeProfile = profile
        }
    }

    func setChromeTabs(_ tabs: [String], for windowId: UUID) {
        updateWindow(windowId) { window in
            window.chromeTabs = tabs
        }
    }

    func setShouldRestoreTabs(_ shouldRestore: Bool, for windowId: UUID) {
        updateWindow(windowId) { window in
            window.shouldRestoreTabs = shouldRestore
            if !shouldRestore {
                window.chromeTabs = []
            }
        }
    }

    // MARK: - Derived Data

    var assignedWindowIds: Set<UUID> {
        var ids = Set<UUID>()
        for layout in layouts {
            for zone in layout.zones {
                for windowId in zone.assignedWindowIDs {
                    ids.insert(windowId)
                }
            }
        }
        return ids
    }

    var unassignedWindows: [DraftWindow] {
        let assigned = assignedWindowIds
        return windowsById.values.filter { !assigned.contains($0.id) }
            .sorted { $0.appInfo.name.localizedCaseInsensitiveCompare($1.appInfo.name) == .orderedAscending }
    }

    var canCreateWorkspace: Bool {
        let trimmed = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !assignedWindowIds.isEmpty
    }

    func window(for id: UUID?) -> DraftWindow? {
        guard let id else { return nil }
        return windowsById[id]
    }

    func zoneContaining(windowId: UUID) -> (screenIndex: Int, zone: DraftZone)? {
        for (screenIndex, layout) in layouts.enumerated() {
            if let zone = layout.zones.first(where: { $0.assignedWindowIDs.contains(windowId) }) {
                return (screenIndex, zone)
            }
        }
        return nil
    }

    func zoneWindowIDs(zoneId: UUID) -> [UUID] {
        guard let screenIndex = screenIndex(containing: zoneId),
              let zone = layouts[screenIndex].zones.first(where: { $0.id == zoneId }) else {
            return []
        }
        return zone.assignedWindowIDs
    }

    func moveWindowInZone(zoneId: UUID, windowId: UUID, by offset: Int) {
        guard let screenIndex = screenIndex(containing: zoneId),
              let zoneIndex = layouts[screenIndex].zones.firstIndex(where: { $0.id == zoneId }),
              let currentIndex = layouts[screenIndex].zones[zoneIndex].assignedWindowIDs.firstIndex(of: windowId) else {
            return
        }

        let newIndex = currentIndex + offset
        guard layouts[screenIndex].zones[zoneIndex].assignedWindowIDs.indices.contains(newIndex) else { return }

        var ids = layouts[screenIndex].zones[zoneIndex].assignedWindowIDs
        ids.swapAt(currentIndex, newIndex)
        layouts[screenIndex].zones[zoneIndex].assignedWindowIDs = ids
        selectedWindowId = windowId
        selectedZoneId = zoneId
        selectedScreenIndex = screenIndex
    }

    func screenIndex(containing zoneId: UUID) -> Int? {
        for (screenIndex, layout) in layouts.enumerated() {
            if layout.zones.contains(where: { $0.id == zoneId }) {
                return screenIndex
            }
        }
        return nil
    }

    // MARK: - Chrome Helpers

    func loadChromeTabs(for windowId: UUID) async -> Bool {
        guard let window = windowsById[windowId], BundleRegistry.isChrome(window.bundleId) else { return false }

        let captures = await Task.detached {
            ChromeAutomationService.captureOpenWindows()
        }.value

        var matchedCapture: ChromeAppleScriptWindowCapture?

        if let selectedProfile = window.chromeProfile,
           !selectedProfile.isEmpty,
           selectedProfile != anyChromeWindowMarker,
           let profile = chromeProfileManager.profile(forDirectory: selectedProfile) {
            matchedCapture = captures.first { capture in
                guard let captureProfile = capture.profileAppleScriptName else { return false }
                return captureProfile == profile.appleScriptName ||
                    captureProfile.localizedCaseInsensitiveContains(profile.appleScriptName) ||
                    profile.appleScriptName.localizedCaseInsensitiveContains(captureProfile)
            }
        }

        if matchedCapture == nil, captures.count == 1 {
            matchedCapture = captures.first
        }

        guard let capture = matchedCapture else {
            return false
        }

        await MainActor.run {
            setChromeTabs(capture.tabURLs, for: windowId)
            setShouldRestoreTabs(!capture.tabURLs.isEmpty, for: windowId)

            if let captureProfile = capture.profileAppleScriptName,
               let profile = chromeProfileManager.profile(forAppleScriptName: captureProfile) {
                setChromeProfile(profile.directory, for: windowId)
            }
        }

        return true
    }

    // MARK: - Workspace Creation

    func createWorkspace() async -> Bool {
        guard canCreateWorkspace else { return false }
        isSaving = true
        defer { isSaving = false }

        let workspaceDisplaySlots = buildWorkspaceDisplaySlots()
        let windows = buildWorkspaceWindows(displaySlots: workspaceDisplaySlots)
        let workspaceScreens = workspaceDisplaySlots.map { $0.asWorkspaceScreen() }
        let trimmedName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let icon = workspaceIcon.trimmingCharacters(in: .whitespacesAndNewlines)

        let workspace = Workspace(
            name: trimmedName.isEmpty ? "New Workspace" : trimmedName,
            icon: icon.isEmpty ? "📁" : icon,
            workspaceWindows: windows,
            displaySlots: workspaceDisplaySlots,
            screens: workspaceScreens
        )

        await MainActor.run {
            workspaceManager.saveWorkspace(workspace)
        }

        DeskJigLog.info(.workspace, "Created workspace", fields: ["workspace": workspace.name, "windowCount": windows.count])
        return true
    }

    // MARK: - Helpers

    private func createWindow(for appInfo: AppInfo) -> UUID {
        let windowId = UUID()
        let bundleId = appInfo.bundleIdentifier ?? appInfo.path
        let window = DraftWindow(
            id: windowId,
            appInfo: appInfo,
            bundleId: bundleId,
            windowTitle: appInfo.name,
            chromeProfile: nil,
            shouldRestoreTabs: false,
            chromeTabs: [],
            openPath: ""
        )
        windowsById[windowId] = window
        return windowId
    }

    private func findAppInfo(bundleOrPath: String) -> AppInfo? {
        if let appInfo = applicationManager.findApplication(by: bundleOrPath) {
            return appInfo
        }
        return applicationManager.applications.first { $0.path == bundleOrPath }
    }

    private func updateWindow(_ windowId: UUID, mutate: (inout DraftWindow) -> Void) {
        guard var window = windowsById[windowId] else { return }
        mutate(&window)
        windowsById[windowId] = window
    }

    private func refreshCurrentDisplays() -> [FullScreenInfo] {
        displayManager.refreshScreens()
        currentDisplays = WorkspaceDisplayTopology.effectiveScreens(from: displayManager)
        return currentDisplays
    }

    private func makeDraftScreen(from screen: FullScreenInfo, title: String) -> DraftScreen {
        DraftScreen(
            id: UUID(),
            title: title,
            displayName: screen.name,
            isPrimary: screen.isPrimary,
            isVirtual: false,
            displayID: screen.displayID,
            resolution: screen.resolution,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            displayFingerprint: screen.displayFingerprint,
            screenInfo: screen
        )
    }

    private func makeDraftScreen(
        from screen: WorkspaceScreen,
        matching currentDisplays: [FullScreenInfo],
        title: String
    ) -> DraftScreen {
        let matchingInfo = currentDisplays.first(where: { screen.matches($0) })
        return DraftScreen(
            id: UUID(),
            title: title,
            displayName: screen.name,
            isPrimary: screen.isPrimary,
            isVirtual: matchingInfo == nil,
            displayID: screen.displayID,
            resolution: screen.resolution,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            displayFingerprint: screen.displayFingerprint,
            screenInfo: matchingInfo
        )
    }

    private func draftWorkspaceScreen(for screen: DraftScreen) -> WorkspaceScreen {
        WorkspaceScreen(
            displayID: screen.displayID,
            name: screen.displayName,
            resolution: screen.resolution,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            isPrimary: screen.isPrimary,
            displayFingerprint: screen.displayFingerprint
        )
    }

    private func initializeScreenAssignments() {
        screenAssignments = [:]
        guard !screens.isEmpty, !currentDisplays.isEmpty else { return }

        let savedScreens = screens.map(draftWorkspaceScreen(for:))
        let suggestions = ScreenMismatchDetector.suggestMappings(
            savedScreens: savedScreens,
            currentScreens: currentDisplays
        )

        for suggestion in suggestions {
            if let currentIndex = suggestion.currentIndex {
                screenAssignments[suggestion.savedIndex] = currentIndex
            }
        }

        selectedDisplayTargetIndex = currentDisplayIndex(for: selectedScreenIndex)
    }

    private func mergedFrame(_ first: RelativeWindowFrame, _ second: RelativeWindowFrame) -> RelativeWindowFrame {
        let minX = min(first.xPercent, second.xPercent)
        let minY = min(first.yPercent, second.yPercent)
        let maxX = max(first.xPercent + first.widthPercent, second.xPercent + second.widthPercent)
        let maxY = max(first.yPercent + first.heightPercent, second.yPercent + second.heightPercent)
        return RelativeWindowFrame(
            xPercent: minX,
            yPercent: minY,
            widthPercent: maxX - minX,
            heightPercent: maxY - minY
        )
    }

    private func nearlyEqual(_ lhs: CGFloat, _ rhs: CGFloat, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) < epsilon
    }

    private func rangesOverlap(_ lhs: ClosedRange<CGFloat>, _ rhs: ClosedRange<CGFloat>, epsilon: CGFloat = 0.0001) -> Bool {
        min(lhs.upperBound, rhs.upperBound) - max(lhs.lowerBound, rhs.lowerBound) > epsilon
    }

    private func zonesFromWorkspaceWindows(_ windows: [WorkspaceWindow]) -> [DraftZone] {
        let windowsNeedingFallback = windows.filter { $0.relativeFrame == nil }
        let fallbackFrames = fallbackRelativeFrames(count: windowsNeedingFallback.count)
        var fallbackIndex = 0

        let groups = Dictionary(grouping: windows) { window -> String in
            if let folderGroupID = window.folderGroupID {
                return "folder-\(folderGroupID.uuidString)"
            }
            return "window-\(window.id.uuidString)"
        }

        return groups.values.compactMap { groupedWindows in
            let orderedWindows = groupedWindows.sorted { lhs, rhs in
                let lhsOrder = lhs.folderOrder ?? Int.max
                let rhsOrder = rhs.folderOrder ?? Int.max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }

            guard let firstWindow = orderedWindows.first else { return nil }
            let frame: RelativeWindowFrame
            if let relative = firstWindow.relativeFrame {
                frame = relative
            } else {
                frame = fallbackIndex < fallbackFrames.count
                    ? fallbackFrames[fallbackIndex]
                    : RelativeWindowFrame(xPercent: 0.1, yPercent: 0.1, widthPercent: 0.4, heightPercent: 0.4)
                fallbackIndex += 1
            }

            return DraftZone(
                id: UUID(),
                frame: frame,
                assignedWindowIDs: orderedWindows.map(\.id)
            )
        }
    }

    private func applyClonedLayout(_ windows: [WorkspaceWindow], to screenIndex: Int) {
        guard layouts.indices.contains(screenIndex) else { return }

        let normalizedClone = normalizeClonedWindows(windows)
        let normalizedWindows = normalizedClone.windows
        let previousWindowIDs = Set(layouts[screenIndex].zones.flatMap(\.assignedWindowIDs))
        for windowID in previousWindowIDs {
            windowsById.removeValue(forKey: windowID)
        }

        for window in normalizedWindows {
            let draftWindow = makeDraftWindow(from: window)
            windowsById[window.id] = draftWindow
        }

        let nextZones: [DraftZone]
        let nextPreset: LayoutPreset

        if normalizedWindows.isEmpty {
            nextPreset = .fullscreen
            nextZones = Self.zones(from: .fullscreen)
        } else {
            nextZones = zonesFromWorkspaceWindows(normalizedWindows)
            nextPreset = normalizedClone.preset
                ?? inferredLayoutPreset(for: nextZones.map(\.frame))
                ?? layouts[screenIndex].preset
        }

        layouts[screenIndex] = DraftScreenLayout(
            preset: nextPreset,
            zones: nextZones
        )

        selectedScreenIndex = screenIndex
        selectedZoneId = nil
        selectedWindowId = nil
        selectedDisplayTargetIndex = currentDisplayIndex(for: screenIndex)
    }

    private func normalizeClonedWindows(_ windows: [WorkspaceWindow]) -> (windows: [WorkspaceWindow], preset: LayoutPreset?) {
        let windowsWithFrames = windows.compactMap { window -> (WorkspaceWindow, RelativeWindowFrame)? in
            guard let frame = window.relativeFrame else { return nil }
            return (window, frame)
        }
        let windowsWithoutFrames = windows.filter { $0.relativeFrame == nil }

        guard windowsWithFrames.isEmpty == false else {
            return (windows, nil)
        }

        let candidatePresets = LayoutPreset.allCases.filter { $0.windowCount == windowsWithFrames.count }
        guard candidatePresets.isEmpty == false else {
            return (windows, nil)
        }

        let bestMatch = candidatePresets.compactMap { preset -> (preset: LayoutPreset, assignment: [Int], cost: Double)? in
            let presetFrames = Self.zones(from: preset).map(\.frame)
            guard let assignment = bestFrameAssignment(
                sourceFrames: windowsWithFrames.map(\.1),
                targetFrames: presetFrames
            ) else {
                return nil
            }

            let cost = zip(windowsWithFrames.map(\.1), assignment).reduce(0.0) { partial, pair in
                partial + frameDistance(pair.0, presetFrames[pair.1])
            }
            return (preset, assignment, cost)
        }
        .min { lhs, rhs in
            if lhs.cost == rhs.cost {
                return lhs.preset.windowCount < rhs.preset.windowCount
            }
            return lhs.cost < rhs.cost
        }

        guard let bestMatch else {
            return (windows, nil)
        }

        let presetFrames = Self.zones(from: bestMatch.preset).map(\.frame)
        let normalizedWindows = zip(windowsWithFrames, bestMatch.assignment).map { entry, assignedIndex in
            entry.0.withRelativeFrame(presetFrames[assignedIndex])
        } + windowsWithoutFrames

        return (normalizedWindows, bestMatch.preset)
    }

    private func bestFrameAssignment(
        sourceFrames: [RelativeWindowFrame],
        targetFrames: [RelativeWindowFrame]
    ) -> [Int]? {
        guard sourceFrames.count == targetFrames.count else { return nil }

        var bestAssignment: [Int]? = nil
        var bestCost = Double.greatestFiniteMagnitude
        var currentAssignment: [Int] = []
        var usedTargetIndices: Set<Int> = []

        func search(_ sourceIndex: Int, _ runningCost: Double) {
            if sourceIndex == sourceFrames.count {
                if runningCost < bestCost {
                    bestCost = runningCost
                    bestAssignment = currentAssignment
                }
                return
            }

            for targetIndex in targetFrames.indices where !usedTargetIndices.contains(targetIndex) {
                let nextCost = runningCost + frameDistance(sourceFrames[sourceIndex], targetFrames[targetIndex])
                if nextCost >= bestCost {
                    continue
                }

                usedTargetIndices.insert(targetIndex)
                currentAssignment.append(targetIndex)
                search(sourceIndex + 1, nextCost)
                currentAssignment.removeLast()
                usedTargetIndices.remove(targetIndex)
            }
        }

        search(0, 0)
        return bestAssignment
    }

    private func frameDistance(_ lhs: RelativeWindowFrame, _ rhs: RelativeWindowFrame) -> Double {
        abs(lhs.xPercent - rhs.xPercent)
            + abs(lhs.yPercent - rhs.yPercent)
            + abs(lhs.widthPercent - rhs.widthPercent)
            + abs(lhs.heightPercent - rhs.heightPercent)
    }

    private func inferredLayoutPreset(for frames: [RelativeWindowFrame]) -> LayoutPreset? {
        let normalizedFrames = normalizedFrameKeys(for: frames)

        return LayoutPreset.allCases.first { preset in
            let presetFrames = Self.zones(from: preset).map(\.frame)
            return normalizedFrameKeys(for: presetFrames) == normalizedFrames
        }
    }

    private func normalizedFrameKeys(for frames: [RelativeWindowFrame]) -> [String] {
        frames
            .map { "\($0.xPercent)-\($0.yPercent)-\($0.widthPercent)-\($0.heightPercent)" }
            .sorted()
    }

    private func makeDraftWindow(from window: WorkspaceWindow) -> DraftWindow {
        let bundleId = window.bundleIdentifier
        let appInfo = findAppInfo(bundleOrPath: bundleId)
            ?? AppInfo(
                name: window.appName,
                bundleIdentifier: bundleId,
                path: window.applicationPath ?? bundleId,
                icon: nil
            )

        let chromeProfile: String?
        if BundleRegistry.isChrome(bundleId) {
            if window.chromeState?.profileMatchMode == .anyWindow {
                chromeProfile = anyChromeWindowMarker
            } else {
                chromeProfile = window.chromeState?.profileDirectory
            }
        } else {
            chromeProfile = nil
        }

        let tabs = window.chromeState?.savedTabURLs ?? []
        let shouldRestoreTabs = window.chromeState?.shouldRestoreTabs ?? !tabs.isEmpty

        return DraftWindow(
            id: window.id,
            appInfo: appInfo,
            bundleId: bundleId,
            windowTitle: window.windowTitle,
            chromeProfile: chromeProfile,
            shouldRestoreTabs: shouldRestoreTabs,
            chromeTabs: tabs,
            openPath: window.openPath ?? ""
        )
    }

    private func fallbackRelativeFrames(count: Int) -> [RelativeWindowFrame] {
        guard count > 0 else { return [] }
        let columns = Int(ceil(sqrt(Double(count))))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let cellWidth = 1.0 / Double(columns)
        let cellHeight = 1.0 / Double(rows)

        var frames: [RelativeWindowFrame] = []
        for index in 0..<count {
            let row = index / columns
            let column = index % columns
            let insetX = cellWidth * 0.1
            let insetY = cellHeight * 0.1
            let width = cellWidth * 0.8
            let height = cellHeight * 0.8
            let x = Double(column) * cellWidth + insetX
            let y = Double(row) * cellHeight + insetY
            frames.append(RelativeWindowFrame(xPercent: x, yPercent: y, widthPercent: width, heightPercent: height))
        }
        return frames
    }

    private func buildWorkspaceWindows(displaySlots: [WorkspaceDisplaySlot]) -> [WorkspaceWindow] {
        var result: [WorkspaceWindow] = []
        let saveOrder = Self.normalizedSaveOrder(
            screens: screens,
            currentDisplays: currentDisplays,
            screenAssignments: screenAssignments
        )
        let slotByDraftIndex = Dictionary(
            uniqueKeysWithValues: saveOrder.enumerated().map { saveIndex, draftIndex in
                (draftIndex, displaySlots[saveIndex])
            }
        )
        let saveIndexByDraftIndex = Self.normalizedSaveIndexMap(
            screens: screens,
            currentDisplays: currentDisplays,
            screenAssignments: screenAssignments
        )

        for (screenIndex, layout) in layouts.enumerated() {
            for zone in layout.zones {
                let folderGroupID = zone.assignedWindowIDs.count > 1 ? zone.id : nil

                for (folderOrder, windowId) in zone.assignedWindowIDs.enumerated() {
                    guard let window = windowsById[windowId] else { continue }

                    let bundleId = window.bundleId
                    let appInfo = window.appInfo

                    var chromeState: ChromeWindowState? = nil
                    if BundleRegistry.isChrome(bundleId) {
                        let selectedProfile = window.chromeProfile ?? ""
                        let profile = chromeProfileManager.profile(forDirectory: selectedProfile)
                        let tabURLs = window.shouldRestoreTabs ? window.chromeTabs : []
                        let matchMode: ChromeProfileMatchMode = selectedProfile.isEmpty || selectedProfile == anyChromeWindowMarker ? .anyWindow : .specific

                        chromeState = ChromeWindowState(
                            profileDirectory: selectedProfile == anyChromeWindowMarker ? "" : selectedProfile,
                            profileDisplayName: profile?.appleScriptDisplayName ?? "",
                            profileHostedDomain: profile?.hostedDomain,
                            profileMatchMode: matchMode,
                            shouldRestoreTabs: !tabURLs.isEmpty,
                            savedTabURLs: tabURLs,
                            focusedTabIndex: nil,
                            chromeWindowId: nil
                        )
                    }

                    let trimmedPath = window.openPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    let openPath = trimmedPath.isEmpty ? nil : trimmedPath

                    let workspaceWindow = WorkspaceWindow(
                        bundleIdentifier: bundleId,
                        appName: appInfo.name,
                        windowTitle: window.windowTitle,
                        openPath: openPath,
                        applicationPath: appInfo.path,
                        chromeState: chromeState,
                        folderGroupID: folderGroupID,
                        folderOrder: folderGroupID == nil ? nil : folderOrder,
                        displaySlotID: slotByDraftIndex[screenIndex]?.id,
                        screenIndex: saveIndexByDraftIndex[screenIndex] ?? screenIndex,
                        relativeFrame: zone.frame
                    )

                    result.append(workspaceWindow)
                }
            }
        }

        return result
    }

    private func buildWorkspaceDisplaySlots() -> [WorkspaceDisplaySlot] {
        let saveOrder = Self.normalizedSaveOrder(
            screens: screens,
            currentDisplays: currentDisplays,
            screenAssignments: screenAssignments
        )

        return saveOrder.map { index in
            let screen = screens[index]
            if let assignedDisplay = currentDisplay(for: index) {
                return WorkspaceDisplaySlot(
                    screen: assignedDisplay,
                    title: screen.title
                )
            }

            return WorkspaceDisplaySlot(
                id: screen.id,
                title: screen.title,
                displayID: screen.displayID,
                displayName: screen.displayName,
                resolution: screen.resolution,
                arrangementFrame: screen.frame,
                visibleFrame: screen.visibleFrame,
                isPrimary: screen.isPrimary,
                displayFingerprint: screen.displayFingerprint
            )
        }
    }

    static func normalizedSaveOrder(
        screens: [DraftScreen],
        currentDisplays: [FullScreenInfo],
        screenAssignments: [Int: Int]
    ) -> [Int] {
        screens.indices.sorted { lhs, rhs in
            let lhsFrame = arrangementFrame(
                for: lhs,
                screens: screens,
                currentDisplays: currentDisplays,
                screenAssignments: screenAssignments
            )
            let rhsFrame = arrangementFrame(
                for: rhs,
                screens: screens,
                currentDisplays: currentDisplays,
                screenAssignments: screenAssignments
            )

            if lhsFrame.minX != rhsFrame.minX {
                return lhsFrame.minX < rhsFrame.minX
            }
            if lhsFrame.minY != rhsFrame.minY {
                return lhsFrame.minY > rhsFrame.minY
            }
            return lhs < rhs
        }
    }

    static func normalizedSaveIndexMap(
        screens: [DraftScreen],
        currentDisplays: [FullScreenInfo],
        screenAssignments: [Int: Int]
    ) -> [Int: Int] {
        Dictionary(
            uniqueKeysWithValues: normalizedSaveOrder(
                screens: screens,
                currentDisplays: currentDisplays,
                screenAssignments: screenAssignments
            ).enumerated().map { saveIndex, draftIndex in
                (draftIndex, saveIndex)
            }
        )
    }

    private static func arrangementFrame(
        for screenIndex: Int,
        screens: [DraftScreen],
        currentDisplays: [FullScreenInfo],
        screenAssignments: [Int: Int]
    ) -> CGRect {
        guard screens.indices.contains(screenIndex) else { return .zero }
        if let currentDisplayIndex = screenAssignments[screenIndex],
           currentDisplays.indices.contains(currentDisplayIndex) {
            return currentDisplays[currentDisplayIndex].frame
        }
        return screens[screenIndex].frame
    }

    static func zones(from preset: LayoutPreset) -> [DraftZone] {
        var zones: [DraftZone] = []
        for index in 0..<preset.windowCount {
            zones.append(
                DraftZone(
                    id: UUID(),
                    frame: preset.relativeFrame(for: index),
                    assignedWindowIDs: []
                )
            )
        }
        return zones
    }

    private func supportsMultipleInstances(_ bundleId: String) -> Bool {
        BundleRegistry.isTerminal(bundleId) || BundleRegistry.isIDE(bundleId) || BundleRegistry.isChrome(bundleId)
    }

    func applyOpenPathToAllOpenByPathWindows(path: String) {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        for window in windowsById.values {
            guard BundleRegistry.isTerminal(window.bundleId) || BundleRegistry.isIDE(window.bundleId) else { continue }
            updateWindow(window.id) { updated in
                updated.openPath = trimmedPath
            }
        }
    }

    private func refreshScreenTitles() {
        for index in screens.indices {
            screens[index].title = "Monitor \(index + 1)"
        }
    }

    private func nextUnassignedCurrentDisplayIndex() -> Int? {
        let assignedDisplayIndices = Set(screenAssignments.values)
        return currentDisplays.indices.first { !assignedDisplayIndices.contains($0) }
    }

    private func assignPrimaryToLeftmostConnectedScreen() {
        guard !screens.isEmpty else { return }
        let connectedIndices = screens.indices.filter { currentDisplay(for: $0) != nil }
        let candidates = connectedIndices.isEmpty ? Array(screens.indices) : connectedIndices

        let primaryIndex = candidates.min { lhs, rhs in
            let lhsFrame = arrangementFrame(for: lhs)
            let rhsFrame = arrangementFrame(for: rhs)
            if lhsFrame.minX != rhsFrame.minX {
                return lhsFrame.minX < rhsFrame.minX
            }
            if lhsFrame.minY != rhsFrame.minY {
                return lhsFrame.minY > rhsFrame.minY
            }
            return lhs < rhs
        } ?? 0

        for index in screens.indices {
            screens[index].isPrimary = index == primaryIndex
        }
    }
}
