//  DeskJigAppResolver.swift
//  DeskJigCLI

import DeskJigShared
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Shared helper for resolving the running DeskJig.app and opening URLs via it.
/// Used by NotifyCommand and QuickSwitch to target the correct app bundle.
enum DeskJigAppResolver {

    struct RunningDeskJigApp {
        let pid: Int32
        let bundlePath: String
        let version: String?
        let launchDate: Date?
    }

    /// Running DeskJig.app instances, most recently launched first.
    static func runningDeskJigApps() -> [RunningDeskJigApp] {
        #if canImport(AppKit)
        return NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == BundleIdentity.bundleID }
            .compactMap { app -> RunningDeskJigApp? in
                guard let bundleURL = app.bundleURL else { return nil }
                let path = standardizedPath(bundleURL.path)
                let version = Bundle(url: bundleURL)?
                    .infoDictionary?["CFBundleShortVersionString"] as? String
                return RunningDeskJigApp(
                    pid: app.processIdentifier,
                    bundlePath: path,
                    version: version,
                    launchDate: app.launchDate
                )
            }
            .sorted { ($0.launchDate ?? .distantPast) > ($1.launchDate ?? .distantPast) }
        #else
        return []
        #endif
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Returns the enclosing DeskJig.app for the currently running deskjig binary, if any.
    /// This is the strongest signal for which build the CLI intends to target.
    private static func currentExecutableDeskJigAppPath() -> String? {
        var currentURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()

        if currentURL.pathExtension == "app",
           currentURL.lastPathComponent == "DeskJig.app" {
            return currentURL.standardizedFileURL.path
        }

        while currentURL.path != "/" {
            currentURL.deleteLastPathComponent()
            if currentURL.pathExtension == "app",
               currentURL.lastPathComponent == "DeskJig.app" {
                return currentURL.standardizedFileURL.path
            }
        }

        return nil
    }

    private static func repoLocalDeskJigAppPath() -> String? {
        let fm = FileManager.default
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = execURL.deletingLastPathComponent()

        for _ in 0..<8 {
            let workspace = dir.appendingPathComponent("DeskJig.xcworkspace")
            if fm.fileExists(atPath: workspace.path) {
                let localApp = dir
                    .appendingPathComponent("build/DerivedData/Build/Products/Debug/DeskJig.app")
                if fm.fileExists(atPath: localApp.path) {
                    return localApp.standardizedFileURL.path
                }
                break
            }
            dir.deleteLastPathComponent()
        }

        return nil
    }

    private static func derivedDataDeskJigAppPaths() -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let derivedData = home.appendingPathComponent("Library/Developer/Xcode/DerivedData")

        guard let contents = try? fm.contentsOfDirectory(
            at: derivedData,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return []
        }

        return contents
            .filter { $0.lastPathComponent.hasPrefix("DeskJig-") }
            .compactMap { dir -> (path: String, date: Date)? in
                let app = dir.appendingPathComponent("Build/Products/Debug/DeskJig.app")
                guard fm.fileExists(atPath: app.path),
                      let attrs = try? fm.attributesOfItem(atPath: app.path),
                      let mod = attrs[.modificationDate] as? Date else { return nil }
                return (app.standardizedFileURL.path, mod)
            }
            .sorted { $0.date > $1.date }
            .map(\.path)
    }

    /// Find the best DeskJig.app to target.
    /// Priority:
    /// 1) The DeskJig.app enclosing the current deskjig binary
    /// 2) A running DeskJig.app whose bundle path matches one of our preferred candidates
    /// 3) Repo-local build output
    /// 4) Any other running DeskJig.app (most recently launched first)
    /// 5) Newest DeskJig.app in Xcode DerivedData
    static func findDeskJigApp() -> String? {
        let currentAppPath = currentExecutableDeskJigAppPath()

        if let currentAppPath {
            return currentAppPath
        }

        let repoLocalAppPath = repoLocalDeskJigAppPath()
        let preferredCandidates = [
            repoLocalAppPath
        ].compactMap { $0 }.map(standardizedPath)

        #if canImport(AppKit)
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == BundleIdentity.bundleID }
            .compactMap { app -> (path: String, launchDate: Date?)? in
                guard let bundleURL = app.bundleURL else { return nil }
                return (standardizedPath(bundleURL.path), app.launchDate)
            }
            .sorted { lhs, rhs in
                switch (lhs.launchDate, rhs.launchDate) {
                case let (l?, r?):
                    return l > r
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return lhs.path < rhs.path
                }
            }

        if let preferredRunning = runningApps.first(where: { preferredCandidates.contains($0.path) }) {
            return preferredRunning.path
        }

        if let running = runningApps.first {
            return running.path
        }
        #endif

        if let repoLocalAppPath {
            return repoLocalAppPath
        }

        return derivedDataDeskJigAppPaths().first
    }

    /// Open a URL via the resolved DeskJig.app, avoiding generic Launch Services routing.
    static func openDeskJigURL(_ url: URL) async throws {
        let env = ProcessInfo.processInfo.environment
        if env["BENTOCTL_CAPTURE_OPEN_URL_STDOUT"] == "1" {
            print(url.absoluteString)
            fflush(stdout)
            return
        }

        #if canImport(AppKit)
        if let appPath = findDeskJigApp() {
            let appURL = URL(fileURLWithPath: appPath)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config) { _, error in
                    if let error {
                        continuation.resume(throwing: DeskJigAppResolverError.explicitAppOpenFailed(
                            appPath: appPath,
                            underlying: error.localizedDescription
                        ))
                    } else {
                        continuation.resume()
                    }
                }
            }
            return
        }
        #endif

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw DeskJigAppResolverError.openFailed(exitCode: process.terminationStatus)
        }
    }
}

enum DeskJigAppResolverError: LocalizedError {
    case openFailed(exitCode: Int32)
    case explicitAppOpenFailed(appPath: String, underlying: String)
    case explicitAppOpenTimedOut(appPath: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let exitCode):
            return "Failed to open DeskJig URL (exit code \(exitCode))"
        case .explicitAppOpenFailed(let appPath, let underlying):
            return "Failed to open DeskJig URL with \(appPath): \(underlying)"
        case .explicitAppOpenTimedOut(let appPath):
            return "Timed out opening DeskJig URL with \(appPath)"
        }
    }
}
