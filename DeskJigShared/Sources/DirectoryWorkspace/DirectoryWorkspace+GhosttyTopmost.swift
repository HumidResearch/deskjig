//  DirectoryWorkspace+GhosttyTopmost.swift
//  DeskJigShared

import AppKit
import CoreGraphics
import Foundation

extension DirectoryWorkspace {
    func ghosttyExpectedTitle(
        for spec: WindowSpec,
        index: Int,
        directoryPath: String
    ) -> String {
        let directoryBasename = URL(fileURLWithPath: directoryPath).lastPathComponent
        let windowIndex = spec.windowIndex ?? index
        return "\(BundleIdentity.terminalTitleTokenPrefix):\(directoryBasename):\(windowIndex)"
    }

    func ensureGhosttyWindowTopmost(
        windowHandle: WindowHandle,
        expectedTitle: String,
        expectedDocumentPath: String,
        targetFrame: CGRect?,
        logger: ((String) -> Void)?,
        specIndex: Int
    ) async {
        logCallStack("DirectoryWorkspace.ensureGhosttyWindowTopmost spec=\(specIndex)")
        guard let targetFrame else {
            logger?("dw.restore spec=\(specIndex) topmost.check=skipped reason=noFrame")
            return
        }
        let expectedDocPath = normalizePath(expectedDocumentPath)
        let point = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            if isTopmostWindow(
                at: point,
                expectedTitle: expectedTitle,
                expectedDocumentPath: expectedDocPath,
                logger: logger,
                specIndex: specIndex,
                attempt: attempt
            ) {
                logger?("dw.restore spec=\(specIndex) topmost.check=ok attempt=\(attempt)")
                return
            }

            if let windowPID = windowHandle.processID,
               let app = NSRunningApplication(processIdentifier: pid_t(windowPID)) {
                if #available(macOS 14.0, *) {
                    _ = app.activate()
                } else {
                    _ = app.activate(options: [.activateIgnoringOtherApps])
                }
            }
            if let axWindow = windowHandle.window {
                _ = AXWindowService.shared.raise(axWindow)
            }
            _ = windowHandle.tap()
            logger?("dw.restore spec=\(specIndex) topmost.retry attempt=\(attempt)")
            guard await Task.sleepUnlessCancelled(nanoseconds: 200_000_000) else { break }
        }

        logger?("dw.restore spec=\(specIndex) topmost.check=failed attempts=\(maxAttempts)")
    }

    func isTopmostWindow(
        at point: CGPoint,
        expectedTitle: String,
        expectedDocumentPath: String?,
        logger: ((String) -> Void)?,
        specIndex: Int,
        attempt: Int
    ) -> Bool {
        guard let windowListInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            logger?("dw.restore spec=\(specIndex) topmost.check=failed attempt=\(attempt) reason=windowListUnavailable")
            return false
        }

        for windowData in windowListInfo {
            guard let windowLayer = windowData[kCGWindowLayer as String] as? Int,
                  windowLayer == 0,
                  let ownerPID = windowData[kCGWindowOwnerPID as String] as? pid_t,
                  let ownerName = windowData[kCGWindowOwnerName as String] as? String,
                  let windowBounds = windowData[kCGWindowBounds as String] as? [String: Any] else {
                continue
            }

            guard !ownerName.contains("Window Server") else { continue }

            let x = windowBounds["X"] as? CGFloat ?? 0
            let y = windowBounds["Y"] as? CGFloat ?? 0
            let width = windowBounds["Width"] as? CGFloat ?? 0
            let height = windowBounds["Height"] as? CGFloat ?? 0
            let frame = CGRect(x: x, y: y, width: width, height: height)

            guard frame.contains(point) else { continue }

            if ownerName != "Ghostty" {
                logger?(
                    "dw.restore spec=\(specIndex) topmost.check attempt=\(attempt) top.app=\"\(ownerName)\" match=false"
                )
                return false
            }

            let cgTitle = (windowData[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !cgTitle.isEmpty, cgTitle == expectedTitle {
                logger?(
                    "dw.restore spec=\(specIndex) topmost.match attempt=\(attempt) method=cgTitle title=\"\(cgTitle)\""
                )
                return true
            }

            let axMatches = AXWindowService.shared.getWindows(
                forProcessID: ownerPID,
                bundleIdentifier: OpenByPathBundleIdentifiers.ghostty
            )

            let cgFrame = CGRect(x: x, y: y, width: width, height: height)
            let axCandidate = axMatches.first(where: { $0.frameMatches(cgFrame, tolerance: 4) }) ??
                axMatches.first(where: { $0.frame.contains(point) })

            guard let axWindow = axCandidate else {
                logger?(
                    "dw.restore spec=\(specIndex) topmost.match attempt=\(attempt) method=axMissing cgTitle=\"\(cgTitle)\""
                )
                return false
            }

            let axHandle = WindowHandle(axWindow: axWindow)
            let axTitle = axWindow.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let axDocPath = normalizePath(axHandle.documentPath)

            if !axTitle.isEmpty, axTitle == expectedTitle {
                logger?(
                    "dw.restore spec=\(specIndex) topmost.match attempt=\(attempt) method=axTitle title=\"\(axTitle)\" doc=\"\(axDocPath ?? "nil")\""
                )
                return true
            }
            if let expectedDocumentPath, let axDocPath, axDocPath == expectedDocumentPath {
                logger?(
                    "dw.restore spec=\(specIndex) topmost.match attempt=\(attempt) method=axDocument title=\"\(axTitle)\" doc=\"\(axDocPath)\""
                )
                return true
            }

            logger?(
                "dw.restore spec=\(specIndex) topmost.match attempt=\(attempt) method=axMismatch cgTitle=\"\(cgTitle)\" axTitle=\"\(axTitle)\" axDoc=\"\(axDocPath ?? "nil")\""
            )
            return false
        }

        logger?("dw.restore spec=\(specIndex) topmost.check=failed attempt=\(attempt) reason=noWindowAtPoint")
        return false
    }

    func logCallStack(_ label: String, limit: Int = 8) {
        guard ProcessInfo.processInfo.environment["SHOW_CALL_STACKS"] == "1" else { return }
        let symbols = Thread.callStackSymbols.prefix(limit).joined(separator: " | ")
        DeskJigLog.debug(.workspace, "CallStack \(label) stack=\(symbols)")
    }

    func normalizePath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }
}
