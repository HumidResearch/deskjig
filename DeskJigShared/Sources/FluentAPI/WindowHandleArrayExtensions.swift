//  WindowHandleArrayExtensions.swift
//  DeskJigShared

import Foundation
import AppKit

// MARK: - Chainable Filters for [WindowHandle]

extension Array where Element == WindowHandle {

    // MARK: - Screen Filtering

    /// Returns windows on the specified display index.
    ///
    /// - Parameter index: The display index (0 = main display)
    /// - Returns: Filtered array of windows on that screen
    public func onScreen(_ index: Int) -> [WindowHandle] {
        let screens = NSScreen.screens
        guard index >= 0 && index < screens.count else { return [] }

        let targetScreen = screens[index]
        let screenFrame = targetScreen.frame

        return filter { handle in
            guard let frame = handle.frame else { return false }
            let windowCenter = CGPoint(x: frame.midX, y: frame.midY)
            return screenFrame.contains(windowCenter)
        }
    }

    /// Returns windows on the main display.
    ///
    /// - Returns: Filtered array of windows on the main screen
    public func onMainScreen() -> [WindowHandle] {
        guard let mainScreen = NSScreen.main else { return [] }
        let mainFrame = mainScreen.frame

        return filter { handle in
            guard let frame = handle.frame else { return false }
            let windowCenter = CGPoint(x: frame.midX, y: frame.midY)
            return mainFrame.contains(windowCenter)
        }
    }

    /// Returns windows on a specific display ID.
    ///
    /// - Parameter displayID: The CGDirectDisplayID
    /// - Returns: Filtered array of windows on that display
    public func onDisplay(_ displayID: CGDirectDisplayID) -> [WindowHandle] {
        let displayBounds = CGDisplayBounds(displayID)

        return filter { handle in
            guard let frame = handle.frame else { return false }
            let windowCenter = CGPoint(x: frame.midX, y: frame.midY)
            return displayBounds.contains(windowCenter)
        }
    }

    // MARK: - Size Filtering

    /// Returns windows with at least the specified minimum dimensions.
    ///
    /// - Parameters:
    ///   - width: Minimum width (pass 0 to ignore)
    ///   - height: Minimum height (pass 0 to ignore)
    /// - Returns: Filtered array of windows meeting size requirements
    public func withMinSize(width: CGFloat, height: CGFloat) -> [WindowHandle] {
        return filter { handle in
            guard let frame = handle.frame else { return false }
            return frame.width >= width && frame.height >= height
        }
    }

    /// Returns windows with at most the specified maximum dimensions.
    ///
    /// - Parameters:
    ///   - width: Maximum width (pass CGFloat.greatestFiniteMagnitude to ignore)
    ///   - height: Maximum height (pass CGFloat.greatestFiniteMagnitude to ignore)
    /// - Returns: Filtered array of windows meeting size requirements
    public func withMaxSize(width: CGFloat, height: CGFloat) -> [WindowHandle] {
        return filter { handle in
            guard let frame = handle.frame else { return false }
            return frame.width <= width && frame.height <= height
        }
    }

    /// Returns windows with dimensions within the specified range.
    ///
    /// - Parameters:
    ///   - minWidth: Minimum width
    ///   - maxWidth: Maximum width
    ///   - minHeight: Minimum height
    ///   - maxHeight: Maximum height
    /// - Returns: Filtered array of windows within size range
    public func withSizeRange(
        minWidth: CGFloat = 0,
        maxWidth: CGFloat = .greatestFiniteMagnitude,
        minHeight: CGFloat = 0,
        maxHeight: CGFloat = .greatestFiniteMagnitude
    ) -> [WindowHandle] {
        return filter { handle in
            guard let frame = handle.frame else { return false }
            return frame.width >= minWidth && frame.width <= maxWidth &&
                   frame.height >= minHeight && frame.height <= maxHeight
        }
    }

    // MARK: - State Filtering

    /// Returns only visible windows (not minimized, not hidden).
    ///
    /// - Returns: Filtered array of visible windows
    public func visible() -> [WindowHandle] {
        return filter { handle in
            !handle.isMinimized && !handle.isHidden
        }
    }

    /// Returns only minimized windows.
    ///
    /// - Returns: Filtered array of minimized windows
    public func minimized() -> [WindowHandle] {
        return filter { $0.isMinimized }
    }

    /// Returns only hidden windows (app is hidden).
    ///
    /// - Returns: Filtered array of hidden windows
    public func hidden() -> [WindowHandle] {
        return filter { $0.isHidden }
    }

    /// Returns only non-minimized windows.
    ///
    /// - Returns: Filtered array of non-minimized windows
    public func notMinimized() -> [WindowHandle] {
        return filter { !$0.isMinimized }
    }

    /// Returns only non-hidden windows.
    ///
    /// - Returns: Filtered array of non-hidden windows
    public func notHidden() -> [WindowHandle] {
        return filter { !$0.isHidden }
    }

    // MARK: - Title Filtering

    /// Returns windows with the exact title.
    ///
    /// - Parameter title: The exact title to match
    /// - Returns: Filtered array of windows with matching title
    public func titled(_ title: String) -> [WindowHandle] {
        return filter { $0.title == title }
    }

    /// Returns windows with titles containing the specified substring.
    ///
    /// - Parameter substring: The substring to search for
    /// - Returns: Filtered array of windows with matching titles
    public func titledContaining(_ substring: String) -> [WindowHandle] {
        return filter { handle in
            guard let title = handle.title else { return false }
            return title.contains(substring)
        }
    }

    /// Returns windows with titles matching the regex pattern.
    ///
    /// - Parameter pattern: The regex pattern to match
    /// - Returns: Filtered array of windows with matching titles
    public func titledMatching(_ pattern: String) -> [WindowHandle] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        return filter { handle in
            guard let title = handle.title else { return false }
            let range = NSRange(title.startIndex..<title.endIndex, in: title)
            return regex.firstMatch(in: title, range: range) != nil
        }
    }

    /// Returns windows with non-empty titles.
    ///
    /// - Returns: Filtered array of windows with titles
    public func withTitle() -> [WindowHandle] {
        return filter { handle in
            guard let title = handle.title else { return false }
            return !title.isEmpty
        }
    }

    // MARK: - Frame/Position Filtering

    /// Returns windows whose frame is contained within the specified rect.
    ///
    /// - Parameter rect: The bounding rect
    /// - Returns: Filtered array of windows within the rect
    public func withinFrame(_ rect: CGRect) -> [WindowHandle] {
        return filter { handle in
            guard let frame = handle.frame else { return false }
            return rect.contains(frame)
        }
    }

    /// Returns windows whose center point is within the specified rect.
    ///
    /// - Parameter rect: The bounding rect
    /// - Returns: Filtered array of windows with centers in the rect
    public func centeredWithin(_ rect: CGRect) -> [WindowHandle] {
        return filter { handle in
            guard let frame = handle.frame else { return false }
            let center = CGPoint(x: frame.midX, y: frame.midY)
            return rect.contains(center)
        }
    }

    /// Returns windows containing the specified point.
    ///
    /// - Parameter point: The point to test
    /// - Returns: Filtered array of windows containing the point
    public func atLocation(_ point: CGPoint) -> [WindowHandle] {
        return filter { handle in
            guard let frame = handle.frame else { return false }
            return frame.contains(point)
        }
    }

    /// Returns windows with frames matching the target frame within tolerance.
    ///
    /// - Parameters:
    ///   - targetFrame: The frame to match
    ///   - tolerance: Maximum difference in pixels (default: 10)
    /// - Returns: Filtered array of windows matching the frame
    public func matchingFrame(_ targetFrame: CGRect, tolerance: CGFloat = 10) -> [WindowHandle] {
        return filter { handle in
            guard let frame = handle.frame else { return false }
            return abs(frame.origin.x - targetFrame.origin.x) <= tolerance &&
                   abs(frame.origin.y - targetFrame.origin.y) <= tolerance &&
                   abs(frame.width - targetFrame.width) <= tolerance &&
                   abs(frame.height - targetFrame.height) <= tolerance
        }
    }

    // MARK: - Process Filtering

    /// Returns windows belonging to the specified process ID.
    ///
    /// - Parameter processID: The process ID to filter by
    /// - Returns: Filtered array of windows for that process
    public func forProcess(_ processID: pid_t) -> [WindowHandle] {
        return filter { $0.processID == processID }
    }

    /// Returns windows belonging to the specified bundle ID.
    ///
    /// - Parameter bundleID: The bundle identifier to filter by
    /// - Returns: Filtered array of windows for that bundle
    public func forBundle(_ bundleID: String) -> [WindowHandle] {
        return filter { $0.bundleIdentifier == bundleID }
    }

    // MARK: - Sorting

    /// Returns windows sorted by their z-order (frontmost first).
    ///
    /// Note: Z-order is determined by querying CGWindowList, which may
    /// have a small performance cost.
    ///
    /// - Returns: Array sorted by z-order (frontmost first)
    public func sortedByZOrder() -> [WindowHandle] {
        // Get CGWindowList z-order
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return self
        }

        // Build frame → z-order index mapping
        var frameToZOrder: [String: Int] = [:]
        for (index, cgWindow) in windowList.enumerated() {
            guard let boundsDict = cgWindow[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"] else {
                continue
            }
            let key = "\(Int(x)),\(Int(y)),\(Int(width)),\(Int(height))"
            frameToZOrder[key] = index
        }

        return sorted { handle1, handle2 in
            guard let frame1 = handle1.frame, let frame2 = handle2.frame else {
                return false
            }
            let key1 = "\(Int(frame1.origin.x)),\(Int(frame1.origin.y)),\(Int(frame1.width)),\(Int(frame1.height))"
            let key2 = "\(Int(frame2.origin.x)),\(Int(frame2.origin.y)),\(Int(frame2.width)),\(Int(frame2.height))"
            let z1 = frameToZOrder[key1] ?? Int.max
            let z2 = frameToZOrder[key2] ?? Int.max
            return z1 < z2
        }
    }

    /// Returns windows sorted by frame position (left-to-right, top-to-bottom).
    ///
    /// - Returns: Array sorted by position
    public func sortedByPosition() -> [WindowHandle] {
        return sorted { handle1, handle2 in
            guard let frame1 = handle1.frame, let frame2 = handle2.frame else {
                return false
            }
            // Primary sort by Y (top to bottom), secondary by X (left to right)
            if abs(frame1.origin.y - frame2.origin.y) < 50 {
                return frame1.origin.x < frame2.origin.x
            }
            return frame1.origin.y < frame2.origin.y
        }
    }

    /// Returns windows sorted by title alphabetically.
    ///
    /// - Returns: Array sorted by title
    public func sortedByTitle() -> [WindowHandle] {
        return sorted { handle1, handle2 in
            let title1 = handle1.title ?? ""
            let title2 = handle2.title ?? ""
            return title1.localizedCaseInsensitiveCompare(title2) == .orderedAscending
        }
    }

    // MARK: - Convenience Accessors

    /// Returns the second element if it exists.
    public var second: WindowHandle? {
        return indices.contains(1) ? self[1] : nil
    }

    /// Returns the third element if it exists.
    public var third: WindowHandle? {
        return indices.contains(2) ? self[2] : nil
    }

    /// Returns element at index if it exists.
    ///
    /// - Parameter index: The index to access
    /// - Returns: WindowHandle at index, or nil if out of bounds
    public func at(_ index: Int) -> WindowHandle? {
        return indices.contains(index) ? self[index] : nil
    }
}
