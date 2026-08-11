//  Workspace.swift
//  DeskJigShared

import Foundation
import CoreGraphics

public enum WorkspaceLayoutHealth: String, Sendable {
    case healthy
    case legacyFlattened
    case legacyFlattenedBrokenPreview
}

public struct WorkspaceLayoutHealthSummary: Equatable, Sendable {
    public let totalCount: Int
    public let healthyCount: Int
    public let legacyFlattenedCount: Int
    public let legacyFlattenedBrokenPreviewCount: Int

    public init(workspaces: [Workspace]) {
        totalCount = workspaces.count

        var healthyCount = 0
        var legacyFlattenedCount = 0
        var legacyFlattenedBrokenPreviewCount = 0

        for workspace in workspaces {
            switch workspace.layoutHealth {
            case .healthy:
                healthyCount += 1
            case .legacyFlattened:
                legacyFlattenedCount += 1
            case .legacyFlattenedBrokenPreview:
                legacyFlattenedBrokenPreviewCount += 1
            }
        }

        self.healthyCount = healthyCount
        self.legacyFlattenedCount = legacyFlattenedCount
        self.legacyFlattenedBrokenPreviewCount = legacyFlattenedBrokenPreviewCount
    }

    public var flattenedCount: Int {
        legacyFlattenedCount + legacyFlattenedBrokenPreviewCount
    }
}

/// Represents a keyboard shortcut in a codable format
public struct WorkspaceKeyboardShortcut: Codable, Hashable, Sendable {
    public let key: String  // Key code as string (e.g., "1", "a", "leftArrow")
    public let modifiers: [String]  // Modifier keys (e.g., ["command", "shift"])
    
    public init(key: String, modifiers: [String]) {
        self.key = key
        self.modifiers = modifiers
    }
}

public struct Workspace: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let icon: String?
    public let keyboardShortcut: WorkspaceKeyboardShortcut?
    public let createdAt: Date
    public let lastActivatedAt: Date?
    public let updatedAt: Date?
    public let windows: [WorkspaceWindow]
    public let displaySlots: [WorkspaceDisplaySlot]?
    public let screens: [WorkspaceScreen]? // Screens used when creating this workspace
    public let isFavorite: Bool // Whether this workspace is marked as favorite

    public init(
        id: UUID = UUID(),
        name: String,
        icon: String? = nil,
        keyboardShortcut: WorkspaceKeyboardShortcut? = nil,
        workspaceWindows: [WorkspaceWindow],
        displaySlots: [WorkspaceDisplaySlot]? = nil,
        screens: [WorkspaceScreen]? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.keyboardShortcut = keyboardShortcut
        self.createdAt = .now
        self.lastActivatedAt = nil // Will be set when first activated
        self.updatedAt = .now
        self.windows = workspaceWindows
        self.displaySlots = displaySlots
        self.screens = screens ?? displaySlots?.map { $0.asWorkspaceScreen() }
        self.isFavorite = isFavorite
    }

    // Create a copy with a new name
    public func withNewName(_ newName: String) -> Workspace {
        Workspace(
            id: self.id,
            name: newName,
            icon: self.icon,
            keyboardShortcut: self.keyboardShortcut,
            createdAt: self.createdAt,
            lastActivatedAt: self.lastActivatedAt,
            updatedAt: .now,
            windows: self.windows,
            displaySlots: self.displaySlots,
            screens: self.screens,
            isFavorite: self.isFavorite
        )
    }

    // Create a copy with a new icon
    public func withNewIcon(_ newIcon: String) -> Workspace {
        Workspace(
            id: self.id,
            name: self.name,
            icon: newIcon,
            keyboardShortcut: self.keyboardShortcut,
            createdAt: self.createdAt,
            lastActivatedAt: self.lastActivatedAt,
            updatedAt: .now,
            windows: self.windows,
            displaySlots: self.displaySlots,
            screens: self.screens,
            isFavorite: self.isFavorite
        )
    }

    // Create a copy with a new keyboard shortcut
    public func withNewKeyboardShortcut(_ shortcut: WorkspaceKeyboardShortcut?) -> Workspace {
        Workspace(
            id: self.id,
            name: self.name,
            icon: self.icon,
            keyboardShortcut: shortcut,
            createdAt: self.createdAt,
            lastActivatedAt: self.lastActivatedAt,
            updatedAt: .now,
            windows: self.windows,
            displaySlots: self.displaySlots,
            screens: self.screens,
            isFavorite: self.isFavorite
        )
    }

    // Create a copy with updated activation time
    // Note: Preserves updatedAt since activation time is local-only metadata
    public func withActivationTime(_ activationTime: Date) -> Workspace {
        Workspace(
            id: self.id,
            name: self.name,
            icon: self.icon,
            keyboardShortcut: self.keyboardShortcut,
            createdAt: self.createdAt,
            lastActivatedAt: activationTime,
            updatedAt: self.updatedAt,
            windows: self.windows,
            displaySlots: self.displaySlots,
            screens: self.screens,
            isFavorite: self.isFavorite
        )
    }

    // Create a copy with updated windows
    public func withNewWindows(_ windows: [WorkspaceWindow]) -> Workspace {
        Workspace(
            id: self.id,
            name: self.name,
            icon: self.icon,
            keyboardShortcut: self.keyboardShortcut,
            createdAt: self.createdAt,
            lastActivatedAt: self.lastActivatedAt,
            updatedAt: .now,
            windows: windows,
            displaySlots: self.displaySlots,
            screens: self.screens,
            isFavorite: self.isFavorite
        )
    }

    // Create a copy with a specific window updated
    public func withUpdatedWindow(_ updatedWindow: WorkspaceWindow) -> Workspace {
        let updatedWindows = windows.map { window in
            window.id == updatedWindow.id ? updatedWindow : window
        }
        return withNewWindows(updatedWindows)
    }

    // Create a copy with updated windows and screens (used for screen remapping)
    public func withNewWindowsAndScreens(
        _ windows: [WorkspaceWindow],
        screens: [WorkspaceScreen]?,
        displaySlots: [WorkspaceDisplaySlot]? = nil
    ) -> Workspace {
        Workspace(
            id: self.id,
            name: self.name,
            icon: self.icon,
            keyboardShortcut: self.keyboardShortcut,
            createdAt: self.createdAt,
            lastActivatedAt: self.lastActivatedAt,
            updatedAt: .now,
            windows: windows,
            displaySlots: displaySlots ?? self.displaySlots,
            screens: screens,
            isFavorite: self.isFavorite
        )
    }

    public func withResolvedDisplayMetadata(
        _ windows: [WorkspaceWindow],
        screens: [WorkspaceScreen],
        displaySlots: [WorkspaceDisplaySlot],
        preserveUpdatedAt: Bool = true
    ) -> Workspace {
        Workspace(
            id: self.id,
            name: self.name,
            icon: self.icon,
            keyboardShortcut: self.keyboardShortcut,
            createdAt: self.createdAt,
            lastActivatedAt: self.lastActivatedAt,
            updatedAt: preserveUpdatedAt ? self.updatedAt : .now,
            windows: windows,
            displaySlots: displaySlots,
            screens: screens,
            isFavorite: self.isFavorite
        )
    }

    // Create a copy with updated layout, name, and icon
    public func withUpdatedLayout(
        newName: String,
        newIcon: String,
        windows: [WorkspaceWindow],
        screens: [WorkspaceScreen]?,
        displaySlots: [WorkspaceDisplaySlot]? = nil
    ) -> Workspace {
        Workspace(
            id: self.id,
            name: newName,
            icon: newIcon,
            keyboardShortcut: self.keyboardShortcut,
            createdAt: self.createdAt,
            lastActivatedAt: self.lastActivatedAt,
            updatedAt: .now,
            windows: windows,
            displaySlots: displaySlots ?? self.displaySlots,
            screens: screens,
            isFavorite: self.isFavorite
        )
    }

    /// Create a copy with explicit updatedAt timestamp
    public func withUpdatedTime(_ time: Date) -> Workspace {
        Workspace(
            id: self.id,
            name: self.name,
            icon: self.icon,
            keyboardShortcut: self.keyboardShortcut,
            createdAt: self.createdAt,
            lastActivatedAt: self.lastActivatedAt,
            updatedAt: time,
            windows: self.windows,
            displaySlots: self.displaySlots,
            screens: self.screens,
            isFavorite: self.isFavorite
        )
    }

    /// Create a workspace with explicit metadata (used for migrations).
    public static func migrated(
        id: UUID,
        name: String,
        icon: String?,
        createdAt: Date,
        lastActivatedAt: Date?,
        windows: [WorkspaceWindow],
        displaySlots: [WorkspaceDisplaySlot]? = nil,
        screens: [WorkspaceScreen]?,
        isFavorite: Bool = false
    ) -> Workspace {
        Workspace(
            id: id,
            name: name,
            icon: icon,
            keyboardShortcut: nil,
            createdAt: createdAt,
            lastActivatedAt: lastActivatedAt,
            updatedAt: nil,
            windows: windows,
            displaySlots: displaySlots,
            screens: screens,
            isFavorite: isFavorite
        )
    }

    // Private initializer for creating copies
    private init(
        id: UUID,
        name: String,
        icon: String?,
        keyboardShortcut: WorkspaceKeyboardShortcut?,
        createdAt: Date,
        lastActivatedAt: Date?,
        updatedAt: Date?,
        windows: [WorkspaceWindow],
        displaySlots: [WorkspaceDisplaySlot]?,
        screens: [WorkspaceScreen]?,
        isFavorite: Bool
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.keyboardShortcut = keyboardShortcut
        self.createdAt = createdAt
        self.lastActivatedAt = lastActivatedAt
        self.updatedAt = updatedAt
        self.windows = windows
        self.displaySlots = displaySlots
        self.screens = screens ?? displaySlots?.map { $0.asWorkspaceScreen() }
        self.isFavorite = isFavorite
    }

    // Create a copy with favorite toggled
    public func withFavoriteToggled() -> Workspace {
        Workspace(
            id: self.id,
            name: self.name,
            icon: self.icon,
            keyboardShortcut: self.keyboardShortcut,
            createdAt: self.createdAt,
            lastActivatedAt: self.lastActivatedAt,
            updatedAt: .now,
            windows: self.windows,
            displaySlots: self.displaySlots,
            screens: self.screens,
            isFavorite: !self.isFavorite
        )
    }

    public var hasSavedDisplayMetadata: Bool {
        let hasWorkspaceGeometry = (displaySlots?.isEmpty == false) || (screens?.isEmpty == false)
        return hasWorkspaceGeometry || windows.contains(where: \.hasDisplayAssignmentMetadata)
    }

    public var isDisplayMetadataFlattened: Bool {
        let missingWorkspaceGeometry = (displaySlots?.isEmpty != false) && (screens?.isEmpty != false)
        return missingWorkspaceGeometry && windows.allSatisfy { !$0.hasDisplayAssignmentMetadata }
    }

    public var layoutHealth: WorkspaceLayoutHealth {
        guard isDisplayMetadataFlattened else {
            return .healthy
        }

        if hasBrokenFlattenedPreview {
            return .legacyFlattenedBrokenPreview
        }

        return .legacyFlattened
    }

    public var needsLayoutRepair: Bool {
        layoutHealth == .legacyFlattenedBrokenPreview
    }

    public func preservingDisplayMetadata(from richerWorkspace: Workspace) -> Workspace {
        guard isDisplayMetadataFlattened, richerWorkspace.hasSavedDisplayMetadata else {
            return self
        }

        let repairedWindows = Self.repairDisplayAssignments(
            in: windows,
            using: richerWorkspace.windows
        )

        return Workspace(
            id: self.id,
            name: self.name,
            icon: self.icon,
            keyboardShortcut: self.keyboardShortcut,
            createdAt: self.createdAt,
            lastActivatedAt: self.lastActivatedAt,
            updatedAt: self.updatedAt,
            windows: repairedWindows,
            displaySlots: richerWorkspace.displaySlots,
            screens: richerWorkspace.screens,
            isFavorite: self.isFavorite
        )
    }

    private static func repairDisplayAssignments(
        in incomingWindows: [WorkspaceWindow],
        using richerWindows: [WorkspaceWindow]
    ) -> [WorkspaceWindow] {
        var remainingByID = Dictionary(uniqueKeysWithValues: richerWindows.map { ($0.id, $0) })
        var remainingMatchedIDs = Set<UUID>()

        func normalizedPath(_ path: String?) -> String {
            guard let path, !path.isEmpty else { return "" }
            return URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        }

        func normalizedTitle(_ title: String) -> String {
            title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        func matchKeys(for window: WorkspaceWindow) -> [String] {
            let bundle = window.bundleIdentifier.lowercased()
            let path = normalizedPath(window.openPath)
            let title = normalizedTitle(window.windowTitle)
            let terminalKey = window.terminalKey?.lowercased() ?? ""

            var keys: [String] = []
            if !terminalKey.isEmpty {
                keys.append("terminal|\(bundle)|\(terminalKey)")
            }
            if !path.isEmpty, !title.isEmpty {
                keys.append("bundle-path-title|\(bundle)|\(path)|\(title)")
            }
            if !path.isEmpty {
                keys.append("bundle-path|\(bundle)|\(path)")
            }
            if !title.isEmpty {
                keys.append("bundle-title|\(bundle)|\(title)")
            }
            keys.append("bundle|\(bundle)")
            return keys
        }

        var fallbackBuckets: [String: [WorkspaceWindow]] = [:]
        for richerWindow in richerWindows {
            for key in matchKeys(for: richerWindow) {
                fallbackBuckets[key, default: []].append(richerWindow)
            }
        }

        return incomingWindows.map { incomingWindow in
            guard !incomingWindow.hasDisplayAssignmentMetadata else {
                return incomingWindow
            }

            if let exact = remainingByID[incomingWindow.id] {
                remainingMatchedIDs.insert(exact.id)
                remainingByID.removeValue(forKey: incomingWindow.id)
                return incomingWindow.preservingDisplayAssignment(from: exact)
            }

            for key in matchKeys(for: incomingWindow) {
                guard let candidates = fallbackBuckets[key] else { continue }
                if let matched = candidates.first(where: { !remainingMatchedIDs.contains($0.id) }) {
                    remainingMatchedIDs.insert(matched.id)
                    remainingByID.removeValue(forKey: matched.id)
                    return incomingWindow.preservingDisplayAssignment(from: matched)
                }
            }

            return incomingWindow
        }
    }

    private var hasBrokenFlattenedPreview: Bool {
        let frames = windows.compactMap(\.relativeFrame)
        guard frames.count > 1 else { return false }

        let uniqueFrameCount = Set(frames).count
        if uniqueFrameCount != frames.count {
            return true
        }

        for index in frames.indices {
            for otherIndex in frames.indices where otherIndex > index {
                if Self.overlapArea(between: frames[index], and: frames[otherIndex]) > 0.05 {
                    return true
                }
            }
        }

        return false
    }

    private static func overlapArea(between lhs: RelativeWindowFrame, and rhs: RelativeWindowFrame) -> Double {
        let lhsMaxX = lhs.xPercent + lhs.widthPercent
        let lhsMaxY = lhs.yPercent + lhs.heightPercent
        let rhsMaxX = rhs.xPercent + rhs.widthPercent
        let rhsMaxY = rhs.yPercent + rhs.heightPercent

        let overlapWidth = min(lhsMaxX, rhsMaxX) - max(lhs.xPercent, rhs.xPercent)
        let overlapHeight = min(lhsMaxY, rhsMaxY) - max(lhs.yPercent, rhs.yPercent)

        return max(0, overlapWidth) * max(0, overlapHeight)
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, keyboardShortcut, createdAt, lastActivatedAt, updatedAt, windows, displaySlots, screens, isFavorite
    }

    /// Custom decoder to handle backward compatibility when `isFavorite` is missing
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        keyboardShortcut = try container.decodeIfPresent(WorkspaceKeyboardShortcut.self, forKey: .keyboardShortcut)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastActivatedAt = try container.decodeIfPresent(Date.self, forKey: .lastActivatedAt)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
        let decodedWindows = try container.decode([WorkspaceWindow].self, forKey: .windows)
        let decodedDisplaySlots = try container.decodeIfPresent([WorkspaceDisplaySlot].self, forKey: .displaySlots)
        let decodedScreens = try container.decodeIfPresent([WorkspaceScreen].self, forKey: .screens)
        displaySlots = decodedDisplaySlots
        screens = decodedScreens ?? decodedDisplaySlots?.map { $0.asWorkspaceScreen() }

        if let decodedDisplaySlots {
            let slotOrder = decodedDisplaySlots
            let slotIndexById = Dictionary(uniqueKeysWithValues: slotOrder.enumerated().map { ($0.element.id, $0.offset) })
            windows = decodedWindows.map { window in
                guard window.screenIndex == nil,
                      let displaySlotID = window.displaySlotID else {
                    return window
                }
                return window.withScreenMapping(screenIndex: slotIndexById[displaySlotID])
            }
        } else {
            windows = decodedWindows
        }
        // Default to false for existing workspaces that don't have this field
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(keyboardShortcut, forKey: .keyboardShortcut)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastActivatedAt, forKey: .lastActivatedAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encode(windows, forKey: .windows)
        try container.encodeIfPresent(displaySlots, forKey: .displaySlots)
        // #566: always persist `screens`, even when `displaySlots` is present.
        // Omitting `screens` in slots mode made `displaySlots` a single point of
        // failure: any reader that drops the (newer) `displaySlots` key - e.g. an
        // older app build re-persisting the store - silently lost ALL display
        // geometry, producing workspaces that fail restore normalization with
        // "has no display slot geometry". The decoder still prefers
        // `displaySlots` when both are present.
        try container.encodeIfPresent(screens, forKey: .screens)
        try container.encode(isFavorite, forKey: .isFavorite)
    }
}

// Note: CGRect already conforms to Codable in macOS/iOS
