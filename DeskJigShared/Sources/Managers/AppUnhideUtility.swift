//
//  AppUnhideUtility.swift
//  DeskJigShared
//
//  Shared utility for unhiding all running applications.
//  Used by action bar, CLI, and workspace restoration.
//

import Foundation
import AppKit

// MARK: - Options & Results

/// Options for unhiding apps
public struct UnhideAllOptions: Sendable {
    /// Whether to log verbose per-app details
    public let verbose: Bool

    public init(verbose: Bool = true) {
        self.verbose = verbose
    }

    /// Default options for action bar unhide-all
    public static let actionBar = UnhideAllOptions(verbose: true)
}

/// Result of a single app unhide attempt
public struct AppUnhideResult: Sendable {
    public let bundleId: String
    public let appName: String
    public let pid: pid_t
    public let success: Bool
    public let method: String // "nsrunningapplication", "skipped", "failed"
    public let skipped: Bool
    public let skipReason: String?
}

/// Aggregated result of unhiding all apps
public struct UnhideAllResult: Sendable {
    public let appsTargeted: Int
    public let appsUnhidden: Int
    public let appsFailed: Int
    public let appsSkipped: Int
    public let durationMs: Int
    public let perAppResults: [AppUnhideResult]

    public var unhiddenAppNames: [String] {
        perAppResults.filter { $0.success && !$0.skipped }.map { $0.appName }
    }

    public var failedAppNames: [String] {
        perAppResults.filter { !$0.success && !$0.skipped }.map { $0.appName }
    }

    public var skippedAppNames: [String] {
        perAppResults.filter { $0.skipped }.map { $0.appName }
    }
}

// MARK: - AppUnhideUtility

/// Shared utility for unhiding all running applications
public enum AppUnhideUtility {

    /// DeskJig's bundle identifier (hardcoded to ensure CLI also excludes it)
    private static let deskJigBundleId = BundleIdentity.bundleID

    /// Unhide all hidden regular apps (excluding DeskJig)
    /// Uses NSWorkspace.shared.runningApplications to get ALL apps
    ///
    /// - Parameters:
    ///   - options: Configuration options for the unhide operation
    ///   - runId: Optional run ID for logging correlation
    /// - Returns: Result containing counts and per-app details
    public static func unhideAllApps(
        options: UnhideAllOptions = .actionBar,
        runId: String? = nil
    ) async -> UnhideAllResult {
        let startTime = Date()
        let resolvedRunId = runId ?? makeRunId()
        let currentAppBundleId = Bundle.main.bundleIdentifier

        // Get ALL running apps from NSWorkspace
        // Note: NSWorkspace.shared.runningApplications is thread-safe and can be called from any thread.
        // We intentionally avoid MainActor.run here to prevent deadlocks when called via syncCapture
        // (which blocks the main thread with a semaphore).
        let runningApps = NSWorkspace.shared.runningApplications

        // Filter to regular activation policy apps that are hidden
        let hiddenRegularApps = runningApps.filter { app in
            guard app.activationPolicy == .regular,
                  let bundleId = app.bundleIdentifier else {
                return false
            }
            // Exclude DeskJig itself (both hardcoded and current app bundle)
            if bundleId == deskJigBundleId {
                return false
            }
            if let currentAppBundleId, bundleId == currentAppBundleId {
                return false
            }
            // Only include hidden apps
            return app.isHidden
        }

        // Also track visible apps (not hidden) for reporting
        let visibleRegularApps = runningApps.filter { app in
            guard app.activationPolicy == .regular,
                  let bundleId = app.bundleIdentifier else {
                return false
            }
            if bundleId == deskJigBundleId {
                return false
            }
            if let currentAppBundleId, bundleId == currentAppBundleId {
                return false
            }
            return !app.isHidden
        }

        if options.verbose {
            DeskJigLog.info(.app, "[\(resolvedRunId)] AppUnhideUtility: Found \(hiddenRegularApps.count) hidden apps to unhide, \(visibleRegularApps.count) already visible")
        }

        if hiddenRegularApps.isEmpty {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            var results: [AppUnhideResult] = []

            // Add skipped results for visible apps
            for app in visibleRegularApps {
                guard let bundleId = app.bundleIdentifier else { continue }
                results.append(AppUnhideResult(
                    bundleId: bundleId,
                    appName: app.localizedName ?? bundleId,
                    pid: app.processIdentifier,
                    success: false,
                    method: "skipped",
                    skipped: true,
                    skipReason: "already_visible"
                ))
            }

            return UnhideAllResult(
                appsTargeted: hiddenRegularApps.count + visibleRegularApps.count,
                appsUnhidden: 0,
                appsFailed: 0,
                appsSkipped: visibleRegularApps.count,
                durationMs: durationMs,
                perAppResults: results
            )
        }

        // Unhide apps concurrently using TaskGroup
        let unhideResults = await withTaskGroup(of: AppUnhideResult.self) { group in
            for app in hiddenRegularApps {
                guard let bundleId = app.bundleIdentifier else { continue }
                let appName = app.localizedName ?? bundleId
                let pid = app.processIdentifier

                group.addTask {
                    await unhideApp(pid: pid, bundleId: bundleId, appName: appName, runId: resolvedRunId, verbose: options.verbose)
                }
            }

            var results: [AppUnhideResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        // Combine results
        var allResults = unhideResults

        // Add skipped results for visible apps
        for app in visibleRegularApps {
            guard let bundleId = app.bundleIdentifier else { continue }
            allResults.append(AppUnhideResult(
                bundleId: bundleId,
                appName: app.localizedName ?? bundleId,
                pid: app.processIdentifier,
                success: false,
                method: "skipped",
                skipped: true,
                skipReason: "already_visible"
            ))
        }

        let successCount = unhideResults.filter { $0.success }.count
        let failedCount = unhideResults.filter { !$0.success }.count
        let skippedCount = visibleRegularApps.count
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        if options.verbose {
            DeskJigLog.info(.app, "[\(resolvedRunId)] AppUnhideUtility: Completed in \(durationMs)ms - unhidden: \(successCount), failed: \(failedCount), skipped: \(skippedCount)")
        }

        return UnhideAllResult(
            appsTargeted: hiddenRegularApps.count + visibleRegularApps.count,
            appsUnhidden: successCount,
            appsFailed: failedCount,
            appsSkipped: skippedCount,
            durationMs: durationMs,
            perAppResults: allResults
        )
    }

    // MARK: - Private Helpers

    private static func unhideApp(
        pid: pid_t,
        bundleId: String,
        appName: String,
        runId: String,
        verbose: Bool
    ) async -> AppUnhideResult {
        // NSRunningApplication and its methods (hide(), unhide(), isHidden) are thread-safe
        // and can be called from any thread per Apple documentation.
        // We intentionally avoid MainActor.run here to prevent deadlocks when called via syncCapture
        // (which blocks the main thread with a semaphore).
        //
        // NOTE: NSRunningApplication.unhide() return value is unreliable - it often returns false
        // even when the unhide operation succeeds. We verify success by checking isHidden state after
        // a brief delay, since the state doesn't update synchronously.
        guard let runningApp = NSRunningApplication(processIdentifier: pid) else {
            if verbose {
                DeskJigLog.warn(.app, "[\(runId)] Failed to unhide: \(appName) (app not found)")
            }
            return AppUnhideResult(
                bundleId: bundleId,
                appName: appName,
                pid: pid,
                success: false,
                method: "failed",
                skipped: false,
                skipReason: nil
            )
        }

        let wasHidden = runningApp.isHidden
        // Call unhide - ignore return value as it's unreliable
        _ = runningApp.unhide()

        // Wait briefly for the state to update, then verify
        await Task.sleepUnlessCancelled(nanoseconds: 50_000_000) // 50ms

        let isNowHidden = NSRunningApplication(processIdentifier: pid)?.isHidden ?? true
        let didUnhide = wasHidden && !isNowHidden

        if didUnhide {
            if verbose {
                DeskJigLog.debug(.app, "[\(runId)] Unhidden: \(appName) via NSRunningApplication")
            }
            return AppUnhideResult(
                bundleId: bundleId,
                appName: appName,
                pid: pid,
                success: true,
                method: "nsrunningapplication",
                skipped: false,
                skipReason: nil
            )
        }

        // Unhide didn't change state - app may not have been hidden
        if verbose {
            DeskJigLog.warn(.app, "[\(runId)] Failed to unhide: \(appName) (wasHidden: \(wasHidden), isNowHidden: \(isNowHidden))")
        }
        return AppUnhideResult(
            bundleId: bundleId,
            appName: appName,
            pid: pid,
            success: false,
            method: "failed",
            skipped: false,
            skipReason: nil
        )
    }

    private static func makeRunId() -> String {
        "unhide_\(UUID().uuidString.prefix(8))"
    }
}
