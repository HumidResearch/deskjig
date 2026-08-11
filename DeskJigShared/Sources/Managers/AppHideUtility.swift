//
//  AppHideUtility.swift
//  DeskJigShared
//
//  Shared utility for hiding all running applications.
//  Used by action bar, CLI, and workspace restoration.
//

import Foundation
import AppKit

// MARK: - Options & Results

/// Options for hiding apps
public struct HideAllOptions: Sendable {
    /// Whether to skip apps that are part of a workspace
    public let workspaceBundleIds: Set<String>
    /// Minimum window size for apps to be considered (0 = no size filter)
    public let minWindowSize: CGSize
    /// Whether to log verbose per-app details
    public let verbose: Bool
    /// When true, only hide apps with NO windows >= minWindowSize (background-only apps)
    /// When false (default), hide apps WITH windows >= minWindowSize (visible apps)
    public let backgroundOnlyMode: Bool

    public init(
        workspaceBundleIds: Set<String> = [],
        minWindowSize: CGSize = .zero,
        verbose: Bool = true,
        backgroundOnlyMode: Bool = false
    ) {
        self.workspaceBundleIds = workspaceBundleIds
        self.minWindowSize = minWindowSize
        self.verbose = verbose
        self.backgroundOnlyMode = backgroundOnlyMode
    }

    /// Default options for action bar hide-all
    /// Uses 100x100 minimum window size to filter out background apps without visible windows
    public static let actionBar = HideAllOptions(
        workspaceBundleIds: [],
        minWindowSize: CGSize(width: 100, height: 100),
        verbose: true
    )

    /// Hide background-only apps (apps with no windows >= minWindowSize)
    public static let backgroundOnly = HideAllOptions(
        workspaceBundleIds: [],
        minWindowSize: CGSize(width: 100, height: 100),
        verbose: true,
        backgroundOnlyMode: true
    )
}

/// Result of a single app hide attempt
public struct AppHideResult: Sendable {
    public let bundleId: String
    public let appName: String
    public let pid: pid_t
    public let success: Bool
    public let method: String // "nsrunningapplication", "ax", "failed"
    public let skipped: Bool
    public let skipReason: String?
}

/// Aggregated result of hiding all apps
public struct HideAllResult: Sendable {
    public let appsTargeted: Int
    public let appsHidden: Int
    public let appsFailed: Int
    public let appsSkipped: Int
    public let durationMs: Int
    public let perAppResults: [AppHideResult]

    public var hiddenAppNames: [String] {
        perAppResults.filter { $0.success && !$0.skipped }.map { $0.appName }
    }

    public var failedAppNames: [String] {
        perAppResults.filter { !$0.success && !$0.skipped }.map { $0.appName }
    }

    public var skippedAppNames: [String] {
        perAppResults.filter { $0.skipped }.map { $0.appName }
    }
}

// MARK: - AppHideUtility

/// Shared utility for hiding all running applications
public enum AppHideUtility {

    /// Hide all running regular apps (excluding DeskJig and optionally workspace apps)
    /// Uses NSWorkspace.shared.runningApplications to get ALL apps, not just those with visible windows
    ///
    /// - Parameters:
    ///   - options: Configuration options for the hide operation
    ///   - runId: Optional run ID for logging correlation
    /// - Returns: Result containing counts and per-app details
    /// DeskJig's bundle identifier (hardcoded to ensure CLI also excludes it)
    private static let deskJigBundleId = BundleIdentity.bundleID

    public static func hideAllApps(
        options: HideAllOptions = .actionBar,
        runId: String? = nil
    ) async -> HideAllResult {
        let startTime = Date()
        let resolvedRunId = runId ?? makeRunId()
        let currentAppBundleId = Bundle.main.bundleIdentifier

        // Get ALL running apps from NSWorkspace (this catches background apps too)
        // Note: NSWorkspace.shared.runningApplications is thread-safe and can be called from any thread.
        // We intentionally avoid MainActor.run here to prevent deadlocks when called via syncCapture
        // (which blocks the main thread with a semaphore).
        let runningApps = NSWorkspace.shared.runningApplications

        // Filter to regular activation policy apps only
        let regularApps = runningApps.filter { app in
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
            return true
        }

        // If minWindowSize is set, only target apps that have at least one large enough window
        let pidsWithLargeWindows: Set<pid_t>?
        if options.minWindowSize != .zero {
            pidsWithLargeWindows = getPidsWithLargeWindows(minSize: options.minWindowSize)
            if options.verbose {
                DeskJigLog.debug(.app, "[\(resolvedRunId)] AppHideUtility: Found \(pidsWithLargeWindows?.count ?? 0) PIDs with windows >= \(Int(options.minWindowSize.width))x\(Int(options.minWindowSize.height))")
            }
        } else {
            pidsWithLargeWindows = nil
        }

        if options.verbose {
            DeskJigLog.info(.app, "[\(resolvedRunId)] AppHideUtility: Found \(regularApps.count) regular apps to evaluate")
        }

        // Build targets list with skip reasons
        var targets: [HideTarget] = []
        for app in regularApps {
            guard let bundleId = app.bundleIdentifier else { continue }

            let isWorkspaceApp = options.workspaceBundleIds.contains(bundleId)
            let hasLargeWindow = pidsWithLargeWindows == nil || pidsWithLargeWindows!.contains(app.processIdentifier)

            // Determine skip reason (if any)
            // Note: We intentionally do NOT skip apps based on isHidden flag.
            // NSRunningApplication.isHidden can be stale/incorrect - an app may have
            // visible windows but isHidden=true. Calling hide() is idempotent so it's
            // safe to call on already-hidden apps.
            let skipReason: String?
            if isWorkspaceApp {
                skipReason = "workspace_app"
            } else if options.backgroundOnlyMode {
                // Background-only mode: HIDE apps with NO large windows, SKIP apps WITH large windows
                if hasLargeWindow {
                    skipReason = "has_visible_windows"
                } else {
                    skipReason = nil
                }
            } else if !hasLargeWindow {
                skipReason = "no_large_windows"
            } else {
                skipReason = nil
            }

            targets.append(HideTarget(
                pid: app.processIdentifier,
                bundleId: bundleId,
                appName: app.localizedName ?? bundleId,
                isWorkspaceApp: isWorkspaceApp,
                skipReason: skipReason
            ))
        }

        // Filter to apps that need hiding (no skip reason)
        let targetsToHide = targets.filter { $0.skipReason == nil }
        let skippedWorkspaceApps = targets.filter { $0.skipReason == "workspace_app" }
        let noLargeWindowsApps = targets.filter { $0.skipReason == "no_large_windows" }

        if options.verbose {
            DeskJigLog.info(.app, "[\(resolvedRunId)] AppHideUtility: \(targetsToHide.count) apps to hide, \(skippedWorkspaceApps.count) workspace apps skipped, \(noLargeWindowsApps.count) no large windows")
            // Log individual skip reasons for debugging
            for target in noLargeWindowsApps {
                DeskJigLog.debug(.app, "[\(resolvedRunId)] Skipped (no_large_windows): \(target.appName)")
            }
        }

        let totalSkipped = skippedWorkspaceApps.count + noLargeWindowsApps.count

        if targetsToHide.isEmpty {
            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            var results: [AppHideResult] = []

            // Add skipped results for all skip reasons
            for target in targets.filter({ $0.skipReason != nil }) {
                results.append(AppHideResult(
                    bundleId: target.bundleId,
                    appName: target.appName,
                    pid: target.pid,
                    success: false,
                    method: "skipped",
                    skipped: true,
                    skipReason: target.skipReason
                ))
            }

            return HideAllResult(
                appsTargeted: targets.count,
                appsHidden: 0,
                appsFailed: 0,
                appsSkipped: totalSkipped,
                durationMs: durationMs,
                perAppResults: results
            )
        }

        // Hide apps concurrently using TaskGroup
        let hideResults = await withTaskGroup(of: AppHideResult.self) { group in
            for target in targetsToHide {
                group.addTask {
                    await hideApp(target: target, runId: resolvedRunId, verbose: options.verbose)
                }
            }

            var results: [AppHideResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        // Combine results
        var allResults = hideResults

        // Add skipped results for all skip reasons
        for target in targets.filter({ $0.skipReason != nil }) {
            allResults.append(AppHideResult(
                bundleId: target.bundleId,
                appName: target.appName,
                pid: target.pid,
                success: false,
                method: "skipped",
                skipped: true,
                skipReason: target.skipReason
            ))
        }

        let successCount = hideResults.filter { $0.success }.count
        let failedCount = hideResults.filter { !$0.success }.count
        let skippedCount = totalSkipped
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        if options.verbose {
            DeskJigLog.info(.app, "[\(resolvedRunId)] AppHideUtility: Completed in \(durationMs)ms - hidden: \(successCount), failed: \(failedCount), skipped: \(skippedCount)")
        }

        return HideAllResult(
            appsTargeted: targets.count,
            appsHidden: successCount,
            appsFailed: failedCount,
            appsSkipped: skippedCount,
            durationMs: durationMs,
            perAppResults: allResults
        )
    }

    // MARK: - Private Helpers

    private struct HideTarget: Sendable {
        let pid: pid_t
        let bundleId: String
        let appName: String
        let isWorkspaceApp: Bool
        let skipReason: String?  // "no_large_windows", "workspace_app"
    }

    private static func hideApp(
        target: HideTarget,
        runId: String,
        verbose: Bool
    ) async -> AppHideResult {
        // Try NSRunningApplication.hide() first (most reliable)
        if let runningApp = NSRunningApplication(processIdentifier: target.pid),
           runningApp.hide() {
            if verbose {
                DeskJigLog.debug(.app, "[\(runId)] Hidden: \(target.appName) via NSRunningApplication")
            }
            return AppHideResult(
                bundleId: target.bundleId,
                appName: target.appName,
                pid: target.pid,
                success: true,
                method: "nsrunningapplication",
                skipped: false,
                skipReason: nil
            )
        }

        // Fallback to AX API
        if let appElement = AXWindowService.shared.createAppElement(for: target.pid),
           AXWindowService.shared.hideApp(appElement) {
            if verbose {
                DeskJigLog.debug(.app, "[\(runId)] Hidden: \(target.appName) via AX API")
            }
            return AppHideResult(
                bundleId: target.bundleId,
                appName: target.appName,
                pid: target.pid,
                success: true,
                method: "ax",
                skipped: false,
                skipReason: nil
            )
        }

        // Both methods failed
        if verbose {
            DeskJigLog.warn(.app, "[\(runId)] Failed to hide: \(target.appName)")
        }
        return AppHideResult(
            bundleId: target.bundleId,
            appName: target.appName,
            pid: target.pid,
            success: false,
            method: "failed",
            skipped: false,
            skipReason: nil
        )
    }

    /// Get the set of process IDs that have at least one window meeting the minimum size threshold
    private static func getPidsWithLargeWindows(minSize: CGSize) -> Set<pid_t> {
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var pids = Set<pid_t>()
        for dict in windowList {
            guard let pid = dict[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = dict[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width >= minSize.width && height >= minSize.height else {
                continue
            }
            pids.insert(pid)
        }
        return pids
    }

    private static func makeRunId() -> String {
        "hide_\(UUID().uuidString.prefix(8))"
    }
}
