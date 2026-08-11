//
//  AppURLHelper.swift
//  DeskJig
//

import Foundation
import DeskJigShared

enum AppURLHelper {
    static func injectChromeURL(
        _ urlString: String,
        into workspace: Workspace,
        forceChrome: Bool = true
    ) -> (workspace: Workspace, mode: AppDelegate.ChromeURLInjectionMode) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            return (workspace, .invalidURL)
        }

        if let chromeWindow = workspace.windows.first(where: { BundleRegistry.isChrome($0.bundleIdentifier) }) {
            var urls = chromeWindow.chromeState?.savedTabURLs ?? []
            let focusedTabIndex: Int
            if let existingIndex = urls.firstIndex(where: { ChromeAutomationService.urlsAreEquivalent(trimmedURL, $0) }) {
                focusedTabIndex = existingIndex + 1
            } else {
                urls.append(trimmedURL)
                focusedTabIndex = urls.count
            }

            let newChromeState = ChromeWindowState(
                profileDirectory: chromeWindow.chromeState?.profileDirectory ?? "Default",
                profileDisplayName: chromeWindow.chromeState?.profileDisplayName ?? "Default",
                profileHostedDomain: chromeWindow.chromeState?.profileHostedDomain,
                profileUserName: chromeWindow.chromeState?.profileUserName,
                profileMatchMode: chromeWindow.chromeState?.profileMatchMode ?? .anyWindow,
                shouldRestoreTabs: true,
                savedTabURLs: urls,
                focusedTabIndex: focusedTabIndex,
                chromeWindowId: chromeWindow.chromeState?.chromeWindowId
            )
            let updatedWindow = chromeWindow.withChromeState(newChromeState)
            return (workspace.withUpdatedWindow(updatedWindow), .reusedExistingChrome)
        }

        if !forceChrome {
            return (workspace, .skippedNoChrome)
        }

        let preferredScreenIndex = workspace.windows.compactMap(\.screenIndex).first ?? 0
        let chromeState = ChromeWindowState(
            profileDirectory: "Default",
            profileDisplayName: "Default",
            profileMatchMode: .anyWindow,
            shouldRestoreTabs: true,
            savedTabURLs: [trimmedURL],
            focusedTabIndex: 1
        )
        let newWindow = WorkspaceWindow(
            bundleIdentifier: BundleRegistry.chrome,
            appName: "Google Chrome",
            windowTitle: trimmedURL,
            chromeState: chromeState,
            screenIndex: preferredScreenIndex,
            relativeFrame: RelativeWindowFrame(
                xPercent: 0.15,
                yPercent: 0.10,
                widthPercent: 0.70,
                heightPercent: 0.80
            )
        )
        return (workspace.withNewWindows(workspace.windows + [newWindow]), .addedForcedChrome)
    }

    static func openFileViaProcess(_ filePath: String) {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

            let ideApps = ["Cursor", "Visual Studio Code", "Xcode"]
            let fileManager = FileManager.default
            for ide in ideApps {
                let appPath = "/Applications/\(ide).app"
                if fileManager.fileExists(atPath: appPath) {
                    DeskJigLog.info(.app, "Opening file", fields: ["ide": ide, "filePath": filePath])
                    process.arguments = ["-a", ide, filePath]
                    try process.run()
                    return
                }
            }

            DeskJigLog.info(.app, "Opening file with default text editor", fields: ["filePath": filePath])
            process.arguments = ["-t", filePath]
            try process.run()
        } catch {
            DeskJigLog.error(.app, "Failed to open file", fields: ["filePath": filePath, "error": error.localizedDescription])
        }
    }

    static func resolveSettingsSection(from url: URL) -> SettingsSidebarSection? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let sectionValue = components.queryItems?.first(where: { $0.name == "section" })?.value
        else {
            return nil
        }

        return SettingsSidebarSection(rawValue: sectionValue)
    }
}
