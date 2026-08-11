//  CGWindowRecord.swift
//  DeskJigShared

import CoreGraphics
import Foundation

/// A parsed `CGWindowListCopyWindowInfo` entry.
///
/// Consolidates the duplicated `kCGWindowNumber` / `kCGWindowBounds` /
/// `kCGWindowOwnerPID` / `kCGWindowLayer` / `kCGWindowName` / `kCGWindowIsOnscreen`
/// dictionary parsing that was copy-pasted across the snapshot, window, z-order, and
/// restoration code (fluent-06) into one failable initializer.
///
/// - Note: `pid` is optional because some CGWindowList entries omit the owner PID;
///   call sites that require it should `guard let pid = record.pid`. This preserves
///   the prior behavior where the main snapshot loop skipped PID-less entries while
///   the z-order loop did not.
struct CGWindowRecord {
    let windowId: CGWindowID
    let pid: pid_t?
    let frame: CGRect
    let layer: Int
    let title: String?
    let isOnScreen: Bool

    init?(dict: [String: Any]) {
        guard let windowId = dict[kCGWindowNumber as String] as? CGWindowID,
              let boundsDict = dict[kCGWindowBounds as String] as? [String: CGFloat],
              let x = boundsDict["X"],
              let y = boundsDict["Y"],
              let width = boundsDict["Width"],
              let height = boundsDict["Height"] else {
            return nil
        }
        self.windowId = windowId
        self.pid = dict[kCGWindowOwnerPID as String] as? pid_t
        self.frame = CGRect(x: x, y: y, width: width, height: height)
        self.layer = dict[kCGWindowLayer as String] as? Int ?? 0
        self.title = dict[kCGWindowName as String] as? String
        self.isOnScreen = dict[kCGWindowIsOnscreen as String] as? Bool ?? false
    }
}
