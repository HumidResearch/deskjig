//  MenuConfiguration.swift
//  DeskJig

//  Configuration-based menu system for Action Panel
//

import Foundation
import DeskJigShared
import KeyboardShortcuts

// MARK: - Action Registry

/// Defines all available actions that can be triggered from the menu
enum MenuAction: String, Codable, CaseIterable {
    // Window Actions
    case closeWindow = "window.close"
    case closeApplication = "window.closeApp"
    case hideWindow = "window.hide"
    case minimizeWindow = "window.minimize"
    case restoreWindow = "window.restore"
    case activateWindow = "window.activate"
    case moveWindowLeft = "window.moveLeft"
    case moveWindowRight = "window.moveRight"
    case moveWindowUp = "window.moveUp"
    case moveWindowDown = "window.moveDown"
    case centerWindow = "window.center"
    case maximizeWindow = "window.maximize"
    case moveWindowToLeftHalf = "window.leftHalf"
    case moveWindowToRightHalf = "window.rightHalf"
    case moveWindowToTopHalf = "window.topHalf"
    case moveWindowToBottomHalf = "window.bottomHalf"
    case moveWindowToLeftThird = "window.leftThird"
    case moveWindowToCenterThird = "window.centerThird"
    case moveWindowToRightThird = "window.rightThird"
    case moveWindowToTopLeftQuarter = "window.topLeftQuarter"
    case moveWindowToTopRightQuarter = "window.topRightQuarter"
    case moveWindowToBottomLeftQuarter = "window.bottomLeftQuarter"
    case moveWindowToBottomRightQuarter = "window.bottomRightQuarter"
    case hideAllWindows = "window.hideAll"
    case unhideAllWindows = "window.unhideAll"
    case minimizeAllWindows = "window.minimizeAll"

    // Tiling Actions
    case tileSideBySide = "tiling.sideBySide"
    case tileTopBottom = "tiling.topBottom"
    case tileQuarters = "tiling.quarters"

    // Workspace Actions
    case createWorkspace = "workspace.create"
    case saveWorkspace = "workspace.save"
    case deleteWorkspace = "workspace.delete"
    case renameWorkspace = "workspace.rename"
    case editWorkspace = "workspace.edit"
    case openWorkspace = "workspace.open"
    case restoreWorkspace = "workspace.restore"
    case restoreWorkspaceWithMapping = "workspace.restoreWithMapping"
    case reloadWorkspaces = "workspace.reload"

    // Directory Workspace Actions
    case createDirectoryWorkspace = "directoryWorkspace.create"
    case openDirectoryWorkspace = "directoryWorkspace.open"
    case editDirectoryWorkspace = "directoryWorkspace.edit"
    case deleteDirectoryWorkspace = "directoryWorkspace.delete"

    // App Actions
    case openSettings = "app.settings"
    case quit = "app.quit"
    case about = "app.about"
    case checkForUpdates = "app.checkUpdates"

    // Custom Actions (with parameters)
    case custom = "custom"

}

// MARK: - Post-Action Behavior
extension MenuAction {
    
    /// Defines what should happen to the menu after an action is executed
    enum PostActionBehavior {
        /// Keep menu expanded (e.g., window controls)
        case stayOpen
        /// Deselect sections but stay expanded (e.g., create workspace)/
        case collapseToRoot
        /// Fully close/collapse the menu (e.g., zones, workspace restore)
        case close
    }

    /// Returns the post-action behavior for this action.
    /// This is the ONLY place you need to update when changing behavior rules!
    var postActionBehavior: PostActionBehavior {
        switch self {
        case .openSettings, .openWorkspace, .restoreWorkspace, .restoreWorkspaceWithMapping, .openDirectoryWorkspace, .editWorkspace: .close
        case .createWorkspace: .close
        case .createDirectoryWorkspace: .collapseToRoot
        default: .stayOpen
        }
    }
}

// MARK: - Keyboard Shortcut Integration
extension MenuAction {
    /// Returns the KeyboardShortcuts.Name associated with this menu action for display purposes.
    var shortcutName: KeyboardShortcuts.Name? {
        switch self {
        case .moveWindowToLeftHalf: .moveWindowToLeftHalf
        case .moveWindowToRightHalf: .moveWindowToRightHalf
        case .moveWindowToLeftThird: .moveWindowToLeftThird
        case .moveWindowToCenterThird: .moveWindowToCenterThird
        case .moveWindowToRightThird: .moveWindowToRightThird
        case .moveWindowToTopHalf: .moveWindowToTopHalf
        case .moveWindowToBottomHalf: .moveWindowToBottomHalf
        case .moveWindowToTopLeftQuarter: .moveWindowToTopLeftQuarter
        case .moveWindowToTopRightQuarter: .moveWindowToTopRightQuarter
        case .moveWindowToBottomLeftQuarter: .moveWindowToBottomLeftQuarter
        case .moveWindowToBottomRightQuarter: .moveWindowToBottomRightQuarter
        case .hideWindow: .hideApp
        case .hideAllWindows: .hideAllApps
        case .unhideAllWindows: .showAllApps
        default: nil
        }
    }
}

/// Parameters that can be passed to actions
struct ActionParameters: Codable {
    var workspaceName: String?
    var workspaceID: Workspace.ID?
    var customHandler: String?
    var layoutTemplate: String?
    var directoryWorkspaceID: UUID?
    var directoryWorkspaceName: String?

    var workspace: Workspace? = nil

    init(
        workspaceName: String? = nil,
        workspaceID: Workspace.ID? = nil,
        customHandler: String? = nil,
        layoutTemplate: String? = nil,
        directoryWorkspaceID: UUID? = nil,
        directoryWorkspaceName: String? = nil
    ) {
        self.workspaceName = workspaceName
        self.workspaceID = workspaceID
        self.customHandler = customHandler
        self.layoutTemplate = layoutTemplate
        self.directoryWorkspaceID = directoryWorkspaceID
        self.directoryWorkspaceName = directoryWorkspaceName
        self.workspace = nil
    }

    init(
        workspace: Workspace
    ) {
        self.workspaceName = workspace.name
        self.workspaceID = workspace.id
        self.customHandler = nil
        self.layoutTemplate = nil
        self.directoryWorkspaceID = nil
        self.directoryWorkspaceName = nil
        self.workspace = workspace
    }

    enum CodingKeys: String, CodingKey {
        case workspaceName
        case workspaceID = "workspaceId" // we can remove this but leaving it here for compatibility
        case customHandler
        case layoutTemplate
        case directoryWorkspaceID = "sessionId"
        case directoryWorkspaceName = "sessionName"
    }
}

// MARK: - Menu Configuration Models

/// A menu item that can be either a branch (reveals submenu) or leaf (executes action)
struct MenuItem: Codable, Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: MenuIcon?
    let type: MenuItemType
    let children: [MenuItem]?
    let contextAction: ContextAction?
    let action: MenuAction?
    let actionParameters: ActionParameters?
    let visibilityRule: MenuVisibilityRule?
    let shortcuts: [String]?
    
    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        icon: MenuIcon? = nil,
        type: MenuItemType,
        children: [MenuItem]? = nil,
        contextAction: ContextAction? = nil,
        action: MenuAction? = nil,
        actionParameters: ActionParameters? = nil,
        visibilityRule: MenuVisibilityRule? = nil,
        shortcuts: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.type = type
        self.children = children
        self.contextAction = contextAction
        self.action = action
        self.actionParameters = actionParameters
        self.visibilityRule = visibilityRule
        self.shortcuts = shortcuts
    }

    enum MenuItemType: String, Codable {
        case branch  // Has children
        case leaf    // Executes action
        case separator
        case dynamic // Populated at runtime (e.g., list of workspaces)
    }

    struct MenuIcon: Codable {
        let type: IconType
        let value: String

        enum IconType: String, Codable {
            case systemImage  // SF Symbol
            case emoji
            case custom
        }
    }
    
    /// A small, singular contextual action to display next to a menu item on hover
    struct ContextAction: Codable, Identifiable {
        let id: String
        let title: String
        let subtitle: String?
        let icon: MenuIcon
        let action: MenuAction
        let actionParameters: ActionParameters?
    }

    struct MenuVisibilityRule: Codable {
        /// The condition that should be tested to determine if the menu should be visible.
        let condition: Condition
        /// The value to test related to the condition, if any.
        let value: String?
        
        enum Condition: String, Codable, Sendable, Hashable {
            /// Indicates that the user has one or more workspaces.
            case hasWorkspaces
            /// Indicates that there is a focused window.
            case isWindowFocused
            /// Indicates that the user has multiple screens.
            case hasMultipleScreens
        }
        
        /// Indicates that the user has one or more workspaces.
        static let hasWorkspaces: MenuVisibilityRule = .init(condition: .hasWorkspaces, value: nil)
        /// Indicates that there is a focused window.
        static let isWindowFocused: MenuVisibilityRule = .init(condition: .isWindowFocused, value: nil)
        /// Indicates that the user has multiple screens.
        static let hasMultipleScreens: MenuVisibilityRule = .init(condition: .hasMultipleScreens, value: nil)
    }
}

/// Root configuration structure
struct MenuConfiguration: Codable {
    let version: String
    let rootItems: [MenuItem]
    let settings: MenuSettings?

    struct MenuSettings: Codable {
        let theme: String?
        let animationSpeed: Double?
        let maxRecentWorkspaces: Int?
        let enableKeyboardShortcuts: Bool?
        let autoCloseDelaySeconds: Double?
    }
}

// MARK: - Example Configurations
// Uncomment to view config examples
//extension MenuConfiguration {
//
//    /// Default menu structure
//    static let defaultConfiguration = MenuConfiguration(
//        version: "1.0",
//        rootItems: [
//            MenuItem(
//                id: "workspaces",
//                title: "Workspaces",
//                subtitle: "Manage your layouts",
//                icon: MenuItem.MenuIcon(type: .systemImage, value: "rectangle.grid.2x2"),
//                type: .branch,
//                children: [
//                    MenuItem(
//                        id: "workspaces.list",
//                        title: "Saved Workspaces",
//                        subtitle: nil,
//                        icon: nil,
//                        type: .dynamic,  // Populated at runtime
//                        children: nil,
//                        contextAction: nil,
//                        action: nil,
//                        actionParameters: nil,
//                        visibilityRule: .hasWorkspaces,
//                        shortcuts: nil
//                    ),
//                    MenuItem(
//                        id: "workspaces.create",
//                        title: "Create Workspace",
//                        subtitle: "Save current layout",
//                        icon: MenuItem.MenuIcon(type: .systemImage, value: "plus"),
//                        type: .leaf,
//                        children: nil,
//                        contextAction: nil,
//                        action: .createWorkspace,
//                        actionParameters: nil,
//                        visibilityRule: nil,
//                        shortcuts: ["cmd+n"]
//                    ),
//                    MenuItem(
//                        id: "workspaces.reload",
//                        title: "Reload Workspaces",
//                        subtitle: "Refresh workspace list",
//                        icon: MenuItem.MenuIcon(type: .systemImage, value: "arrow.clockwise"),
//                        type: .leaf,
//                        children: nil,
//                        contextAction: nil,
//                        action: .reloadWorkspaces,
//                        actionParameters: nil,
//                        visibilityRule: nil,
//                        shortcuts: nil
//                    )
//                ],
//                contextAction: nil,
//                action: nil,
//                actionParameters: nil,
//                visibilityRule: nil,
//                shortcuts: ["cmd+w"]
//            ),
//            MenuItem(
//                id: "windows",
//                title: "Window Control",
//                subtitle: "Manage active windows",
//                icon: MenuItem.MenuIcon(type: .systemImage, value: "macwindow"),
//                type: .branch,
//                children: [
//                    MenuItem(
//                        id: "windows.positioning",
//                        title: "Position Window",
//                        subtitle: nil,
//                        icon: MenuItem.MenuIcon(type: .systemImage, value: "arrow.up.left.and.arrow.down.right"),
//                        type: .branch,
//                        children: [
//                            MenuItem(
//                                id: "windows.left",
//                                title: "Move Left",
//                                subtitle: nil,
//                                icon: MenuItem.MenuIcon(type: .systemImage, value: "arrow.left"),
//                                type: .leaf,
//                                children: nil,
//                                contextAction: nil,
//                                action: .moveWindowLeft,
//                                actionParameters: nil,
//                                visibilityRule: .isWindowFocused,
//                                shortcuts: ["cmd+shift+left"]
//                            ),
//                            MenuItem(
//                                id: "windows.right",
//                                title: "Move Right",
//                                subtitle: nil,
//                                icon: MenuItem.MenuIcon(type: .systemImage, value: "arrow.right"),
//                                type: .leaf,
//                                children: nil,
//                                contextAction: nil,
//                                action: .moveWindowRight,
//                                actionParameters: nil,
//                                visibilityRule: .isWindowFocused,
//                                shortcuts: ["cmd+shift+right"]
//                            ),
//                            MenuItem(
//                                id: "windows.center",
//                                title: "Center Window",
//                                subtitle: nil,
//                                icon: MenuItem.MenuIcon(type: .systemImage, value: "scope"),
//                                type: .leaf,
//                                children: nil,
//                                contextAction: nil,
//                                action: .centerWindow,
//                                actionParameters: nil,
//                                visibilityRule: .isWindowFocused,
//                                shortcuts: ["cmd+shift+c"]
//                            ),
//                            MenuItem(
//                                id: "windows.maximize",
//                                title: "Maximize Window",
//                                subtitle: nil,
//                                icon: MenuItem.MenuIcon(type: .systemImage, value: "arrow.up.left.and.arrow.down.right.square"),
//                                type: .leaf,
//                                children: nil,
//                                contextAction: nil,
//                                action: .maximizeWindow,
//                                actionParameters: nil,
//                                visibilityRule: .isWindowFocused,
//                                shortcuts: ["cmd+shift+return"]
//                            )
//                        ],
//                        contextAction: nil,
//                        action: nil,
//                        actionParameters: nil,
//                        visibilityRule: nil,
//                        shortcuts: nil
//                    ),
//                    MenuItem(
//                        id: "windows.visibility",
//                        title: "Visibility",
//                        subtitle: nil,
//                        icon: MenuItem.MenuIcon(type: .systemImage, value: "eye"),
//                        type: .branch,
//                        children: [
//                            MenuItem(
//                                id: "windows.hide",
//                                title: "Hide Window",
//                                subtitle: nil,
//                                icon: MenuItem.MenuIcon(type: .systemImage, value: "eye.slash"),
//                                type: .leaf,
//                                children: nil,
//                                contextAction: nil,
//                                action: .hideWindow,
//                                actionParameters: nil,
//                                visibilityRule: nil,
//                                shortcuts: ["cmd+h"]
//                            ),
//                            MenuItem(
//                                id: "windows.minimize",
//                                title: "Minimize Window",
//                                subtitle: nil,
//                                icon: MenuItem.MenuIcon(type: .systemImage, value: "minus.rectangle"),
//                                type: .leaf,
//                                children: nil,
//                                contextAction: nil,
//                                action: .minimizeWindow,
//                                actionParameters: nil,
//                                visibilityRule: nil,
//                                shortcuts: ["cmd+m"]
//                            )
//                        ],
//                        contextAction: nil,
//                        action: nil,
//                        actionParameters: nil,
//                        visibilityRule: nil,
//                        shortcuts: nil
//                    )
//                ],
//                contextAction: nil,
//                action: nil,
//                actionParameters: nil,
//                visibilityRule: nil,
//                shortcuts: nil
//            ),
//            MenuItem(
//                id: "settings",
//                title: "Settings",
//                subtitle: "Configure DeskJig",
//                icon: MenuItem.MenuIcon(type: .systemImage, value: "gear"),
//                type: .leaf,
//                children: nil,
//                contextAction: nil,
//                action: .openSettings,
//                actionParameters: nil,
//                visibilityRule: nil,
//                shortcuts: ["cmd+,"]
//            )
//        ],
//        settings: MenuSettings(
//            theme: "default",
//            animationSpeed: 0.3,
//            maxRecentWorkspaces: 10,
//            enableKeyboardShortcuts: true
//        )
//    )
//
//    /// Minimalist configuration - fewer options
//    static let minimalistConfiguration = MenuConfiguration(
//        version: "1.0",
//        rootItems: [
//            MenuItem(
//                id: "workspaces",
//                title: "Workspaces",
//                subtitle: nil,
//                icon: MenuItem.MenuIcon(type: .emoji, value: "📁"),
//                type: .dynamic,
//                children: nil,
//                contextAction: nil,
//                action: nil,
//                actionParameters: nil,
//                visibilityRule: nil,
//                shortcuts: nil
//            ),
//            MenuItem(
//                id: "settings",
//                title: "Settings",
//                subtitle: nil,
//                icon: MenuItem.MenuIcon(type: .systemImage, value: "gear"),
//                type: .leaf,
//                children: nil,
//                contextAction: nil,
//                action: .openSettings,
//                actionParameters: nil,
//                visibilityRule: nil,
//                shortcuts: nil
//            )
//        ],
//        settings: nil
//    )
//}

