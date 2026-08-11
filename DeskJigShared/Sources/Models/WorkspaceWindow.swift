//  WorkspaceWindow.swift
//  DeskJigShared

import Foundation
import CoreGraphics

public struct WorkspaceWindow: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let bundleIdentifier: String
    public let appName: String
    public let windowTitle: String
    /// Stable identifier for terminal window identity across captures/restores.
    public let terminalKey: String?
    /// Optional directory path to open this window in (e.g. project folder for IDE/terminal).
    public let openPath: String?
    public let applicationPath: String?
    public let chromeState: ChromeWindowState?
    public let tmuxState: TmuxSessionState?
    public let folderGroupID: UUID?
    public let folderOrder: Int?
    /// Stable display slot identity for geometry-first workspace restoration.
    public let displaySlotID: UUID?
    public let screenIndex: Int? // The index of the screen in the screens array
    public let relativeFrame: RelativeWindowFrame? // Window position as percentages of screen

    public var hasDisplayAssignmentMetadata: Bool {
        displaySlotID != nil || screenIndex != nil
    }

    public init(
        bundleIdentifier: String,
        appName: String,
        windowTitle: String,
        terminalKey: String? = nil,
        openPath: String? = nil,
        applicationPath: String? = nil,
        chromeState: ChromeWindowState? = nil,
        tmuxState: TmuxSessionState? = nil,
        folderGroupID: UUID? = nil,
        folderOrder: Int? = nil,
        displaySlotID: UUID? = nil,
        screenIndex: Int? = nil,
        relativeFrame: RelativeWindowFrame? = nil
    ) {
        self.id = UUID()
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.terminalKey = terminalKey
        self.openPath = openPath
        self.applicationPath = applicationPath
        self.chromeState = chromeState
        self.tmuxState = tmuxState
        self.folderGroupID = folderGroupID
        self.folderOrder = folderOrder
        self.displaySlotID = displaySlotID
        self.screenIndex = screenIndex
        self.relativeFrame = relativeFrame
    }

    public init(
        id: UUID,
        bundleIdentifier: String,
        appName: String,
        windowTitle: String,
        terminalKey: String? = nil,
        openPath: String? = nil,
        applicationPath: String? = nil,
        chromeState: ChromeWindowState? = nil,
        tmuxState: TmuxSessionState? = nil,
        folderGroupID: UUID? = nil,
        folderOrder: Int? = nil,
        displaySlotID: UUID? = nil,
        screenIndex: Int? = nil,
        relativeFrame: RelativeWindowFrame? = nil
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.terminalKey = terminalKey
        self.openPath = openPath
        self.applicationPath = applicationPath
        self.chromeState = chromeState
        self.tmuxState = tmuxState
        self.folderGroupID = folderGroupID
        self.folderOrder = folderOrder
        self.displaySlotID = displaySlotID
        self.screenIndex = screenIndex
        self.relativeFrame = relativeFrame
    }

    // Custom decoder for backward compatibility
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        appName = try container.decode(String.self, forKey: .appName)
        windowTitle = try container.decode(String.self, forKey: .windowTitle)
        terminalKey = try container.decodeIfPresent(String.self, forKey: .terminalKey)

        // Backward compatibility - these might not exist in older saves
        openPath = try container.decodeIfPresent(String.self, forKey: .openPath)
        applicationPath = try container.decodeIfPresent(String.self, forKey: .applicationPath)
        chromeState = try container.decodeIfPresent(ChromeWindowState.self, forKey: .chromeState)
        tmuxState = try container.decodeIfPresent(TmuxSessionState.self, forKey: .tmuxState)
        folderGroupID = try container.decodeIfPresent(UUID.self, forKey: .folderGroupID)
        folderOrder = try container.decodeIfPresent(Int.self, forKey: .folderOrder)
        displaySlotID = try container.decodeIfPresent(UUID.self, forKey: .displaySlotID)
        screenIndex = try container.decodeIfPresent(Int.self, forKey: .screenIndex)
        relativeFrame = try container.decodeIfPresent(RelativeWindowFrame.self, forKey: .relativeFrame)

        // Note: Deprecated keys (frame, displayID) in CodingKeys are automatically ignored during decoding
    }

    // Custom encoder to only encode current properties (not deprecated ones)
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(id, forKey: .id)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(appName, forKey: .appName)
        try container.encode(windowTitle, forKey: .windowTitle)
        try container.encodeIfPresent(terminalKey, forKey: .terminalKey)
        try container.encodeIfPresent(openPath, forKey: .openPath)
        try container.encodeIfPresent(applicationPath, forKey: .applicationPath)
        try container.encodeIfPresent(chromeState, forKey: .chromeState)
        try container.encodeIfPresent(tmuxState, forKey: .tmuxState)
        try container.encodeIfPresent(folderGroupID, forKey: .folderGroupID)
        try container.encodeIfPresent(folderOrder, forKey: .folderOrder)
        try container.encodeIfPresent(displaySlotID, forKey: .displaySlotID)
        if displaySlotID == nil {
            try container.encodeIfPresent(screenIndex, forKey: .screenIndex)
        }
        try container.encodeIfPresent(relativeFrame, forKey: .relativeFrame)

        // Note: frame and displayID are NOT encoded (deprecated)
    }

    private enum CodingKeys: String, CodingKey {
        case id, bundleIdentifier, appName, windowTitle, terminalKey, openPath, applicationPath, chromeState, tmuxState, folderGroupID, folderOrder, displaySlotID, screenIndex, relativeFrame
        // Deprecated keys kept for backward compatibility with old workspaces
        case frame, displayID
    }

    // Create a copy with updated window title
    public func withWindowTitle(_ newTitle: String) -> WorkspaceWindow {
        WorkspaceWindow(
            id: self.id,
            bundleIdentifier: self.bundleIdentifier,
            appName: self.appName,
            windowTitle: newTitle,
            terminalKey: self.terminalKey,
            openPath: self.openPath,
            applicationPath: self.applicationPath,
            chromeState: self.chromeState,
            tmuxState: self.tmuxState,
            folderGroupID: self.folderGroupID,
            folderOrder: self.folderOrder,
            displaySlotID: self.displaySlotID,
            screenIndex: self.screenIndex,
            relativeFrame: self.relativeFrame
        )
    }

    // Create a copy with updated open path
    public func withOpenPath(_ newOpenPath: String?) -> WorkspaceWindow {
        WorkspaceWindow(
            id: self.id,
            bundleIdentifier: self.bundleIdentifier,
            appName: self.appName,
            windowTitle: self.windowTitle,
            terminalKey: self.terminalKey,
            openPath: newOpenPath,
            applicationPath: self.applicationPath,
            chromeState: self.chromeState,
            tmuxState: self.tmuxState,
            folderGroupID: self.folderGroupID,
            folderOrder: self.folderOrder,
            displaySlotID: self.displaySlotID,
            screenIndex: self.screenIndex,
            relativeFrame: self.relativeFrame
        )
    }

    // Create a copy with updated Chrome state
    public func withChromeState(_ newChromeState: ChromeWindowState?) -> WorkspaceWindow {
        WorkspaceWindow(
            id: self.id,
            bundleIdentifier: self.bundleIdentifier,
            appName: self.appName,
            windowTitle: self.windowTitle,
            terminalKey: self.terminalKey,
            openPath: self.openPath,
            applicationPath: self.applicationPath,
            chromeState: newChromeState,
            tmuxState: self.tmuxState,
            folderGroupID: self.folderGroupID,
            folderOrder: self.folderOrder,
            displaySlotID: self.displaySlotID,
            screenIndex: self.screenIndex,
            relativeFrame: self.relativeFrame
        )
    }

    // Create a copy with updated tmux state
    public func withTmuxState(_ newTmuxState: TmuxSessionState?) -> WorkspaceWindow {
        WorkspaceWindow(
            id: self.id,
            bundleIdentifier: self.bundleIdentifier,
            appName: self.appName,
            windowTitle: self.windowTitle,
            terminalKey: self.terminalKey,
            openPath: self.openPath,
            applicationPath: self.applicationPath,
            chromeState: self.chromeState,
            tmuxState: newTmuxState,
            folderGroupID: self.folderGroupID,
            folderOrder: self.folderOrder,
            displaySlotID: self.displaySlotID,
            screenIndex: self.screenIndex,
            relativeFrame: self.relativeFrame
        )
    }

    // Create a copy with updated relative frame
    public func withRelativeFrame(_ newRelativeFrame: RelativeWindowFrame?) -> WorkspaceWindow {
        WorkspaceWindow(
            id: self.id,
            bundleIdentifier: self.bundleIdentifier,
            appName: self.appName,
            windowTitle: self.windowTitle,
            terminalKey: self.terminalKey,
            openPath: self.openPath,
            applicationPath: self.applicationPath,
            chromeState: self.chromeState,
            tmuxState: self.tmuxState,
            folderGroupID: self.folderGroupID,
            folderOrder: self.folderOrder,
            displaySlotID: self.displaySlotID,
            screenIndex: self.screenIndex,
            relativeFrame: newRelativeFrame
        )
    }

    // Create a copy with optional updates to multiple fields (for screen remapping)
    public func withScreenMapping(
        screenIndex: Int? = nil
    ) -> WorkspaceWindow {
        WorkspaceWindow(
            id: self.id,
            bundleIdentifier: self.bundleIdentifier,
            appName: self.appName,
            windowTitle: self.windowTitle,
            terminalKey: self.terminalKey,
            openPath: self.openPath,
            applicationPath: self.applicationPath,
            chromeState: self.chromeState,
            tmuxState: self.tmuxState,
            folderGroupID: self.folderGroupID,
            folderOrder: self.folderOrder,
            displaySlotID: self.displaySlotID,
            screenIndex: screenIndex ?? self.screenIndex,
            relativeFrame: self.relativeFrame
        )
    }

    public func withDisplaySlotID(_ displaySlotID: UUID?) -> WorkspaceWindow {
        WorkspaceWindow(
            id: self.id,
            bundleIdentifier: self.bundleIdentifier,
            appName: self.appName,
            windowTitle: self.windowTitle,
            terminalKey: self.terminalKey,
            openPath: self.openPath,
            applicationPath: self.applicationPath,
            chromeState: self.chromeState,
            tmuxState: self.tmuxState,
            folderGroupID: self.folderGroupID,
            folderOrder: self.folderOrder,
            displaySlotID: displaySlotID,
            screenIndex: self.screenIndex,
            relativeFrame: self.relativeFrame
        )
    }

    public func preservingDisplayAssignment(from other: WorkspaceWindow) -> WorkspaceWindow {
        var updated = self

        if updated.displaySlotID == nil, let displaySlotID = other.displaySlotID {
            updated = updated.withDisplaySlotID(displaySlotID)
        }

        if updated.screenIndex == nil, let screenIndex = other.screenIndex {
            updated = updated.withScreenMapping(screenIndex: screenIndex)
        }

        return updated
    }

    // Create a copy with updated terminal key
    public func withTerminalKey(_ newTerminalKey: String?) -> WorkspaceWindow {
        WorkspaceWindow(
            id: self.id,
            bundleIdentifier: self.bundleIdentifier,
            appName: self.appName,
            windowTitle: self.windowTitle,
            terminalKey: newTerminalKey,
            openPath: self.openPath,
            applicationPath: self.applicationPath,
            chromeState: self.chromeState,
            tmuxState: self.tmuxState,
            folderGroupID: self.folderGroupID,
            folderOrder: self.folderOrder,
            displaySlotID: self.displaySlotID,
            screenIndex: self.screenIndex,
            relativeFrame: self.relativeFrame
        )
    }

    public func withFolderMetadata(groupID: UUID?, order: Int?) -> WorkspaceWindow {
        WorkspaceWindow(
            id: self.id,
            bundleIdentifier: self.bundleIdentifier,
            appName: self.appName,
            windowTitle: self.windowTitle,
            terminalKey: self.terminalKey,
            openPath: self.openPath,
            applicationPath: self.applicationPath,
            chromeState: self.chromeState,
            tmuxState: self.tmuxState,
            folderGroupID: groupID,
            folderOrder: order,
            displaySlotID: self.displaySlotID,
            screenIndex: self.screenIndex,
            relativeFrame: self.relativeFrame
        )
    }
}
