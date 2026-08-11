//  WindowHandle+Screenshot.swift
//  DeskJigShared

import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Screenshot Error

/// Errors that can occur during screenshot operations
public enum WindowScreenshotError: Error, Sendable {
    case windowNotFound
    case capturePermissionDenied
    case captureFailed(String)
    case failedToCreateDestination
    case failedToSave(String)
}

// MARK: - Screenshot Utilities

/// Utility for capturing window screenshots using CGWindowID
public enum WindowScreenshot {

    /// Capture a screenshot of a window by its CGWindowID
    /// - Parameters:
    ///   - windowId: The CGWindowID to capture
    ///   - scale: Scale factor (2.0 = retina, default)
    /// - Returns: The captured CGImage
    public static func capture(windowId: CGWindowID, scale: CGFloat = 2.0) async throws -> CGImage {
        guard CGPreflightScreenCaptureAccess() else {
            throw WindowScreenshotError.capturePermissionDenied
        }

        let content = try await SCShareableContent.current

        guard let scWindow = content.windows.first(where: { $0.windowID == windowId }) else {
            throw WindowScreenshotError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: scWindow)

        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(scWindow.frame.width) * scale)
        config.height = Int(CGFloat(scWindow.frame.height) * scale)
        config.capturesAudio = false
        config.shouldBeOpaque = false
        config.ignoreGlobalClipDisplay = true
        config.scalesToFit = true
        config.showsCursor = false
        config.capturesShadowsOnly = false

        do {
            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
        } catch {
            throw WindowScreenshotError.captureFailed(error.localizedDescription)
        }
    }

    /// Capture a screenshot of a window from WindowInfo
    @available(macOS 12.3, *)
    public static func capture(windowInfo: WindowInfo, scale: CGFloat = 2.0) async throws -> CGImage {
        if TestingConfiguration.USE_BLACK_SCREENSHOTS {
            let width = max(1, Int(windowInfo.frame.width * scale))
            let height = max(1, Int(windowInfo.frame.height * scale))
            if let black = createBlackImage(width: width, height: height) {
                return black
            }
            throw WindowScreenshotError.captureFailed("Failed to create black screenshot")
        }

        guard windowInfo.id >= 0, windowInfo.id <= Int(UInt32.max) else {
            throw WindowScreenshotError.windowNotFound
        }

        return try await capture(windowId: CGWindowID(windowInfo.id), scale: scale)
    }

    /// Capture and save a screenshot to file
    /// - Parameters:
    ///   - windowId: The CGWindowID to capture
    ///   - path: File path to save to
    ///   - scale: Scale factor (2.0 = retina, default)
    public static func save(windowId: CGWindowID, to path: String, scale: CGFloat = 2.0) async throws {
        let image = try await capture(windowId: windowId, scale: scale)
        let url = URL(fileURLWithPath: path)

        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw WindowScreenshotError.failedToCreateDestination
        }

        CGImageDestinationAddImage(destination, image, nil)

        guard CGImageDestinationFinalize(destination) else {
            throw WindowScreenshotError.failedToSave("Failed to finalize image destination")
        }
    }

    /// Capture WindowSnapshot instances for visible windows
    @available(macOS 12.3, *)
    public static func createWindowSnapshots(
        windows: [WindowInfo],
        applicationManager: ApplicationManagerProtocol? = nil
    ) async -> [WindowSnapshot] {
        let visibleWindows = windows.filter { !$0.isHidden && !$0.isMinimized }
        var snapshots: [WindowSnapshot] = []

        let appInfoByBundleId: [String: AppInfo]? = applicationManager?.applications.reduce(into: [:]) { result, app in
            guard let bundleId = app.bundleIdentifier, !bundleId.isEmpty else {
                return
            }

            if result[bundleId] == nil {
                result[bundleId] = app
            }
        }

        for windowInfo in visibleWindows {
            guard let image = try? await capture(windowInfo: windowInfo) else { continue }
            let frameSize = windowInfo.frame.size
            let size: NSSize
            if frameSize.width > 0 && frameSize.height > 0 {
                size = NSSize(width: frameSize.width, height: frameSize.height)
            } else {
                size = NSSize(width: image.width, height: image.height)
            }
            let nsImage = NSImage(cgImage: image, size: size)

            var appInfo: AppInfo?
            if let bundleId = windowInfo.bundleIdentifier {
                appInfo = appInfoByBundleId?[bundleId]
            }

            snapshots.append(WindowSnapshot(
                id: windowInfo.id,
                windowInfo: windowInfo,
                appInfo: appInfo,
                screenshot: nsImage
            ))
        }

        return snapshots
    }

    /// Check if screen recording permission is granted
    public static var hasPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Request screen recording permission (shows system dialog)
    @discardableResult
    public static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    private static func createBlackImage(width: Int, height: Int) -> CGImage? {
        guard width > 0 && height > 0 else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        return context.makeImage()
    }
}
