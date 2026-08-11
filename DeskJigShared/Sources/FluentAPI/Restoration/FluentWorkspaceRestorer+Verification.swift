//  FluentWorkspaceRestorer+Verification.swift
//  DeskJigShared

import Foundation
import CoreGraphics

extension FluentWorkspaceRestorer {

    func evaluateRestoration(
        workspace: Workspace,
        screenMappings: [(workspaceScreenIndex: Int, currentScreenIndex: Int)],
        result: FluentRestorationResult,
        currentScreens: [FullScreenInfo],
        runId: String
    ) async -> FluentRestorationResult.Evaluation {
        // 1. Check if executor reported any failures
        var issues: [String] = []
        if result.windowsFailed > 0 {
            issues.append("\(result.windowsFailed) window(s) failed to restore")
        }

        // 2. Capture a fresh snapshot for verification
        let verificationSnapshot = await SystemSnapshotCapture.captureQuick(runId: runId)
        let enhanced = EnhancedSnapshot.from(verificationSnapshot)

        // Build screen mapping dictionary for quick lookup
        let screenMappingDict = Dictionary(uniqueKeysWithValues: screenMappings.map {
            ($0.workspaceScreenIndex, $0.currentScreenIndex)
        })

        // Reuse the workspace-effective screen topology captured at the start of this attempt
        // (passed in) so expected frames reflect ignored-display preferences the same way restore
        // planning does — and we avoid a redundant MainActor display refresh here (fwr-02).
        // Monitors do not change during a restore, so the start-of-attempt topology is correct.
        let positionedFrames = await lockManager.getPositionedFrames(for: runId)

        // 3. Check for missing windows by path-aware matching first, then position fallback.
        for window in workspace.windows {
            let bundleId = window.bundleIdentifier
            // Filter out zombie windows (exist in CGWindowList but not accessible via AX API)
            let matches = enhanced.windows.filter { $0.bundleId == bundleId && $0.isAXAccessible != false }

            var matched = false
            let expectedPath = normalizeVerificationPath(window.openPath)
            let isOpenByPathWindow = OpenByPathBundleIdentifiers.supported.contains(bundleId) && expectedPath != nil
            let observedPaths = matches.compactMap { observedVerificationPath(for: $0, bundleId: bundleId) }

            let expectedPlacement: (targetFrame: CGRect?, observedFinalFrame: CGRect?) = {
                guard let relativeFrame = window.relativeFrame,
                      let originalScreenIndex = window.screenIndex else { return (nil, nil) }
                let effectiveScreenIndex = screenMappingDict[originalScreenIndex] ?? originalScreenIndex
                guard effectiveScreenIndex >= 0, effectiveScreenIndex < currentScreens.count else {
                    return (nil, nil)
                }
                let targetCurrentScreen = currentScreens[effectiveScreenIndex]
                let baselineExpectedFrame = WindowFrameConverter.toAbsolute(
                    relativeFrame: relativeFrame,
                    screen: targetCurrentScreen,
                    allScreens: currentScreens
                )
                let bundlePositionedFrames = positionedFrames.filter { $0.bundleId == bundleId }
                guard let positionedFrame = bundlePositionedFrames.min(by: {
                    Self.frameDistance($0.originalTarget, baselineExpectedFrame) < Self.frameDistance($1.originalTarget, baselineExpectedFrame)
                }) else {
                    return (baselineExpectedFrame, nil)
                }

                let originalDistance = Self.frameDistance(positionedFrame.originalTarget, baselineExpectedFrame)
                guard originalDistance < 200 else {
                    return (baselineExpectedFrame, nil)
                }

                return (positionedFrame.effectiveTarget, positionedFrame.finalFrame)
            }()
            let expectedFrame = expectedPlacement.targetFrame
            let observedFinalFrame = expectedPlacement.observedFinalFrame
            let verificationMatches = Self.filteredVerificationMatches(
                for: bundleId,
                matches: matches,
                expectedFrame: expectedFrame,
                currentScreens: currentScreens
            )
            let layoutMatchesExpected: (CGRect, CGRect?) -> Bool = { actualFrame, candidateExpectedFrame in
                guard let candidateExpectedFrame else { return false }
                return WindowLayoutFrameMatcher.matchesLayout(
                    actualFrame: actualFrame,
                    targetFrame: candidateExpectedFrame,
                    screens: currentScreens
                )
            }
            let frameMatchesObservedFinal: (SnapshotWindow, CGFloat) -> Bool = { snapshotWindow, tolerance in
                guard let observedFinalFrame else { return false }
                return snapshotWindow.frameMatches(observedFinalFrame, tolerance: tolerance)
            }

            // Path-based verification for open-by-path windows (Ghostty/Cursor/VSCode/Xcode/etc.).
            // If path evidence exists and does not match, treat as failure instead of frame-only success.
            if let expectedPath, isOpenByPathWindow {
                let pathMatches = matches.filter { observedVerificationPath(for: $0, bundleId: bundleId) == expectedPath }

                if !pathMatches.isEmpty {
                    if let expectedFrame {
                        matched = pathMatches.contains {
                            $0.frameMatches(expectedFrame, tolerance: 70) ||
                            layoutMatchesExpected($0.frame, expectedFrame) ||
                            frameMatchesObservedFinal($0, 70) ||
                            layoutMatchesExpected($0.frame, observedFinalFrame)
                        }
                        if !matched {
                            // Path-correct windows can vary slightly in frame after app-native adjustments.
                            // But reject catastrophic drift (cross-screen displacement).
                            let closestFrame = pathMatches.min(by: {
                                Self.frameDistance($0.frame, expectedFrame) < Self.frameDistance($1.frame, expectedFrame)
                            })?.frame
                            if let closestFrame, Self.isCatastrophicFrameDrift(actual: closestFrame, expected: expectedFrame, currentScreens: currentScreens) {
                                matched = false
                                DeskJigLog.debug(.restorationTrace, "Window verification catastrophic frame drift (path-matched)", fields: [
                                    "app": window.appName,
                                    "bundleId": bundleId,
                                    "expectedFrame": "\(Int(expectedFrame.origin.x)),\(Int(expectedFrame.origin.y)) \(Int(expectedFrame.width))x\(Int(expectedFrame.height))",
                                    "actualFrame": "\(Int(closestFrame.origin.x)),\(Int(closestFrame.origin.y)) \(Int(closestFrame.width))x\(Int(closestFrame.height))"
                                ], runId: runId)
                            } else {
                                matched = true
                            }
                        }
                    } else {
                        matched = true
                    }
                } else if !observedPaths.isEmpty {
                    matched = false
                    DeskJigLog.debug(.restorationTrace, "Window verification path mismatch", fields: [
                        "app": window.appName,
                        "bundleId": bundleId,
                        "expectedPath": expectedPath,
                        "observedPaths": observedPaths.joined(separator: "; ")
                    ], runId: runId)
                }
            }

            // Fallback: frame/existence-based verification when no path evidence is available.
            if !matched && !verificationMatches.isEmpty {
                if let expectedFrame {
                    if verificationMatches.contains(where: {
                        $0.frameMatches(expectedFrame, tolerance: 50) ||
                        layoutMatchesExpected($0.frame, expectedFrame) ||
                        frameMatchesObservedFinal($0, 50) ||
                        layoutMatchesExpected($0.frame, observedFinalFrame)
                    }) {
                        matched = true
                    } else {
                        let closestMatch = verificationMatches.min(by: {
                            Self.frameDistance($0.frame, expectedFrame) < Self.frameDistance($1.frame, expectedFrame)
                        })
                        if let closestFrame = closestMatch?.frame {
                            matched = false
                            DeskJigLog.debug(.restorationTrace, "Window verification frame drift", fields: [
                                "app": window.appName,
                                "bundleId": bundleId,
                                "driftKind": Self.isCatastrophicFrameDrift(actual: closestFrame, expected: expectedFrame, currentScreens: currentScreens) ? "catastrophic" : "significant",
                                "expectedFrame": "\(Int(expectedFrame.origin.x)),\(Int(expectedFrame.origin.y)) \(Int(expectedFrame.width))x\(Int(expectedFrame.height))",
                                "actualFrame": "\(Int(closestFrame.origin.x)),\(Int(closestFrame.origin.y)) \(Int(closestFrame.width))x\(Int(closestFrame.height))",
                                "actualFrames": verificationMatches.map { "\(Int($0.frame.origin.x)),\(Int($0.frame.origin.y)) \(Int($0.frame.width))x\(Int($0.frame.height))" }.joined(separator: "; ")
                            ], runId: runId)
                        }
                    }
                } else {
                    matched = true
                }
            }

            if !matched {
                // Log detailed verification failure info for debugging
                let actualFrames = verificationMatches.map { "\(Int($0.frame.origin.x)),\(Int($0.frame.origin.y)) \(Int($0.frame.width))x\(Int($0.frame.height))" }
                let expectedFrameStr: String
                if let expectedFrame {
                    expectedFrameStr = "\(Int(expectedFrame.origin.x)),\(Int(expectedFrame.origin.y)) \(Int(expectedFrame.width))x\(Int(expectedFrame.height))"
                } else {
                    expectedFrameStr = "no-relative-frame"
                }
                DeskJigLog.debug(.restorationTrace, "Window verification failed", fields: [
                    "app": window.appName,
                    "bundleId": bundleId,
                    "expectedPath": expectedPath ?? "none",
                    "observedPaths": observedPaths.isEmpty ? "none" : observedPaths.joined(separator: "; "),
                    "expectedFrame": expectedFrameStr,
                    "observedFinalFrame": observedFinalFrame.map {
                        "\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height))"
                    } ?? "none",
                    "actualFrames": actualFrames.isEmpty ? "no windows found" : actualFrames.joined(separator: "; "),
                    "matchCount": "\(verificationMatches.count)",
                    "tolerance": "50"
                ], runId: runId)
                if let expectedPath, isOpenByPathWindow, !observedPaths.isEmpty {
                    issues.append("Path mismatch: \(window.appName) expected=\(expectedPath)")
                } else {
                    issues.append("Missing or mispositioned: \(window.appName) (\(bundleId))")
                }
            }
        }

        return FluentRestorationResult.Evaluation(
            isPerfect: issues.isEmpty,
            issues: issues
        )
    }

    /// Detects when a window has drifted to a completely different screen rather than
    /// experiencing normal AX/CG frame noise. A delta >200px in X or Y that also places
    /// the window center on a different screen is catastrophic and should trigger a retry.
    static func isCatastrophicFrameDrift(
        actual: CGRect,
        expected: CGRect,
        currentScreens: [FullScreenInfo]
    ) -> Bool {
        let xDelta = abs(actual.origin.x - expected.origin.x)
        let yDelta = abs(actual.origin.y - expected.origin.y)

        // Must exceed positional threshold to be considered catastrophic
        guard xDelta > 200 || yDelta > 200 else { return false }

        // Check if the window centers land on different screens
        let actualCenter = CGPoint(x: actual.midX, y: actual.midY)
        let expectedCenter = CGPoint(x: expected.midX, y: expected.midY)

        let actualScreen = currentScreens.first { $0.frame.contains(actualCenter) }
        let expectedScreen = currentScreens.first { $0.frame.contains(expectedCenter) }

        // If either center is off-screen, or they're on different screens, it's catastrophic
        if actualScreen == nil || expectedScreen == nil {
            return true
        }
        return actualScreen?.displayID != expectedScreen?.displayID
    }

    static func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        lhs.manhattanDistance(to: rhs)
    }

    private static func filteredVerificationMatches(
        for bundleId: String,
        matches: [SnapshotWindow],
        expectedFrame: CGRect?,
        currentScreens: [FullScreenInfo]
    ) -> [SnapshotWindow] {
        guard BundleRegistry.isAdobeCreativeApp(bundleId), let expectedFrame else {
            return matches
        }

        let minimumRatio: CGFloat = 0.72
        let targetScreen = currentScreens.first {
            $0.frame.contains(CGPoint(x: expectedFrame.midX, y: expectedFrame.midY))
        }

        let sizeEligible = matches.filter { match in
            let widthRatio = match.frame.width / max(expectedFrame.width, 1)
            let heightRatio = match.frame.height / max(expectedFrame.height, 1)
            return widthRatio >= minimumRatio && heightRatio >= minimumRatio
        }

        let sameScreenEligible = sizeEligible.filter { match in
            guard let targetScreen, let displayIndex = match.displayIndex else { return false }
            return currentScreens.indices.contains(displayIndex) &&
                currentScreens[displayIndex].displayID == targetScreen.displayID
        }

        if !sameScreenEligible.isEmpty {
            return sameScreenEligible
        }
        if !sizeEligible.isEmpty {
            return sizeEligible
        }
        return matches
    }

    private func normalizeVerificationPath(_ path: String?) -> String? {
        guard let path else { return nil }
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("file://") {
            trimmed = String(trimmed.dropFirst("file://".count))
        }
        trimmed = trimmed.removingPercentEncoding ?? trimmed
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func observedVerificationPath(for window: SnapshotWindow, bundleId: String) -> String? {
        if BundleRegistry.isTerminal(bundleId) {
            return normalizeVerificationPath(window.freshWorkingDirectory ?? window.documentPath)
        }

        if BundleRegistry.isIDE(bundleId) {
            guard let rawPath = normalizeVerificationPath(window.ideDocumentPath ?? window.documentPath) else {
                return nil
            }
            if bundleId == OpenByPathBundleIdentifiers.xcode {
                if rawPath.hasSuffix(".xcworkspace") || rawPath.hasSuffix(".xcodeproj") {
                    return URL(fileURLWithPath: rawPath).deletingLastPathComponent().path
                }
            }
            return rawPath
        }

        return normalizeVerificationPath(window.documentPath)
    }
}
