//
//  WindowHighlightOverlay.swift
//  DeskJig
//
//  Manages temporary red border overlay windows for visual identification
//

import AppKit
import SwiftUI
import DeskJigShared

/// View that renders a red border rectangle
struct HighlightBorderView: View {
    let color: Color
    let lineWidth: CGFloat
    @Binding var opacity: Double

    var body: some View {
        Rectangle()
            .inset(by: lineWidth / 2)
            .stroke(color, lineWidth: lineWidth)
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}

/// Custom window for highlight overlays - transparent, floating, ignores mouse
final class HighlightOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        self.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 1)
        self.isOpaque = false
        self.backgroundColor = NSColor.clear
        self.ignoresMouseEvents = true
        self.hasShadow = false
        self.isRestorable = false
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }
}

/// Manages temporary highlight overlays for identified windows
@MainActor
final class WindowHighlightOverlay {
    static let shared = WindowHighlightOverlay()

    private var highlightWindow: HighlightOverlayWindow?
    private var dismissTask: Task<Void, Never>?
    private var hostingView: NSHostingView<HighlightBorderView>?
    private var lastFrame: CGRect?
    private var lastLineWidth: CGFloat = 0

    // Observable opacity for animation
    private var currentOpacity: Double = 1.0

    private init() {}

    /// Shows a red border around the specified frame for a duration
    /// - Parameters:
    ///   - frame: The CGRect frame in screen coordinates (origin at top-left, like CGWindowList)
    ///   - duration: How long to show the highlight (default 2 seconds)
    ///   - color: Border color (default red)
    ///   - lineWidth: Border width (default 4 points)
    func showHighlight(
        around frame: CGRect,
        duration: TimeInterval = 2.0,
        color: Color = DesignTokens.Status.error,
        lineWidth: CGFloat = 4.0
    ) {
        // Convert frame from CGWindowList coordinates (origin top-left)
        // to Cocoa coordinates (origin bottom-left)
        let cocoaFrame = convertToCocoaCoordinates(frame)
        showOverlay(
            at: cocoaFrame,
            duration: duration,
            color: color,
            lineWidth: lineWidth
        )
    }

    /// Shows a highlight around a display frame expressed in global screen coordinates
    /// (origin at bottom-left, like NSScreen / CGDisplay bounds).
    func showDisplayHighlight(
        around screenFrame: CGRect,
        duration: TimeInterval = 3.2,
        color: Color = DesignTokens.Status.error,
        lineWidth: CGFloat = 8.0
    ) {
        DeskJigLog.info(.window, "Display highlight requested", fields: [
            "frame": NSStringFromRect(screenFrame),
            "duration": String(format: "%.2f", duration),
            "lineWidth": String(format: "%.1f", lineWidth)
        ])
        // NSScreen / CGDisplay bounds already use the same bottom-left global coordinate
        // space as NSWindow content rects, so display highlights should not be converted.
        showOverlay(
            at: screenFrame,
            duration: duration,
            color: color,
            lineWidth: lineWidth
        )
    }

    /// Dismisses any current highlight immediately
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        highlightWindow?.orderOut(nil)
        highlightWindow = nil
        hostingView = nil
        lastFrame = nil
        lastLineWidth = 0
    }

    /// Converts a CGRect from CGWindowList coordinates (origin top-left) to Cocoa coordinates (origin bottom-left)
    private func convertToCocoaCoordinates(_ rect: CGRect) -> NSRect {
        // Get the main screen height for coordinate conversion
        guard let mainScreen = NSScreen.screens.first else {
            return NSRect(origin: .zero, size: rect.size)
        }

        let screenHeight = mainScreen.frame.height

        // Flip the Y coordinate
        let cocoaY = screenHeight - rect.origin.y - rect.height

        return NSRect(
            x: rect.origin.x,
            y: cocoaY,
            width: rect.width,
            height: rect.height
        )
    }

    private func showOverlay(
        at frame: CGRect,
        duration: TimeInterval,
        color: Color,
        lineWidth: CGFloat
    ) {
        dismissTask?.cancel()
        dismissTask = nil

        currentOpacity = 1.0

        let shouldReuseWindow = lastFrame == frame && abs(lastLineWidth - lineWidth) < 0.5
        if !shouldReuseWindow {
            highlightWindow?.orderOut(nil)
            highlightWindow = nil
            hostingView = nil

            let window = HighlightOverlayWindow(frame: frame)
            let contentView = HighlightBorderView(
                color: color,
                lineWidth: lineWidth,
                opacity: .constant(1.0)
            )

            let hosting = NSHostingView(rootView: contentView)
            hosting.frame = NSRect(origin: .zero, size: frame.size)
            window.contentView = hosting

            highlightWindow = window
            hostingView = hosting
            lastFrame = frame
            lastLineWidth = lineWidth
        } else {
            highlightWindow?.setFrame(frame, display: true)
        }

        highlightWindow?.alphaValue = 1
        highlightWindow?.orderFront(nil)

        dismissTask = Task { @MainActor in
            let holdDuration = max(duration - 0.35, 0.1)
            await Task.sleepUnlessCancelled(for: .milliseconds(Int(holdDuration * 1000)))

            guard !Task.isCancelled else { return }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.highlightWindow?.animator().alphaValue = 0
            } completionHandler: {
                Task { @MainActor in
                    self.highlightWindow?.orderOut(nil)
                    self.highlightWindow = nil
                    self.hostingView = nil
                    self.lastFrame = nil
                    self.lastLineWidth = 0
                }
            }
        }
    }
}
