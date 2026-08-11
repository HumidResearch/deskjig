//  WindowHandle.swift
//  DeskJigShared

import Foundation
import CoreGraphics
import AppKit

/// A chainable wrapper for window operations in the Fluent Window API.
///
/// `WindowHandle` is the core abstraction for manipulating macOS windows programmatically.
/// It wraps an underlying `AXWindow` and provides a fluent interface where operations
/// return `Self` on success or `nil` on failure, enabling natural method chaining.
///
/// All position and state operations are backed by the Accessibility API (AX) via
/// `AXWindowService`, ensuring reliable cross-application window manipulation.
///
/// ## Overview
///
/// WindowHandle provides four categories of operations:
/// - **Position Operations**: Move windows to specific coordinates
/// - **Screen Zone Operations**: Snap windows to screen regions (halves, thirds, quarters)
/// - **State Operations**: Minimize, restore, close, hide, activate, and more
/// - **State Queries**: Read-only properties for window metadata and state
///
/// ## Method Chaining
///
/// Operations that modify window state return `WindowHandle?`, enabling fluent chaining:
///
/// ```swift
/// // Chain multiple operations - stops at first failure
/// App.Figma?.firstWindow()?
///     .unminimize()?
///     .moveTo(x: 0, y: 100)?
///     .resize(width: 800, height: 600)
///
/// // Screen zone operations with activation
/// Window.topmost()?
///     .center()?
///     .raise()?
///     .activate()
/// ```
///
/// ## Error Handling
///
/// Methods return `nil` when:
/// - The underlying window no longer exists
/// - The AXWindowService is unavailable
/// - The operation fails (e.g., window cannot be moved)
///
/// Use optional chaining to handle failures gracefully:
///
/// ```swift
/// if let window = Window.topmost()?.moveToLeftHalf() {
///     print("Window moved successfully")
/// } else {
///     print("Operation failed")
/// }
/// ```
///
/// ## Animation Support
///
/// Screen zone operations and `setFrame(_:animated:options:)` support smooth animations:
///
/// ```swift
/// Window.topmost()?.moveToLeftHalf(animated: true, options: .smooth)
/// Window.topmost()?.center(animated: true)
/// ```
///
/// ## See Also
/// - ``Window`` for static window lookup methods
/// - ``App`` for application-based window access
/// - ``AXWindow`` for the underlying window representation
/// - ``WindowAnimationOptions`` for animation configuration
public final class WindowHandle: @unchecked Sendable {

    /// Guards `_axWindow`. `WindowHandle` is `@unchecked Sendable` — it is returned from
    /// `async` functions and threaded through `MainActor.run` boundaries throughout the
    /// restoration pipeline (see #539) — so a handle can legally be retained and touched
    /// from more than one task even though today's call sites only ever hand a given
    /// instance off sequentially (produce on one task, await, consume on the next; never
    /// two tasks holding the same instance concurrently). Every read and write of the
    /// window state goes through the `axWindow` computed property below rather than
    /// touching `_axWindow` directly, so this lock is the single choke point for that
    /// state — cheap insurance against a future call site that shares a handle.
    private let axWindowLock = NSLock()

    /// Backing storage for ``axWindow``. Never reference this directly — always go
    /// through the `axWindow` computed property, which serializes access via
    /// `axWindowLock`.
    private var _axWindow: AXWindow?

    /// The underlying AX window (may be nil if window was not found or closed).
    ///
    /// Lock-protected: see `axWindowLock` above. All ~40 read/write sites in this file
    /// (guards, refresh reassignment, invalidation on `close()`, read-only queries like
    /// `frame`/`title`/`exists`) go through this single accessor.
    private var axWindow: AXWindow? {
        get {
            axWindowLock.lock()
            defer { axWindowLock.unlock() }
            return _axWindow
        }
        set {
            axWindowLock.lock()
            defer { axWindowLock.unlock() }
            _axWindow = newValue
        }
    }

    /// Reference to AXWindowService for operations
    private var axService: AXWindowServiceProtocol? {
        return FluentServices.shared.axWindowService
    }

    // MARK: - Initialization

    /// Creates a WindowHandle wrapping an AXWindow.
    ///
    /// - Parameter axWindow: The AX window to wrap
    internal init(axWindow: AXWindow?) {
        self.axWindow = axWindow
    }
    
    // MARK: - Position Operations (Chainable)

    /// Moves the window to the specified screen coordinates.
    ///
    /// Repositions the window's origin (top-left corner) to the given coordinates
    /// while preserving its current size. The coordinate system uses top-left origin,
    /// matching macOS window coordinates.
    ///
    /// - Parameters:
    ///   - x: The X coordinate for the window's left edge in screen points
    ///   - y: The Y coordinate for the window's top edge in screen points
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Move window to top-left corner of screen
    /// Window.topmost()?.moveTo(x: 0, y: 0)
    ///
    /// // Chain with other operations
    /// App.Safari?.firstWindow()?
    ///     .moveTo(x: 100, y: 100)?
    ///     .resize(width: 800, height: 600)?
    ///     .activate()
    /// ```
    ///
    /// ## See Also
    /// - ``position(_:_:)`` for alternative syntax
    /// - ``setFrame(_:animated:options:)`` for combined position and size changes
    /// - ``center(animated:options:)`` for centering on screen
    @discardableResult
    public func moveTo(x: CGFloat, y: CGFloat) -> WindowHandle? {
        guard let window = axWindow,
              let service = axService else {
            return nil
        }
        
        let newFrame = CGRect(x: x, y: y, width: window.frame.width, height: window.frame.height)
        let success = service.move(window, to: newFrame)
        
        if success {
            // Refresh to get updated state
            axWindow = service.refresh(window)
        }
        
        return success ? self : nil
    }
    
    /// Resizes the window to the specified dimensions.
    ///
    /// Changes the window's width and height while preserving its current position
    /// (top-left corner). Some applications may enforce minimum or maximum sizes,
    /// which could result in the actual size differing from the requested size.
    ///
    /// - Parameters:
    ///   - width: The new width in screen points
    ///   - height: The new height in screen points
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Resize window to specific dimensions
    /// Window.topmost()?.resize(width: 1200, height: 800)
    ///
    /// // Combine with position for precise placement
    /// App.Figma?.firstWindow()?
    ///     .moveTo(x: 0, y: 0)?
    ///     .resize(width: 1920, height: 1080)
    /// ```
    ///
    /// ## See Also
    /// - ``setFrame(_:animated:options:)`` for combined position and size changes
    /// - ``maximize(animated:options:)`` for filling the entire screen
    @discardableResult
    public func resize(width: CGFloat, height: CGFloat) -> WindowHandle? {
        guard let window = axWindow,
              let service = axService else {
            return nil
        }
        
        let newFrame = CGRect(x: window.frame.origin.x, y: window.frame.origin.y, width: width, height: height)
        let success = service.move(window, to: newFrame)
        
        if success {
            axWindow = service.refresh(window)
        }
        
        return success ? self : nil
    }
    
    /// Sets the window frame (position and size) in a single operation.
    ///
    /// This is the most flexible positioning method, allowing you to set both
    /// the window's origin and size simultaneously. Supports optional animation
    /// for smooth visual transitions.
    ///
    /// When `animated` is `true`, the window smoothly transitions from its current
    /// frame to the target frame using the provided animation options. This blocks
    /// until the animation completes.
    ///
    /// - Parameters:
    ///   - frame: The target frame containing both position and size
    ///   - animated: Whether to animate the transition. Defaults to `false`.
    ///   - options: Configuration for the animation timing and easing. Only used
    ///              when `animated` is `true`. Defaults to `.default`.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Set exact frame without animation
    /// let targetFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
    /// Window.topmost()?.setFrame(targetFrame)
    ///
    /// // Animate to new frame with smooth easing
    /// Window.topmost()?.setFrame(targetFrame, animated: true, options: .smooth)
    ///
    /// // Use screen-relative frame
    /// if let screenFrame = NSScreen.main?.visibleFrame {
    ///     Window.topmost()?.setFrame(screenFrame, animated: true)
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``moveTo(x:y:)`` for position-only changes
    /// - ``resize(width:height:)`` for size-only changes
    /// - ``WindowAnimationOptions`` for animation configuration
    @discardableResult
    public func setFrame(
        _ frame: CGRect,
        animated: Bool = false,
        options: WindowAnimationOptions = .default
    ) -> WindowHandle? {
        guard let window = axWindow,
              let service = axService else {
            return nil
        }

        if animated {
            // Block until animation completes
            let semaphore = DispatchSemaphore(value: 0)
            var animationSuccess = false
            let timeout = max(options.duration + 1.5, 2.0)
            let timeoutDeadline = DispatchTime.now() + timeout

            Task {
                let result = await WindowAnimator.shared.animate(
                    window: window,
                    to: frame,
                    options: options
                )
                animationSuccess = result.success
                semaphore.signal()
            }

            let waitResult = semaphore.wait(timeout: timeoutDeadline)
            guard waitResult == .success else {
                DeskJigLog.warn(.window, "WindowHandle.setFrame animated wait timed out", fields: [
                    "windowIdentity": window.identityKey,
                    "timeout": String(format: "%.2f", timeout),
                    "targetX": String(format: "%.1f", frame.minX),
                    "targetY": String(format: "%.1f", frame.minY),
                    "targetWidth": String(format: "%.1f", frame.width),
                    "targetHeight": String(format: "%.1f", frame.height)
                ])
                return nil
            }

            if animationSuccess {
                axWindow = service.refresh(window)
            }

            return animationSuccess ? self : nil
        } else {
            let success = service.move(window, to: frame)

            if success {
                axWindow = service.refresh(window)
            }

            return success ? self : nil
        }
    }
    
    /// Moves the window to the specified screen coordinates (alternative syntax).
    ///
    /// This is an alias for ``moveTo(x:y:)`` that provides a more concise syntax
    /// using unlabeled parameters. Both methods are functionally identical.
    ///
    /// - Parameters:
    ///   - x: The X coordinate for the window's left edge in screen points
    ///   - y: The Y coordinate for the window's top edge in screen points
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Concise positioning syntax
    /// Window.topmost()?.position(100, 200)
    ///
    /// // Equivalent to:
    /// Window.topmost()?.moveTo(x: 100, y: 200)
    /// ```
    ///
    /// ## See Also
    /// - ``moveTo(x:y:)`` for labeled parameter syntax
    @discardableResult
    public func position(_ x: CGFloat, _ y: CGFloat) -> WindowHandle? {
        return moveTo(x: x, y: y)
    }
    
    // MARK: - Screen Zone Operations (Chainable)
    
    /// Gets the visible frame for the screen containing this window, in window coordinates (top-left origin)
    private func getScreenVisibleFrame() -> (frame: CGRect, screenHeight: CGFloat)? {
        guard let window = axWindow else { return nil }
        
        // Find the screen containing this window
        let windowCenter = CGPoint(
            x: window.frame.midX,
            y: window.frame.midY
        )
        
        // Global coordinate space anchor (always from first screen)
        let globalMaxY = WorkspaceDisplayTopology.windowCoordinateAnchorY(
            from: NSScreen.screens.map(FullScreenInfo.init(screen:))
        )
        
        // Use DisplayManager if available, otherwise use NSScreen
        if let displayManager = FluentServices.shared.displayManager {
            if let screenInfo = displayManager.getBestScreen(for: window.frame) {
                // Convert visibleFrame from screen coords (bottom-left) to window coords (top-left)
                let visibleFrameInWindowCoords = screenInfo.visibleFrameInWindowCoordinates(globalMaxY: globalMaxY)
                return (visibleFrameInWindowCoords, globalMaxY)
            }
        }
        
        // Fallback to NSScreen
        for screen in NSScreen.screens {
            // Convert screen frame to window coordinates for comparison
            let screenFrameInWindowCoords = CGRect(
                x: screen.frame.origin.x,
                y: globalMaxY - screen.frame.maxY,
                width: screen.frame.width,
                height: screen.frame.height
            )
            
            if screenFrameInWindowCoords.contains(windowCenter) {
                // Convert visibleFrame from screen coords to window coords
                let visibleY = globalMaxY - screen.visibleFrame.maxY
                let visibleFrame = CGRect(
                    x: screen.visibleFrame.origin.x,
                    y: visibleY,
                    width: screen.visibleFrame.width,
                    height: screen.visibleFrame.height
                )
                return (visibleFrame, globalMaxY)
            }
        }
        
        // Default to main screen
        guard let screen = NSScreen.main else { return nil }
        let visibleY = globalMaxY - screen.visibleFrame.maxY
        let visibleFrame = CGRect(
            x: screen.visibleFrame.origin.x,
            y: visibleY,
            width: screen.visibleFrame.width,
            height: screen.visibleFrame.height
        )
        return (visibleFrame, globalMaxY)
    }

    /// Direction for edge-based movement with smart resize behavior.
    public enum Edge: String, Sendable {
        case left
        case right
        case up
        case down
    }

    /// Moves the window to a screen edge, using smart resize if already at that edge.
    ///
    /// Smart resize behavior matches the legacy smart-resize implementation:
    /// - Left/Right: if already at the edge and full height, cycle widths (full → 2/3 → 1/2 → 1/3 → full).
    /// - Left/Right: if already at the edge but not full height, expand to full height.
    /// - Up/Down: if already at the edge and touching left/right, expand to full width.
    /// - Up/Down: if already at the edge but not touching left/right, expand to full height.
    ///
    /// - Parameters:
    ///   - edge: The edge direction to move toward.
    ///   - animated: Whether to animate the transition.
    ///   - options: Animation configuration when `animated` is `true`.
    /// - Returns: Self for chaining, or `nil` if the operation failed.
    @discardableResult
    public func moveToEdge(
        _ edge: Edge,
        animated: Bool = false,
        options: WindowAnimationOptions = .default
    ) -> WindowHandle? {
        guard let window = axWindow,
              let screenInfo = getScreenVisibleFrame() else {
            return nil
        }

        let visibleFrame = screenInfo.frame
        let tolerance: CGFloat = 10.0
        let windowFrame = window.frame

        if let smartFrame = smartResizeFrame(
            for: windowFrame,
            visibleFrame: visibleFrame,
            edge: edge,
            tolerance: tolerance
        ) {
            return setFrame(smartFrame, animated: animated, options: options)
        }

        let targetFrame = edgeTargetFrame(
            for: windowFrame,
            visibleFrame: visibleFrame,
            edge: edge
        )
        return setFrame(targetFrame, animated: animated, options: options)
    }

    private func edgeTargetFrame(
        for windowFrame: CGRect,
        visibleFrame: CGRect,
        edge: Edge
    ) -> CGRect {
        switch edge {
        case .left:
            return CGRect(
                x: visibleFrame.minX,
                y: windowFrame.origin.y,
                width: windowFrame.width,
                height: windowFrame.height
            )
        case .right:
            return CGRect(
                x: visibleFrame.maxX - windowFrame.width,
                y: windowFrame.origin.y,
                width: windowFrame.width,
                height: windowFrame.height
            )
        case .up:
            return CGRect(
                x: windowFrame.origin.x,
                y: visibleFrame.minY,
                width: windowFrame.width,
                height: windowFrame.height
            )
        case .down:
            return CGRect(
                x: windowFrame.origin.x,
                y: visibleFrame.maxY - windowFrame.height,
                width: windowFrame.width,
                height: windowFrame.height
            )
        }
    }

    private func smartResizeFrame(
        for windowFrame: CGRect,
        visibleFrame: CGRect,
        edge: Edge,
        tolerance: CGFloat
    ) -> CGRect? {
        let isAtLeft = abs(windowFrame.minX - visibleFrame.minX) < tolerance
        let isAtRight = abs(windowFrame.maxX - visibleFrame.maxX) < tolerance
        let isAtTop = abs(windowFrame.minY - visibleFrame.minY) < tolerance
        let isAtBottom = abs(windowFrame.maxY - visibleFrame.maxY) < tolerance

        switch edge {
        case .left:
            guard isAtLeft else { return nil }
            if isAtTop && isAtBottom {
                let oneThirdWidth = visibleFrame.width / 3
                let halfWidth = visibleFrame.width / 2
                let twoThirdsWidth = visibleFrame.width * 2 / 3
                let fullWidth = visibleFrame.width
                let currentWidth = windowFrame.width

                let targetWidth: CGFloat
                if abs(currentWidth - fullWidth) < tolerance {
                    targetWidth = twoThirdsWidth
                } else if abs(currentWidth - twoThirdsWidth) < tolerance {
                    targetWidth = halfWidth
                } else if abs(currentWidth - halfWidth) < tolerance {
                    targetWidth = oneThirdWidth
                } else if abs(currentWidth - oneThirdWidth) < tolerance {
                    targetWidth = fullWidth
                } else {
                    targetWidth = twoThirdsWidth
                }

                return CGRect(
                    x: visibleFrame.minX,
                    y: visibleFrame.minY,
                    width: targetWidth,
                    height: visibleFrame.height
                )
            }

            return CGRect(
                x: visibleFrame.minX,
                y: visibleFrame.minY,
                width: windowFrame.width,
                height: visibleFrame.height
            )

        case .right:
            guard isAtRight else { return nil }
            if isAtTop && isAtBottom {
                let oneThirdWidth = visibleFrame.width / 3
                let halfWidth = visibleFrame.width / 2
                let twoThirdsWidth = visibleFrame.width * 2 / 3
                let fullWidth = visibleFrame.width
                let currentWidth = windowFrame.width

                let targetWidth: CGFloat
                if abs(currentWidth - fullWidth) < tolerance {
                    targetWidth = twoThirdsWidth
                } else if abs(currentWidth - twoThirdsWidth) < tolerance {
                    targetWidth = halfWidth
                } else if abs(currentWidth - halfWidth) < tolerance {
                    targetWidth = oneThirdWidth
                } else if abs(currentWidth - oneThirdWidth) < tolerance {
                    targetWidth = fullWidth
                } else {
                    targetWidth = twoThirdsWidth
                }

                return CGRect(
                    x: visibleFrame.maxX - targetWidth,
                    y: visibleFrame.minY,
                    width: targetWidth,
                    height: visibleFrame.height
                )
            }

            return CGRect(
                x: visibleFrame.maxX - windowFrame.width,
                y: visibleFrame.minY,
                width: windowFrame.width,
                height: visibleFrame.height
            )

        case .up:
            guard isAtTop else { return nil }
            if isAtLeft || isAtRight {
                return CGRect(
                    x: visibleFrame.minX,
                    y: visibleFrame.minY,
                    width: visibleFrame.width,
                    height: windowFrame.height
                )
            }

            return CGRect(
                x: windowFrame.origin.x,
                y: visibleFrame.minY,
                width: windowFrame.width,
                height: visibleFrame.height
            )

        case .down:
            guard isAtBottom else { return nil }
            if isAtLeft || isAtRight {
                return CGRect(
                    x: visibleFrame.minX,
                    y: visibleFrame.maxY - windowFrame.height,
                    width: visibleFrame.width,
                    height: windowFrame.height
                )
            }

            return CGRect(
                x: windowFrame.origin.x,
                y: visibleFrame.minY,
                width: windowFrame.width,
                height: visibleFrame.height
            )
        }
    }
    
    /// Moves and resizes the window to fill the left half of its current screen.
    ///
    /// The window is positioned at the left edge of the screen's visible area
    /// (accounting for the menu bar and Dock) and resized to occupy exactly 50%
    /// of the horizontal space while filling the full vertical height.
    ///
    /// The screen used is determined by the window's current center point location.
    ///
    /// - Parameters:
    ///   - animated: Whether to animate the transition. Defaults to `false`.
    ///   - options: Configuration for the animation timing and easing. Only used
    ///              when `animated` is `true`. Defaults to `.default`.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Snap to left half instantly
    /// Window.topmost()?.moveToLeftHalf()
    ///
    /// // Animate the transition
    /// Window.topmost()?.moveToLeftHalf(animated: true)
    ///
    /// // Side-by-side window arrangement
    /// App.Safari?.firstWindow()?.moveToLeftHalf()
    /// App.Notes?.firstWindow()?.moveToRightHalf()
    /// ```
    ///
    /// ## See Also
    /// - ``moveToRightHalf(animated:options:)`` for the opposite half
    /// - ``moveToLeftThird(animated:options:)`` for narrower layout
    /// - ``moveToTopLeftQuarter(animated:options:)`` for quarter screen
    @discardableResult
    public func moveToLeftHalf(
        animated: Bool = false,
        options: WindowAnimationOptions = .default
    ) -> WindowHandle? {
        guard let screenInfo = getScreenVisibleFrame() else { return nil }
        let visibleFrame = screenInfo.frame

        let targetFrame = CGRect(
            x: visibleFrame.origin.x,
            y: visibleFrame.origin.y,
            width: visibleFrame.width / 2,
            height: visibleFrame.height
        )

        return setFrame(targetFrame, animated: animated, options: options)
    }
    
    /// Moves and resizes the window to fill the right half of its current screen.
    ///
    /// The window is positioned at the horizontal center of the screen's visible area
    /// (accounting for the menu bar and Dock) and resized to occupy exactly 50%
    /// of the horizontal space while filling the full vertical height.
    ///
    /// The screen used is determined by the window's current center point location.
    ///
    /// - Parameters:
    ///   - animated: Whether to animate the transition. Defaults to `false`.
    ///   - options: Configuration for the animation timing and easing. Only used
    ///              when `animated` is `true`. Defaults to `.default`.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Snap to right half instantly
    /// Window.topmost()?.moveToRightHalf()
    ///
    /// // Animate the transition
    /// Window.topmost()?.moveToRightHalf(animated: true)
    ///
    /// // Side-by-side window arrangement
    /// App.Safari?.firstWindow()?.moveToLeftHalf()
    /// App.Notes?.firstWindow()?.moveToRightHalf()
    /// ```
    ///
    /// ## See Also
    /// - ``moveToLeftHalf(animated:options:)`` for the opposite half
    /// - ``moveToRightThird(animated:options:)`` for narrower layout
    /// - ``moveToTopRightQuarter(animated:options:)`` for quarter screen
    @discardableResult
    public func moveToRightHalf(
        animated: Bool = false,
        options: WindowAnimationOptions = .default
    ) -> WindowHandle? {
        guard let screenInfo = getScreenVisibleFrame() else { return nil }
        let visibleFrame = screenInfo.frame

        let targetFrame = CGRect(
            x: visibleFrame.origin.x + visibleFrame.width / 2,
            y: visibleFrame.origin.y,
            width: visibleFrame.width / 2,
            height: visibleFrame.height
        )

        return setFrame(targetFrame, animated: animated, options: options)
    }
    
    /// Moves and resizes the window to fill the top half of its current screen.
    ///
    /// The window is positioned at the top of the screen's visible area
    /// (accounting for the menu bar) and resized to occupy exactly 50%
    /// of the vertical space while filling the full horizontal width.
    ///
    /// The screen used is determined by the window's current center point location.
    ///
    /// - Parameters:
    ///   - animated: Whether to animate the transition. Defaults to `false`.
    ///   - options: Configuration for the animation timing and easing. Only used
    ///              when `animated` is `true`. Defaults to `.default`.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Snap to top half instantly
    /// Window.topmost()?.moveToTopHalf()
    ///
    /// // Create a stacked layout
    /// App.Terminal?.firstWindow()?.moveToTopHalf()
    /// App.Safari?.firstWindow()?.moveToBottomHalf()
    /// ```
    ///
    /// ## See Also
    /// - ``moveToBottomHalf(animated:options:)`` for the opposite half
    /// - ``moveToTopLeftQuarter(animated:options:)`` for quarter screen
    /// - ``moveToTopRightQuarter(animated:options:)`` for quarter screen
    @discardableResult
    public func moveToTopHalf(
        animated: Bool = false,
        options: WindowAnimationOptions = .default
    ) -> WindowHandle? {
        guard let screenInfo = getScreenVisibleFrame() else { return nil }
        let visibleFrame = screenInfo.frame
        let halfHeight = ceil(visibleFrame.height / 2.0)

        let targetFrame = CGRect(
            x: visibleFrame.origin.x,
            y: visibleFrame.origin.y,
            width: visibleFrame.width,
            height: halfHeight
        )

        return setFrame(targetFrame, animated: animated, options: options)
    }

    /// Moves and resizes the window to fill the bottom half of its current screen.
    ///
    /// The window is positioned at the vertical center of the screen's visible area
    /// (accounting for the Dock if positioned at the bottom) and resized to occupy
    /// exactly 50% of the vertical space while filling the full horizontal width.
    ///
    /// The screen used is determined by the window's current center point location.
    ///
    /// - Parameters:
    ///   - animated: Whether to animate the transition. Defaults to `false`.
    ///   - options: Configuration for the animation timing and easing. Only used
    ///              when `animated` is `true`. Defaults to `.default`.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Snap to bottom half instantly
    /// Window.topmost()?.moveToBottomHalf()
    ///
    /// // Create a stacked layout
    /// App.Terminal?.firstWindow()?.moveToTopHalf()
    /// App.Safari?.firstWindow()?.moveToBottomHalf()
    /// ```
    ///
    /// ## See Also
    /// - ``moveToTopHalf(animated:options:)`` for the opposite half
    /// - ``moveToBottomLeftQuarter(animated:options:)`` for quarter screen
    /// - ``moveToBottomRightQuarter(animated:options:)`` for quarter screen
    @discardableResult
    public func moveToBottomHalf(
        animated: Bool = false,
        options: WindowAnimationOptions = .default
    ) -> WindowHandle? {
        guard let screenInfo = getScreenVisibleFrame() else { return nil }
        let visibleFrame = screenInfo.frame
        let topHalfHeight = ceil(visibleFrame.height / 2.0)
        let bottomHalfHeight = visibleFrame.height - topHalfHeight

        let targetFrame = CGRect(
            x: visibleFrame.origin.x,
            y: visibleFrame.origin.y + topHalfHeight,
            width: visibleFrame.width,
            height: bottomHalfHeight
        )

        return setFrame(targetFrame, animated: animated, options: options)
    }
    
    /// Moves and resizes the window to fill the left third of its current screen.
    ///
    /// The window is positioned at the left edge of the screen's visible area
    /// and resized to occupy exactly 33.3% of the horizontal space while filling
    /// the full vertical height. Ideal for three-column layouts.
    ///
    /// The screen used is determined by the window's current center point location.
    ///
    /// - Parameters:
    ///   - animated: Whether to animate the transition. Defaults to `false`.
    ///   - options: Configuration for the animation timing and easing. Only used
    ///              when `animated` is `true`. Defaults to `.default`.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Create a three-column layout
    /// App.Slack?.firstWindow()?.moveToLeftThird()
    /// App.VSCode?.firstWindow()?.moveToCenterThird()
    /// App.Safari?.firstWindow()?.moveToRightThird()
    /// ```
    ///
    /// ## See Also
    /// - ``moveToCenterThird(animated:options:)`` for the middle column
    /// - ``moveToRightThird(animated:options:)`` for the right column
    /// - ``moveToLeftHalf(animated:options:)`` for wider left layout
    @discardableResult
    public func moveToLeftThird(
        animated: Bool = false,
        options: WindowAnimationOptions = .default
    ) -> WindowHandle? {
        guard let screenInfo = getScreenVisibleFrame() else { return nil }
        let visibleFrame = screenInfo.frame
        let thirdWidth = visibleFrame.width / 3

        let targetFrame = CGRect(
            x: visibleFrame.origin.x,
            y: visibleFrame.origin.y,
            width: thirdWidth,
            height: visibleFrame.height
        )

        return setFrame(targetFrame, animated: animated, options: options)
    }

    /// Moves and resizes the window to fill the center third of its current screen.
    ///
    /// The window is positioned at the horizontal center of the screen's visible area
    /// and resized to occupy exactly 33.3% of the horizontal space while filling
    /// the full vertical height. Ideal for the middle column of three-column layouts.
    ///
    /// The screen used is determined by the window's current center point location.
    ///
    /// - Parameters:
    ///   - animated: Whether to animate the transition. Defaults to `false`.
    ///   - options: Configuration for the animation timing and easing. Only used
    ///              when `animated` is `true`. Defaults to `.default`.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Create a three-column layout
    /// App.Slack?.firstWindow()?.moveToLeftThird()
    /// App.VSCode?.firstWindow()?.moveToCenterThird()
    /// App.Safari?.firstWindow()?.moveToRightThird()
    ///
    /// // Focus window in center for focused work
    /// Window.topmost()?.moveToCenterThird(animated: true)
    /// ```
    ///
    /// ## See Also
    /// - ``moveToLeftThird(animated:options:)`` for the left column
    /// - ``moveToRightThird(animated:options:)`` for the right column
    /// - ``center(animated:options:)`` for centering without resize
    @discardableResult
    public func moveToCenterThird(
        animated: Bool = false,
        options: WindowAnimationOptions = .default
    ) -> WindowHandle? {
        guard let screenInfo = getScreenVisibleFrame() else { return nil }
        let visibleFrame = screenInfo.frame
        let thirdWidth = visibleFrame.width / 3

        let targetFrame = CGRect(
            x: visibleFrame.origin.x + thirdWidth,
            y: visibleFrame.origin.y,
            width: thirdWidth,
            height: visibleFrame.height
        )

        return setFrame(targetFrame, animated: animated, options: options)
    }

    /// Moves and resizes the window to fill the right third of its current screen.
    ///
    /// The window is positioned at the right edge of the screen's visible area
    /// and resized to occupy exactly 33.3% of the horizontal space while filling
    /// the full vertical height. Ideal for the right column of three-column layouts.
    ///
    /// The screen used is determined by the window's current center point location.
    ///
    /// - Parameters:
    ///   - animated: Whether to animate the transition. Defaults to `false`.
    ///   - options: Configuration for the animation timing and easing. Only used
    ///              when `animated` is `true`. Defaults to `.default`.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Create a three-column layout
    /// App.Slack?.firstWindow()?.moveToLeftThird()
    /// App.VSCode?.firstWindow()?.moveToCenterThird()
    /// App.Safari?.firstWindow()?.moveToRightThird()
    /// ```
    ///
    /// ## See Also
    /// - ``moveToLeftThird(animated:options:)`` for the left column
    /// - ``moveToCenterThird(animated:options:)`` for the middle column
    /// - ``moveToRightHalf(animated:options:)`` for wider right layout
    @discardableResult
    public func moveToRightThird(
        animated: Bool = false,
        options: WindowAnimationOptions = .default
    ) -> WindowHandle? {
        guard let screenInfo = getScreenVisibleFrame() else { return nil }
        let visibleFrame = screenInfo.frame
        let thirdWidth = visibleFrame.width / 3

        let targetFrame = CGRect(
            x: visibleFrame.origin.x + (thirdWidth * 2),
            y: visibleFrame.origin.y,
            width: thirdWidth,
            height: visibleFrame.height
        )

        return setFrame(targetFrame, animated: animated, options: options)
    }
    
    /// Moves and resizes the window to fill the top-left quarter of its current screen.
    ///
    /// The window is positioned at the top-left corner of the screen's visible area
    /// (accounting for menu bar and Dock) and resized to occupy exactly 25% of the
    /// screen space (half width, half height). Ideal for four-window grid layouts.
    ///
    /// The screen used is determined by the window's current center point location.
    ///
    /// - Parameters:
    ///   - animated: Whether to animate the transition. Defaults to `false`.
    ///   - options: Configuration for the animation timing and easing. Only used
    ///              when `animated` is `true`. Defaults to `.default`.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Create a four-window grid layout
    /// App.Safari?.firstWindow()?.moveToTopLeftQuarter()
    /// App.Notes?.firstWindow()?.moveToTopRightQuarter()
    /// App.Terminal?.firstWindow()?.moveToBottomLeftQuarter()
    /// App.Finder?.firstWindow()?.moveToBottomRightQuarter()
    /// ```
    ///
    /// ## See Also
    /// - ``moveToTopRightQuarter(animated:options:)`` for top-right corner
    /// - ``moveToBottomLeftQuarter(animated:options:)`` for bottom-left corner
    /// - ``moveToTopHalf(animated:options:)`` for top half layout
    /// - ``moveToLeftHalf(animated:options:)`` for left half layout
    @discardableResult
    public func moveToTopLeftQuarter(
        animated: Bool = false,
        options: WindowAnimationOptions = .default
    ) -> WindowHandle? {
        guard let screenInfo = getScreenVisibleFrame() else { return nil }
        let visibleFrame = screenInfo.frame
        let halfWidth = visibleFrame.width / 2
        let halfHeight = visibleFrame.height / 2

        let targetFrame = CGRect(
            x: visibleFrame.origin.x,
            y: visibleFrame.origin.y,
            width: halfWidth,
            height: halfHeight
        )

        return setFrame(targetFrame, animated: animated, options: options)
    }

    /// Moves and resizes the window to fill the top-right quarter of its current screen.
    ///
    /// The window is positioned at the top-right corner of the screen's visible area
    /// (accounting for menu bar and Dock) and resized to occupy exactly 25% of the
    /// screen space (half width, half height). Ideal for four-window grid layouts.
    ///
    /// The screen used is determined by the window's current center point location.
    ///
    /// - Parameters:
    ///   - animated: Whether to animate the transition. Defaults to `false`.
    ///   - options: Configuration for the animation timing and easing. Only used
    ///              when `animated` is `true`. Defaults to `.default`.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Create a four-window grid layout
    /// App.Safari?.firstWindow()?.moveToTopLeftQuarter()
    /// App.Notes?.firstWindow()?.moveToTopRightQuarter()
    /// App.Terminal?.firstWindow()?.moveToBottomLeftQuarter()
    /// App.Finder?.firstWindow()?.moveToBottomRightQuarter()
    /// ```
    ///
    /// ## See Also
    /// - ``moveToTopLeftQuarter(animated:options:)`` for top-left corner
    /// - ``moveToBottomRightQuarter(animated:options:)`` for bottom-right corner
    /// - ``moveToTopHalf(animated:options:)`` for top half layout
    /// - ``moveToRightHalf(animated:options:)`` for right half layout
    @discardableResult
    public func moveToTopRightQuarter(
        animated: Bool = false,
        options: WindowAnimationOptions = .default
    ) -> WindowHandle? {
        guard let screenInfo = getScreenVisibleFrame() else { return nil }
        let visibleFrame = screenInfo.frame
        let halfWidth = visibleFrame.width / 2
        let halfHeight = visibleFrame.height / 2

        let targetFrame = CGRect(
            x: visibleFrame.origin.x + halfWidth,
            y: visibleFrame.origin.y,
            width: halfWidth,
            height: halfHeight
        )

        return setFrame(targetFrame, animated: animated, options: options)
    }

    /// Moves and resizes the window to fill the bottom-left quarter of its current screen.
    ///
    /// The window is positioned at the bottom-left corner of the screen's visible area
    /// (accounting for Dock if positioned at left or bottom) and resized to occupy exactly
    /// 25% of the screen space (half width, half height). Ideal for four-window grid layouts.
    ///
    /// The screen used is determined by the window's current center point location.
    ///
    /// - Parameters:
    ///   - animated: Whether to animate the transition. Defaults to `false`.
    ///   - options: Configuration for the animation timing and easing. Only used
    ///              when `animated` is `true`. Defaults to `.default`.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Create a four-window grid layout
    /// App.Safari?.firstWindow()?.moveToTopLeftQuarter()
    /// App.Notes?.firstWindow()?.moveToTopRightQuarter()
    /// App.Terminal?.firstWindow()?.moveToBottomLeftQuarter()
    /// App.Finder?.firstWindow()?.moveToBottomRightQuarter()
    /// ```
    ///
    /// ## See Also
    /// - ``moveToTopLeftQuarter(animated:options:)`` for top-left corner
    /// - ``moveToBottomRightQuarter(animated:options:)`` for bottom-right corner
    /// - ``moveToBottomHalf(animated:options:)`` for bottom half layout
    /// - ``moveToLeftHalf(animated:options:)`` for left half layout
    @discardableResult
    public func moveToBottomLeftQuarter(
        animated: Bool = false,
        options: WindowAnimationOptions = .default
    ) -> WindowHandle? {
        guard let screenInfo = getScreenVisibleFrame() else { return nil }
        let visibleFrame = screenInfo.frame
        let halfWidth = visibleFrame.width / 2
        let halfHeight = visibleFrame.height / 2

        let targetFrame = CGRect(
            x: visibleFrame.origin.x,
            y: visibleFrame.origin.y + halfHeight,
            width: halfWidth,
            height: halfHeight
        )

        return setFrame(targetFrame, animated: animated, options: options)
    }

    /// Moves and resizes the window to fill the bottom-right quarter of its current screen.
    ///
    /// The window is positioned at the bottom-right corner of the screen's visible area
    /// (accounting for Dock if positioned at right or bottom) and resized to occupy exactly
    /// 25% of the screen space (half width, half height). Ideal for four-window grid layouts.
    ///
    /// The screen used is determined by the window's current center point location.
    ///
    /// - Parameters:
    ///   - animated: Whether to animate the transition. Defaults to `false`.
    ///   - options: Configuration for the animation timing and easing. Only used
    ///              when `animated` is `true`. Defaults to `.default`.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Create a four-window grid layout
    /// App.Safari?.firstWindow()?.moveToTopLeftQuarter()
    /// App.Notes?.firstWindow()?.moveToTopRightQuarter()
    /// App.Terminal?.firstWindow()?.moveToBottomLeftQuarter()
    /// App.Finder?.firstWindow()?.moveToBottomRightQuarter()
    /// ```
    ///
    /// ## See Also
    /// - ``moveToTopRightQuarter(animated:options:)`` for top-right corner
    /// - ``moveToBottomLeftQuarter(animated:options:)`` for bottom-left corner
    /// - ``moveToBottomHalf(animated:options:)`` for bottom half layout
    /// - ``moveToRightHalf(animated:options:)`` for right half layout
    @discardableResult
    public func moveToBottomRightQuarter(
        animated: Bool = false,
        options: WindowAnimationOptions = .default
    ) -> WindowHandle? {
        guard let screenInfo = getScreenVisibleFrame() else { return nil }
        let visibleFrame = screenInfo.frame
        let halfWidth = visibleFrame.width / 2
        let halfHeight = visibleFrame.height / 2

        let targetFrame = CGRect(
            x: visibleFrame.origin.x + halfWidth,
            y: visibleFrame.origin.y + halfHeight,
            width: halfWidth,
            height: halfHeight
        )

        return setFrame(targetFrame, animated: animated, options: options)
    }
    
    /// Maximizes the window to fill the entire visible area of its current screen.
    ///
    /// The window is resized to occupy the full visible area of the screen, accounting
    /// for the menu bar and Dock. This is different from macOS full-screen mode (green
    /// button) - the window remains in normal mode but fills the available space.
    ///
    /// The screen used is determined by the window's current center point location.
    ///
    /// - Parameters:
    ///   - animated: Whether to animate the transition. Defaults to `false`.
    ///   - options: Configuration for the animation timing and easing. Only used
    ///              when `animated` is `true`. Defaults to `.default`.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Maximize window instantly
    /// Window.topmost()?.maximize()
    ///
    /// // Animate window to fill screen
    /// App.Safari?.firstWindow()?.maximize(animated: true, options: .smooth)
    ///
    /// // Maximize and activate
    /// App.VSCode?.firstWindow()?.maximize()?.activate()
    /// ```
    ///
    /// ## See Also
    /// - ``center(animated:options:)`` for centering without resize
    /// - ``moveToLeftHalf(animated:options:)`` for half-screen layout
    /// - ``setFrame(_:animated:options:)`` for custom frame
    @discardableResult
    public func maximize(
        animated: Bool = false,
        options: WindowAnimationOptions = .default
    ) -> WindowHandle? {
        guard let screenInfo = getScreenVisibleFrame() else { return nil }
        return setFrame(screenInfo.frame, animated: animated, options: options)
    }

    /// Centers the window on its current screen without changing its size.
    ///
    /// Repositions the window so its center point aligns with the center of the
    /// screen's visible area. The window's dimensions remain unchanged.
    ///
    /// The screen used is determined by the window's current center point location.
    ///
    /// - Parameters:
    ///   - animated: Whether to animate the transition. Defaults to `false`.
    ///   - options: Configuration for the animation timing and easing. Only used
    ///              when `animated` is `true`. Defaults to `.default`.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Center window instantly
    /// Window.topmost()?.center()
    ///
    /// // Animate centering with smooth easing
    /// Window.topmost()?.center(animated: true, options: .smooth)
    ///
    /// // Center and bring to front
    /// App.Finder?.firstWindow()?.center()?.raise()?.activate()
    ///
    /// // Resize then center
    /// Window.topmost()?.resize(width: 800, height: 600)?.center()
    /// ```
    ///
    /// ## See Also
    /// - ``moveToCenterThird(animated:options:)`` for centering with resize to third
    /// - ``maximize(animated:options:)`` for filling the screen
    /// - ``moveTo(x:y:)`` for exact positioning
    @discardableResult
    public func center(
        animated: Bool = false,
        options: WindowAnimationOptions = .default
    ) -> WindowHandle? {
        guard let window = axWindow,
              let screenInfo = getScreenVisibleFrame() else { return nil }
        let visibleFrame = screenInfo.frame

        let centerX = visibleFrame.origin.x + (visibleFrame.width - window.frame.width) / 2
        let centerY = visibleFrame.origin.y + (visibleFrame.height - window.frame.height) / 2

        let targetFrame = CGRect(x: centerX, y: centerY, width: window.frame.width, height: window.frame.height)
        return setFrame(targetFrame, animated: animated, options: options)
    }
    
    // MARK: - State Operations (Chainable)

    /// Minimizes the window to the Dock.
    ///
    /// The window is collapsed into the Dock, either into the application's icon
    /// or into a separate minimized window area (depending on System Preferences).
    /// A minimized window remains in memory but is not visible on screen.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Minimize the topmost window
    /// Window.topmost()?.minimize()
    ///
    /// // Minimize all Safari windows
    /// App.Safari?.allWindows().forEach { $0.minimize() }
    /// ```
    ///
    /// ## See Also
    /// - ``unminimize()`` to restore a minimized window
    /// - ``restore()`` alias for unminimize
    /// - ``hide()`` to hide the entire application
    @discardableResult
    public func minimize() -> WindowHandle? {
        guard let window = axWindow,
              let service = axService else {
            return nil
        }
        
        let success = service.minimize(window)
        
        if success {
            axWindow = service.refresh(window)
        }
        
        return success ? self : nil
    }
    
    /// Restores a minimized window from the Dock.
    ///
    /// Brings the window back from its minimized state in the Dock to its
    /// previous position and size on screen. The window becomes visible
    /// but may not be focused (use ``activate()`` to also bring it to front).
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Restore and activate a minimized window
    /// Window.topmost()?.unminimize()?.activate()
    ///
    /// // Restore first Finder window
    /// App.Finder?.firstWindow()?.unminimize()
    ///
    /// // Restore, move to position, then activate
    /// App.Safari?.firstWindow()?
    ///     .unminimize()?
    ///     .moveTo(x: 0, y: 0)?
    ///     .activate()
    /// ```
    ///
    /// ## See Also
    /// - ``minimize()`` to minimize a window
    /// - ``restore()`` alias for this method
    /// - ``unhide()`` to unhide the entire application
    @discardableResult
    public func unminimize() -> WindowHandle? {
        guard let window = axWindow,
              let service = axService else {
            return nil
        }
        
        let success = service.restore(window)
        
        if success {
            axWindow = service.refresh(window)
        }
        
        return success ? self : nil
    }
    
    /// Restores a minimized window from the Dock (alias for ``unminimize()``).
    ///
    /// This method is functionally identical to ``unminimize()`` and is provided
    /// for API convenience and readability in different contexts.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Restore a minimized window
    /// Window.topmost()?.restore()?.activate()
    ///
    /// // Equivalent to:
    /// Window.topmost()?.unminimize()?.activate()
    /// ```
    ///
    /// ## See Also
    /// - ``unminimize()`` for the primary method
    /// - ``minimize()`` to minimize a window
    @discardableResult
    public func restore() -> WindowHandle? {
        return unminimize()
    }
    
    /// Closes the window.
    ///
    /// Triggers the window's close button action, which typically closes the window
    /// and may prompt the user to save unsaved changes (depending on the application).
    /// After closing, the underlying window reference becomes invalid.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed. Note that
    ///            even on success, the window is now closed and the handle should
    ///            not be used for further operations.
    ///
    /// - Important: After calling `close()`, the window no longer exists and this
    ///              handle should be discarded. The ``exists`` property will return
    ///              `false` and further operations will fail.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Close the topmost window
    /// Window.topmost()?.close()
    ///
    /// // Close all windows of an app (use with caution)
    /// App.Safari?.allWindows().forEach { $0.close() }
    ///
    /// // Check if close succeeded
    /// if Window.topmost()?.close() != nil {
    ///     print("Window closed successfully")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``minimize()`` to collapse to Dock instead of closing
    /// - ``hide()`` to hide the application without closing
    @discardableResult
    public func close() -> WindowHandle? {
        guard let window = axWindow,
              let service = axService else {
            return nil
        }
        
        let success = service.close(window)
        
        if success {
            axWindow = nil
        }
        
        return success ? self : nil
    }
    
    /// Hides the window's entire application.
    ///
    /// Hides all windows of the application that owns this window, equivalent to
    /// pressing Cmd+H or selecting "Hide [App Name]" from the application menu.
    /// Hidden applications remain running in the background but all their windows
    /// become invisible.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// - Note: This hides the **entire application**, not just this specific window.
    ///         To hide a single window, use ``minimize()`` instead.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Hide Safari
    /// App.Safari?.firstWindow()?.hide()
    ///
    /// // Hide the app owning the topmost window
    /// Window.topmost()?.hide()
    /// ```
    ///
    /// ## See Also
    /// - ``unhide()`` to make the application visible again
    /// - ``minimize()`` to minimize a single window
    /// - ``isHidden`` to check if the application is hidden
    @discardableResult
    public func hide() -> WindowHandle? {
        guard let window = axWindow,
              let service = axService else {
            return nil
        }
        
        // Hide via AX app element
        if let appElement = service.createAppElement(for: window.processID) {
            let success = service.hideApp(appElement)
            if success {
                axWindow = service.refresh(window)
                return self
            }
        }
        
        // Fallback: hide via NSRunningApplication
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == window.processID }) {
            let success = app.hide()
            if success {
                axWindow = service.refresh(window)
                return self
            }
        }
        
        return nil
    }
    
    /// Unhides the window's application, making all its windows visible again.
    ///
    /// Reverses the effect of ``hide()``, making all windows of the application
    /// visible again. The windows return to their previous positions but the
    /// application may not be brought to the foreground (use ``activate()`` for that).
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Unhide Safari and bring to front
    /// App.Safari?.firstWindow()?.unhide()?.activate()
    ///
    /// // Unhide the app owning a window and center it
    /// windowHandle.unhide()?.center()?.activate()
    /// ```
    ///
    /// ## See Also
    /// - ``hide()`` to hide the application
    /// - ``unminimize()`` to restore a minimized window
    /// - ``activate()`` to bring the window to front
    @discardableResult
    public func unhide() -> WindowHandle? {
        guard let window = axWindow,
              let service = axService else {
            return nil
        }
        
        // Unhide via NSRunningApplication
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == window.processID }) {
            let success = app.unhide()
            if success {
                axWindow = service.refresh(window)
                return self
            }
        }
        
        return nil
    }
    
    /// Activates the window, bringing it to the front and giving it keyboard focus.
    ///
    /// Makes this window the active (frontmost) window and focuses it to receive
    /// keyboard input. Also activates the owning application if it's not already
    /// in the foreground. This is the most common way to bring a window to the
    /// user's attention.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Bring topmost window to front
    /// Window.topmost()?.activate()
    ///
    /// // Common pattern: position then activate
    /// App.Safari?.firstWindow()?
    ///     .moveToLeftHalf()?
    ///     .activate()
    ///
    /// // Restore and activate a minimized window
    /// App.Finder?.firstWindow()?.unminimize()?.activate()
    /// ```
    ///
    /// ## See Also
    /// - ``raise()`` to bring to front within the app only
    /// - ``tap()`` to click the window center
    /// - ``unhide()`` if the application is hidden
    @discardableResult
    public func activate() -> WindowHandle? {
        guard let window = axWindow,
              let service = axService else {
            return nil
        }
        
        let success = service.activate(window)
        return success ? self : nil
    }
    
    /// Raises the window to the front within its owning application.
    ///
    /// Brings this window to the front of its application's window stack without
    /// necessarily activating the application or giving it keyboard focus. Use this
    /// when you want to reorder windows within an app without stealing focus.
    ///
    /// For bringing a window completely to the foreground with focus, use ``activate()``
    /// instead.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Raise window within its app
    /// Window.topmost()?.raise()
    ///
    /// // Common pattern: raise then activate
    /// App.Safari?.window(at: 1)?.raise()?.activate()
    ///
    /// // Raise without stealing focus from current app
    /// App.Finder?.firstWindow()?.raise()
    /// ```
    ///
    /// ## See Also
    /// - ``activate()`` to also give the window keyboard focus
    /// - ``tap()`` to click the window center
    @discardableResult
    public func raise() -> WindowHandle? {
        guard let window = axWindow,
              let service = axService else {
            return nil
        }
        
        let success = service.raise(window)
        return success ? self : nil
    }
    
    /// Simulates a mouse click at the center of the window.
    ///
    /// Posts a left mouse button down and up event at the center point of the
    /// window's frame. This can be useful for activating windows that don't
    /// respond well to Accessibility API activation, or for triggering click
    /// handlers in the window content.
    ///
    /// The click occurs at the exact center of the window's current frame,
    /// regardless of what UI element is at that location.
    ///
    /// - Returns: Self for chaining, or `nil` if the operation failed
    ///
    /// - Warning: This simulates an actual mouse click, which may have unintended
    ///            effects depending on what UI element is at the window's center.
    ///            Use ``activate()`` for simply bringing a window to front.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Click center of window to activate it
    /// Window.topmost()?.tap()
    ///
    /// // Raise then tap for stubborn windows
    /// App.Safari?.firstWindow()?.raise()?.tap()
    /// ```
    ///
    /// ## See Also
    /// - ``activate()`` for standard window activation
    /// - ``raise()`` to bring to front without clicking
    @discardableResult
    public func tap(preserveMousePosition: Bool = false) -> WindowHandle? {
        guard let window = axWindow else {
            return nil
        }
        
        // Calculate center point of window
        let centerX = window.frame.origin.x + window.frame.width / 2
        let centerY = window.frame.origin.y + window.frame.height / 2
        let clickPoint = CGPoint(x: centerX, y: centerY)

        let originalPosition: CGPoint?
        if preserveMousePosition {
            let originalScreenPosition = NSEvent.mouseLocation
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            originalPosition = CGPoint(
                x: originalScreenPosition.x,
                y: screenHeight - originalScreenPosition.y
            )
            CGWarpMouseCursorPosition(clickPoint)
        } else {
            originalPosition = nil
        }

        guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: clickPoint, mouseButton: .left),
              let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: clickPoint, mouseButton: .left) else {
            if let originalPosition {
                CGWarpMouseCursorPosition(originalPosition)
            }
            return nil
        }

        mouseDown.post(tap: .cghidEventTap)
        usleep(10000)
        mouseUp.post(tap: .cghidEventTap)

        if let originalPosition {
            usleep(50000)
            CGWarpMouseCursorPosition(originalPosition)
        }

        return self
    }
    
    // MARK: - State Queries (Non-Chainable)

    /// The current frame (position and size) of the window in screen coordinates.
    ///
    /// Returns the window's rectangle in the screen coordinate system, where the
    /// origin (0, 0) is at the top-left corner of the primary display.
    ///
    /// This property is `nil` if the window no longer exists or was never valid.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get window dimensions
    /// if let frame = Window.topmost()?.frame {
    ///     print("Window at (\(frame.origin.x), \(frame.origin.y))")
    ///     print("Size: \(frame.width) x \(frame.height)")
    /// }
    ///
    /// // Check if window is in left half of screen
    /// if let frame = Window.topmost()?.frame,
    ///    let screen = NSScreen.main?.visibleFrame {
    ///     let inLeftHalf = frame.origin.x < screen.width / 2
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``setFrame(_:animated:options:)`` to change the frame
    /// - ``moveTo(x:y:)`` to change position only
    /// - ``resize(width:height:)`` to change size only
    public var frame: CGRect? {
        return axWindow?.frame
    }
    
    /// Indicates whether the window is currently minimized to the Dock.
    ///
    /// Returns `true` if the window is collapsed into the Dock, `false` if
    /// it's visible on screen. If the window handle is invalid, returns `false`.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Check before trying to move
    /// if let window = Window.topmost(), !window.isMinimized {
    ///     window.moveToLeftHalf()
    /// }
    ///
    /// // Restore minimized windows only
    /// for window in App.Safari?.allWindows() ?? [] {
    ///     if window.isMinimized {
    ///         window.unminimize()?.activate()
    ///     }
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``minimize()`` to minimize the window
    /// - ``unminimize()`` to restore a minimized window
    /// - ``isHidden`` to check if the application is hidden
    public var isMinimized: Bool {
        return axWindow?.isMinimized ?? false
    }
    
    /// Indicates whether the window's application is currently hidden.
    ///
    /// Returns `true` if the owning application has been hidden (e.g., via Cmd+H),
    /// making all its windows invisible. Returns `false` if the application is
    /// visible. If the window handle is invalid, returns `false`.
    ///
    /// - Note: This reflects the hidden state of the **entire application**,
    ///         not just this specific window. Individual windows cannot be hidden
    ///         without hiding the whole app.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Check if app is hidden before operations
    /// if let window = App.Safari?.firstWindow(), window.isHidden {
    ///     window.unhide()?.activate()
    /// }
    ///
    /// // Filter to visible windows only
    /// let visibleWindows = App.Safari?.allWindows().filter { !$0.isHidden }
    /// ```
    ///
    /// ## See Also
    /// - ``hide()`` to hide the application
    /// - ``unhide()`` to make the application visible
    /// - ``isMinimized`` to check if a specific window is minimized
    public var isHidden: Bool {
        return axWindow?.isHidden ?? false
    }
    
    /// The title of the window as displayed in its title bar.
    ///
    /// Returns the current title text of the window, which typically includes
    /// the document name, application name, or other contextual information.
    /// Returns `nil` if the window has no title or the handle is invalid.
    ///
    /// - Note: Window titles can change dynamically (e.g., when a document is
    ///         saved or a web page navigates). Use ``refresh()`` to update the
    ///         cached window state if needed.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Print all window titles for an app
    /// for window in App.Safari?.allWindows() ?? [] {
    ///     print("Window: \(window.title ?? "Untitled")")
    /// }
    ///
    /// // Find window by title
    /// let docWindow = App.VSCode?.allWindows().first {
    ///     $0.title?.contains("CLAUDE.md") ?? false
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``appName`` for the application name
    /// - ``exists`` to check if the window is still valid
    /// - ``refresh()`` to update window state
    public var title: String? {
        return axWindow?.title
    }
    
    /// Indicates whether this handle references a valid, existing window.
    ///
    /// Returns `true` if the underlying window reference is valid, `false` if
    /// the window has been closed, the handle was never initialized with a valid
    /// window, or the window reference has become stale.
    ///
    /// - Note: This checks the cached state. The window may have been closed
    ///         since the last operation. Use ``refresh()`` to verify the window
    ///         still exists in the system.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Check before operations
    /// if let window = Window.topmost(), window.exists {
    ///     window.moveToLeftHalf()
    /// }
    ///
    /// // After closing, exists returns false
    /// let window = Window.topmost()
    /// window?.close()
    /// print(window?.exists ?? false)  // false
    ///
    /// // Refresh to verify current state
    /// if window?.refresh() != nil {
    ///     print("Window still exists")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``refresh()`` to update and verify window state
    /// - ``close()`` which invalidates the window
    public var exists: Bool {
        return axWindow != nil
    }
    
    /// The localized name of the application that owns this window.
    ///
    /// Returns the human-readable application name (e.g., "Safari", "Finder",
    /// "Visual Studio Code") as shown in the Dock and menu bar. This is looked
    /// up from the running application's `localizedName` property.
    ///
    /// Returns `nil` if the window handle is invalid or the application cannot
    /// be found.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get app name for topmost window
    /// if let appName = Window.topmost()?.appName {
    ///     print("Active app: \(appName)")
    /// }
    ///
    /// // Log window information
    /// if let window = Window.topmost() {
    ///     print("\(window.appName ?? "Unknown"): \(window.title ?? "Untitled")")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``bundleIdentifier`` for the unique app identifier
    /// - ``processID`` for the system process ID
    /// - ``title`` for the window's title
    public var appName: String? {
        guard let window = axWindow else { return nil }
        // Get app name from NSRunningApplication
        return NSWorkspace.shared.runningApplications
            .first { $0.processIdentifier == window.processID }?
            .localizedName
    }
    
    /// The bundle identifier of the application that owns this window.
    ///
    /// Returns the unique reverse-DNS style identifier for the application
    /// (e.g., "com.apple.Safari", "com.google.Chrome"). This is the most reliable
    /// way to identify an application across different systems and localizations.
    ///
    /// Returns `nil` if the window handle is invalid or the bundle identifier
    /// is not available.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Check which app owns the window
    /// if let bundleId = Window.topmost()?.bundleIdentifier {
    ///     switch bundleId {
    ///     case "com.apple.Safari":
    ///         print("This is a Safari window")
    ///     case "com.google.Chrome":
    ///         print("This is a Chrome window")
    ///     default:
    ///         print("Other app: \(bundleId)")
    ///     }
    /// }
    ///
    /// // Filter windows by bundle ID
    /// let chromeWindows = Window.all().filter {
    ///     $0.bundleIdentifier == "com.google.Chrome"
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``appName`` for the human-readable application name
    /// - ``processID`` for the system process ID
    public var bundleIdentifier: String? {
        return axWindow?.bundleIdentifier
    }
    
    /// The UNIX process ID (PID) of the application that owns this window.
    ///
    /// Returns the system process identifier for the owning application. This
    /// can be used for lower-level system operations or to correlate with other
    /// process information (e.g., from `ps` or Activity Monitor).
    ///
    /// Returns `nil` if the window handle is invalid.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Get process ID for debugging
    /// if let pid = Window.topmost()?.processID {
    ///     print("Process ID: \(pid)")
    /// }
    ///
    /// // Find NSRunningApplication for the window
    /// if let pid = Window.topmost()?.processID {
    ///     let app = NSRunningApplication(processIdentifier: pid)
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``bundleIdentifier`` for the unique app identifier
    /// - ``appName`` for the human-readable application name
    public var processID: pid_t? {
        return axWindow?.processID
    }
    
    /// The underlying `AXWindow` model object (for advanced use).
    ///
    /// Provides direct access to the `AXWindow` struct that contains the raw
    /// window data and Accessibility API element. Use this when you need to
    /// access properties or perform operations not exposed by `WindowHandle`.
    ///
    /// Returns `nil` if the window handle is invalid.
    ///
    /// - Warning: Modifying the `AXWindow` directly may cause the `WindowHandle`
    ///            state to become out of sync. Use ``refresh()`` after direct
    ///            modifications to update the handle's state.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Access raw window data
    /// if let axWindow = Window.topmost()?.window {
    ///     print("Window layer: \(axWindow.layer)")
    ///     print("Identity key: \(axWindow.identityKey)")
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``axElement`` for the Accessibility API element
    /// - ``refresh()`` to update window state
    /// - ``AXWindow`` for the underlying model
    public var window: AXWindow? {
        return axWindow
    }
    
    /// The Accessibility API element for direct manipulation (for advanced use).
    ///
    /// Provides direct access to the `AXUIElement` that represents this window
    /// in the macOS Accessibility framework. Use this for performing AX operations
    /// not available through the `WindowHandle` API.
    ///
    /// Returns `nil` if the window handle is invalid.
    ///
    /// - Warning: Direct manipulation of the `AXUIElement` bypasses `WindowHandle`'s
    ///            state management. Use ``refresh()`` after direct modifications to
    ///            update the handle's cached state.
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Perform custom AX query
    /// if let element = Window.topmost()?.axElement {
    ///     var value: CFTypeRef?
    ///     let result = AXUIElementCopyAttributeValue(
    ///         element,
    ///         kAXRoleAttribute as CFString,
    ///         &value
    ///     )
    ///     if result == .success, let role = value as? String {
    ///         print("AX Role: \(role)")
    ///     }
    /// }
    /// ```
    ///
    /// ## See Also
    /// - ``window`` for the underlying AXWindow model
    /// - ``refresh()`` to update window state
    public var axElement: AXUIElement? {
        return axWindow?.axElement
    }
    
    // MARK: - Refresh

    /// Refreshes the window's state from the system.
    ///
    /// Queries the Accessibility API to update all cached window properties
    /// (frame, title, minimized state, etc.) to reflect the current system state.
    /// This is useful when you need to verify that a window still exists or get
    /// its current state after external changes.
    ///
    /// If the window no longer exists (was closed or the application quit),
    /// this method invalidates the handle and returns `nil`.
    ///
    /// - Returns: Self for chaining, or `nil` if the window no longer exists
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Verify window still exists after delay
    /// let window = Window.topmost()
    /// // ... time passes ...
    /// if window?.refresh() != nil {
    ///     print("Window still exists with title: \(window?.title ?? "Unknown")")
    /// } else {
    ///     print("Window was closed")
    /// }
    ///
    /// // Refresh before reading current state
    /// if let frame = Window.topmost()?.refresh()?.frame {
    ///     print("Current frame: \(frame)")
    /// }
    ///
    /// // Chain refresh with operations
    /// Window.topmost()?.refresh()?.moveToLeftHalf()?.activate()
    /// ```
    ///
    /// ## See Also
    /// - ``exists`` to check if the handle is valid (without refreshing)
    /// - ``frame`` and other properties that use cached state
    @discardableResult
    public func refresh() -> WindowHandle? {
        guard let window = axWindow,
              let service = axService else {
            return nil
        }
        
        if let refreshed = service.refresh(window) {
            axWindow = refreshed
            return self
        }
        
        // Window no longer exists
        axWindow = nil
        return nil
    }
}

// MARK: - Equatable

extension WindowHandle: Equatable {
    public static func == (lhs: WindowHandle, rhs: WindowHandle) -> Bool {
        // Compare by identity key since AXWindow doesn't have CGWindowID
        return lhs.axWindow?.identityKey == rhs.axWindow?.identityKey
    }
}

// MARK: - Hashable

extension WindowHandle: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(axWindow?.identityKey)
    }
}

// MARK: - CustomStringConvertible

extension WindowHandle: CustomStringConvertible {
    public var description: String {
        guard let window = axWindow else {
            return "WindowHandle(nil)"
        }
        let frameDesc = String(format: "(%.0f, %.0f) %.0fx%.0f",
                              window.frame.origin.x, window.frame.origin.y,
                              window.frame.width, window.frame.height)
        return "WindowHandle(\(appName ?? "Unknown"): \"\(window.title)\", \(frameDesc))"
    }
}
