//
//  ApplicationManager.swift
//  DeskJigShared
//
//  Created by Marco Freedom on 02.09.2025.
//

import Foundation
import AppKit

public protocol ApplicationManagerProtocol: AnyObject {
    var applications: [AppInfo] { get }
    var isLoading: Bool { get }

    func loadApplications()
    func refreshApplications()
    func launchApplication(_ app: AppInfo) -> Bool
    func findApplication(by bundleIdentifier: String) -> AppInfo?
    func isApplicationRunning(bundleIdentifier: String) -> Bool
}

public class ApplicationManager: ObservableObject, ApplicationManagerProtocol {
    @Published public var applications: [AppInfo] = []
    @Published public var isLoading = false

    private let searchDirectories = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/Applications/Utilities",
        ("~/Applications" as NSString).expandingTildeInPath
    ]

    public init() {
        loadApplications()
    }

    public func loadApplications() {
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var apps: [AppInfo] = []
            let fileManager = FileManager.default

            // Search all directories
            for directory in self.searchDirectories {
                guard fileManager.fileExists(atPath: directory) else {
                    DeskJigLog.warn(.app, "Directory does not exist: \(directory)")
                    continue
                }

                do {
                    let contents = try fileManager.contentsOfDirectory(atPath: directory)

                    for item in contents {
                        let fullPath = "\(directory)/\(item)"

                        // Check if it's an application bundle
                        if item.hasSuffix(".app") {
                            var isDirectory: ObjCBool = false
                            if fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) && isDirectory.boolValue {

                                // Get bundle info
                                if let bundle = Bundle(path: fullPath) {
                                    let appName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                                                 bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ??
                                                 item.replacingOccurrences(of: ".app", with: "")

                                    let bundleId = bundle.bundleIdentifier

                                    // Skip duplicates based on bundle identifier
                                    if let bundleId = bundleId,
                                       apps.contains(where: { $0.bundleIdentifier == bundleId }) {
                                        continue
                                    }

                                    // Get app icon
                                    var appIcon: NSImage?
                                    if let iconFileName = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
                                        let iconPath = bundle.path(forResource: iconFileName, ofType: nil) ??
                                                      bundle.path(forResource: iconFileName, ofType: "icns")
                                        if let iconPath = iconPath {
                                            appIcon = NSImage(contentsOfFile: iconPath)
                                        }
                                    }

                                    // Fallback to generic app icon
                                    if appIcon == nil {
                                        appIcon = NSWorkspace.shared.icon(forFile: fullPath)
                                    }

                                    let appInfo = AppInfo(
                                        name: appName,
                                        bundleIdentifier: bundleId,
                                        path: fullPath,
                                        icon: appIcon
                                    )

                                    apps.append(appInfo)
                                } else {
                                    // Fallback for apps without proper bundle structure
                                    let appName = item.replacingOccurrences(of: ".app", with: "")
                                    let appIcon = NSWorkspace.shared.icon(forFile: fullPath)

                                    // Skip duplicates based on path
                                    if apps.contains(where: { $0.path == fullPath }) {
                                        continue
                                    }

                                    let appInfo = AppInfo(
                                        name: appName,
                                        bundleIdentifier: nil,
                                        path: fullPath,
                                        icon: appIcon
                                    )

                                    apps.append(appInfo)
                                }
                            }
                        }
                    }

                } catch {
                    DeskJigLog.error(.app, "Error reading directory \(directory): \(error)")
                }
            }

            // Sort apps alphabetically
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            DispatchQueue.main.async {
                self.applications = apps
                self.isLoading = false
            }
        }
    }

    public func launchApplication(_ app: AppInfo) -> Bool {
        let workspace = NSWorkspace.shared
        
        // Use the modern API
        var success = false
        let semaphore = DispatchSemaphore(value: 0)
        
        workspace.openApplication(at: URL(fileURLWithPath: app.path),
                                 configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error = error {
                DeskJigLog.error(.app, "Failed to launch \(app.name): \(error)")
                success = false
            } else {
                success = true
            }
            semaphore.signal()
        }
        
        // Wait for completion with timeout
        let result = semaphore.wait(timeout: .now() + 5.0)
        if result == .timedOut {
            DeskJigLog.warn(.app, "Timeout launching \(app.name)")
            return false
        }
        
        return success
    }

    public func refreshApplications() {
        loadApplications()
    }

    /// Find application by bundle identifier, including runtime resolution for system apps
    public func findApplication(by bundleIdentifier: String) -> AppInfo? {
        // First check our loaded applications
        if let app = applications.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return app
        }

        // If not found, try to resolve it using NSWorkspace for running apps
        let runningApps = NSWorkspace.shared.runningApplications
        if let runningApp = runningApps.first(where: { $0.bundleIdentifier == bundleIdentifier }),
           let appURL = runningApp.bundleURL {

            let appPath = appURL.path
            let appName = runningApp.localizedName ?? appURL.deletingPathExtension().lastPathComponent
            let appIcon = NSWorkspace.shared.icon(forFile: appPath)

            let appInfo = AppInfo(
                name: appName,
                bundleIdentifier: bundleIdentifier,
                path: appPath,
                icon: appIcon
            )

            // Add to our applications list for future reference
            appendIfMissing(appInfo)

            return appInfo
        }

        // Last resort: try to find it using LaunchServices
        return findApplicationUsingLaunchServices(bundleIdentifier: bundleIdentifier)
    }

    private func findApplicationUsingLaunchServices(bundleIdentifier: String) -> AppInfo? {
        // Use LSCopyApplicationURLsForBundleIdentifier to find the app
        if let appURLs = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?.takeRetainedValue() as? [URL],
           let appURL = appURLs.first {

            let appPath = appURL.path
            let appName = appURL.deletingPathExtension().lastPathComponent
            let appIcon = NSWorkspace.shared.icon(forFile: appPath)

            let appInfo = AppInfo(
                name: appName,
                bundleIdentifier: bundleIdentifier,
                path: appPath,
                icon: appIcon
            )

            // Add to our applications list for future reference
            appendIfMissing(appInfo)

            return appInfo
        }

        return nil
    }
    
    /// Append a runtime-resolved app unless an entry with the same bundle id (or path) already
    /// exists. The presence check must run inside the same main-queue hop as the append: callers
    /// check `applications` on their own thread before dispatching here, so concurrent lookups for
    /// the same app would otherwise each queue their own append and produce duplicate entries.
    private func appendIfMissing(_ appInfo: AppInfo) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let alreadyPresent = self.applications.contains { existing in
                if let bundleId = appInfo.bundleIdentifier {
                    return existing.bundleIdentifier == bundleId
                }
                return existing.path == appInfo.path
            }
            guard !alreadyPresent else { return }
            self.applications.append(appInfo)
        }
    }

    /// Check if an application is currently running
    public func isApplicationRunning(bundleIdentifier: String) -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications
        return runningApps.contains { $0.bundleIdentifier == bundleIdentifier }
    }
}
