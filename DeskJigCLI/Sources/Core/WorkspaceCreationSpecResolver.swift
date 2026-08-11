//  WorkspaceCreationSpecResolver.swift
//  DeskJigCLI

import Foundation
import DeskJigShared

enum WorkspaceCreationSpecResolver {
    enum ResolutionError: Error, Equatable {
        case message(String)

        var message: String {
            switch self {
            case .message(let message):
                return message
            }
        }
    }

    struct AppDescriptor: Equatable {
        let bundleId: String
        let appName: String

        var defaultWindowTitle: String { appName }
    }

    enum ResolutionResult {
        case success(Workspace)
        case failure(String)
    }

    private static let knownAppsByAlias: [String: AppDescriptor] = [
        "ghostty": AppDescriptor(bundleId: OpenByPathBundleIdentifiers.ghostty, appName: "Ghostty"),
        "terminal": AppDescriptor(bundleId: OpenByPathBundleIdentifiers.terminal, appName: "Terminal"),
        "iterm": AppDescriptor(bundleId: OpenByPathBundleIdentifiers.iterm2, appName: "iTerm2"),
        "iterm2": AppDescriptor(bundleId: OpenByPathBundleIdentifiers.iterm2, appName: "iTerm2"),
        "kitty": AppDescriptor(bundleId: OpenByPathBundleIdentifiers.kitty, appName: "kitty"),
        "alacritty": AppDescriptor(bundleId: OpenByPathBundleIdentifiers.alacritty, appName: "Alacritty"),
        "cursor": AppDescriptor(bundleId: OpenByPathBundleIdentifiers.cursor, appName: "Cursor"),
        "codex": AppDescriptor(bundleId: OpenByPathBundleIdentifiers.codex, appName: "Codex"),
        "vscode": AppDescriptor(bundleId: OpenByPathBundleIdentifiers.vscode, appName: "VS Code"),
        "xcode": AppDescriptor(bundleId: OpenByPathBundleIdentifiers.xcode, appName: "Xcode")
    ]

    private static let knownAppsByBundleId: [String: AppDescriptor] = knownAppsByAlias.values.reduce(into: [:]) { partialResult, descriptor in
        partialResult[descriptor.bundleId] = descriptor
    }

    static func resolve(
        spec: WorkspaceCreationSpec,
        displayManager: DisplayManager,
        replacing existingWorkspace: Workspace? = nil
    ) -> ResolutionResult {
        let trimmedName = spec.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return .failure("Workspace name must not be empty.")
        }

        guard !spec.windows.isEmpty else {
            return .failure("Workspace spec must include at least one window.")
        }

        displayManager.refreshScreens()
        let currentScreens = displayManager.screens
        guard !currentScreens.isEmpty else {
            return .failure("No displays detected; cannot create a saved workspace.")
        }
        let savedScreens = currentScreens.map { WorkspaceScreen(from: $0) }

        var resolvedWindows: [WorkspaceWindow] = []
        resolvedWindows.reserveCapacity(spec.windows.count)

        for (index, windowSpec) in spec.windows.enumerated() {
            let appResolution = resolveAppDescriptor(
                bundleId: windowSpec.bundleId,
                appAlias: Optional<String>.none,
                appName: windowSpec.appName
            )

            let appDescriptor: AppDescriptor
            switch appResolution {
            case .success(let resolved):
                appDescriptor = resolved
            case .failure(let error):
                return .failure("Window [\(index)]: \(error.message)")
            }

            let openPath: String?
            switch normalizeOpenPath(windowSpec.openPath) {
            case .success(let normalized):
                openPath = normalized
            case .failure(let error):
                return .failure("Window [\(index)]: \(error.message)")
            }

            let screenIndex: Int?
            switch resolveScreenIndex(windowSpec.screen, screens: currentScreens) {
            case .success(let resolved):
                screenIndex = resolved
            case .failure(let error):
                return .failure("Window [\(index)]: \(error.message)")
            }

            let relativeFrame: RelativeWindowFrame
            switch resolveRelativeFrame(windowSpec.layout) {
            case .success(let frame):
                relativeFrame = frame
            case .failure(let error):
                return .failure("Window [\(index)]: \(error.message)")
            }

            let title = windowSpec.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let workspaceWindow = WorkspaceWindow(
                bundleIdentifier: appDescriptor.bundleId,
                appName: appDescriptor.appName,
                windowTitle: (title?.isEmpty == false ? title! : appDescriptor.defaultWindowTitle),
                openPath: openPath,
                applicationPath: nil,
                chromeState: nil,
                screenIndex: screenIndex,
                relativeFrame: relativeFrame
            )
            resolvedWindows.append(workspaceWindow)
        }

        let titledWindows = OpenByPathTitleAssigner.apply(to: resolvedWindows)

        let workspace: Workspace
        if let existingWorkspace {
            workspace = Workspace.migrated(
                id: existingWorkspace.id,
                name: trimmedName,
                icon: spec.icon,
                createdAt: existingWorkspace.createdAt,
                lastActivatedAt: existingWorkspace.lastActivatedAt,
                windows: titledWindows,
                screens: savedScreens,
                isFavorite: existingWorkspace.isFavorite
            )
        } else {
            workspace = Workspace(
                name: trimmedName,
                icon: spec.icon,
                keyboardShortcut: nil,
                workspaceWindows: titledWindows,
                screens: savedScreens
            )
        }

        return .success(workspace)
    }

    static func resolveAppDescriptor(
        bundleId: String?,
        appAlias: String?,
        appName: String?
    ) -> Result<AppDescriptor, ResolutionError> {
        let trimmedBundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAppAlias = appAlias?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedAppName = appName?.trimmingCharacters(in: .whitespacesAndNewlines)

        let aliasDescriptor = trimmedAppAlias.flatMap { knownAppsByAlias[$0] }
        if trimmedAppAlias != nil && aliasDescriptor == nil {
            return .failure(.message("Unknown app alias '\(trimmedAppAlias!)'."))
        }

        let canonicalFromBundleId = trimmedBundleId.flatMap { knownAppsByBundleId[$0] }

        if let trimmedBundleId, let aliasDescriptor, aliasDescriptor.bundleId != trimmedBundleId {
            return .failure(.message("bundleId '\(trimmedBundleId)' does not match alias '\(trimmedAppAlias!)'."))
        }

        if let trimmedBundleId, let trimmedAppName, let canonical = canonicalFromBundleId,
           !namesMatch(lhs: trimmedAppName, rhs: canonical.appName) {
            return .failure(.message("bundleId '\(trimmedBundleId)' does not match appName '\(trimmedAppName)'."))
        }

        if let aliasDescriptor, let trimmedAppName,
           !namesMatch(lhs: trimmedAppName, rhs: aliasDescriptor.appName) {
            return .failure(.message("app alias '\(trimmedAppAlias!)' does not match appName '\(trimmedAppName)'."))
        }

        if let canonical = canonicalFromBundleId {
            return .success(AppDescriptor(
                bundleId: canonical.bundleId,
                appName: trimmedAppName ?? canonical.appName
            ))
        }

        if let aliasDescriptor {
            return .success(AppDescriptor(
                bundleId: aliasDescriptor.bundleId,
                appName: trimmedAppName ?? aliasDescriptor.appName
            ))
        }

        if let trimmedBundleId {
            let inferredAppName = trimmedAppName ?? inferredAppName(fromBundleId: trimmedBundleId)
            return .success(AppDescriptor(bundleId: trimmedBundleId, appName: inferredAppName))
        }

        if let trimmedAppName {
            if let canonical = knownAppsByAlias[trimmedAppName.lowercased()] {
                return .success(canonical)
            }
            return .failure(.message("appName '\(trimmedAppName)' is not a supported alias. Provide bundleId for custom apps."))
        }

        return .failure(.message("Specify bundleId, app alias, or appName."))
    }

    private static func resolveScreenIndex(
        _ screenTarget: WorkspaceCreationScreenTarget?,
        screens: [FullScreenInfo]
    ) -> Result<Int?, ResolutionError> {
        guard let screenTarget else { return .success(nil) }

        switch screenTarget {
        case .index(let index):
            guard screens.indices.contains(index) else {
                return .failure(.message("screen index \(index) is out of range (0-\(max(screens.count - 1, 0)))."))
            }
            return .success(index)
        case .displayID(let displayID):
            guard let matchedIndex = screens.firstIndex(where: { $0.displayID == displayID }) else {
                return .failure(.message("No display found for displayID \(displayID)."))
            }
            return .success(matchedIndex)
        case .primary:
            return .success(screens.firstIndex(where: \.isPrimary) ?? 0)
        }
    }

    private static func resolveRelativeFrame(
        _ layout: WorkspaceCreationLayoutSpec
    ) -> Result<RelativeWindowFrame, ResolutionError> {
        switch layout {
        case .preset(let preset):
            guard let windowPosition = DeskJigShared.WindowPosition.parse(preset) else {
                return .failure(.message("Unknown layout preset '\(preset)'."))
            }
            return .success(windowPosition.toRelativeFrame())
        case .relativeFrame(let frame):
            guard frame.widthPercent > 0, frame.heightPercent > 0 else {
                return .failure(.message("Explicit relative frame widthPercent and heightPercent must be greater than 0."))
            }
            guard frame.xPercent >= 0, frame.yPercent >= 0,
                  frame.widthPercent <= 1, frame.heightPercent <= 1 else {
                return .failure(.message("Explicit relative frame percentages must be between 0 and 1."))
            }
            guard frame.xPercent + frame.widthPercent <= 1.0001,
                  frame.yPercent + frame.heightPercent <= 1.0001 else {
                return .failure(.message("Explicit relative frame must fit within the visible screen bounds."))
            }
            return .success(RelativeWindowFrame(
                xPercent: frame.xPercent,
                yPercent: frame.yPercent,
                widthPercent: frame.widthPercent,
                heightPercent: frame.heightPercent
            ))
        }
    }

    private static func normalizeOpenPath(_ path: String?) -> Result<String?, ResolutionError> {
        guard let path else { return .success(nil) }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .success(nil) }

        let normalized = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: normalized) else {
            return .failure(.message("openPath does not exist: \(normalized)"))
        }

        return .success(normalized)
    }

    private static func namesMatch(lhs: String, rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive]) == .orderedSame
    }

    private static func inferredAppName(fromBundleId bundleId: String) -> String {
        if let canonical = knownAppsByBundleId[bundleId] {
            return canonical.appName
        }

        let suffix = bundleId.split(separator: ".").last.map(String.init) ?? bundleId
        return suffix
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
