//  WindowHandleResolver.swift
//  DeskJigShared

import Foundation
import CoreGraphics

public enum WindowHandleResolver {
    public static func preferredStrategy(for match: ExpWindowMatch) -> AXMatchingStrategy {
        switch match.method {
        case .bentoTitle:
            return .titleOnly
        case .documentPath, .titlePattern:
            return (match.window.title?.isEmpty == false) ? .frameAndTitle : .frameOnly
        default:
            return .frameOnly
        }
    }

    public static func preferredStrategy(
        workspaceWindow: WorkspaceWindow,
        snapshotWindow: SnapshotWindow
    ) -> AXMatchingStrategy {
        if workspaceWindow.windowTitle.hasPrefix("\(BundleIdentity.terminalTitleTokenPrefix):") ||
           workspaceWindow.windowTitle.contains(BundleRegistry.managedTmuxWindowTitle) {
            return .titleOnly
        }

        // Ghostty and Terminal.app tmux launches often surface a window with an
        // empty title before frame/title metadata stabilizes. Matching by PID's
        // first AX window is more reliable than frame-only in that phase.
        if (snapshotWindow.bundleId == BundleRegistry.ghostty ||
            snapshotWindow.bundleId == BundleRegistry.terminal),
           snapshotWindow.title?.isEmpty != false {
            return .pidFirstWindow
        }

        if snapshotWindow.title?.isEmpty == false {
            return .frameAndTitle
        }

        return .frameOnly
    }

    public static func resolve(
        windowId: CGWindowID,
        preferredStrategy: AXMatchingStrategy,
        filter: WindowFilterOptions = .all
    ) -> WindowHandle? {
        if let handle = Window.find(windowId: windowId, axMatchStrategy: preferredStrategy, filter: filter) {
            return handle
        }

        if preferredStrategy != .frameOnly {
            return Window.find(windowId: windowId, axMatchStrategy: .frameOnly, filter: filter)
        }

        return nil
    }
}

