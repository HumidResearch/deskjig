//  WindowLayoutFrameMatcher.swift
//  DeskJigShared

import Foundation
import AppKit
import CoreGraphics

enum WindowLayoutFrameMatcher {
    struct RelativeLayout: Equatable {
        let screenIndex: Int
        let xPercent: CGFloat
        let yPercent: CGFloat
        let widthPercent: CGFloat
        let heightPercent: CGFloat
    }

    private struct ScreenGeometry {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    @MainActor
    static func liveScreens() -> [FullScreenInfo] {
        WorkspaceDisplayTopology.sortScreens(NSScreen.screens.map(FullScreenInfo.init(screen:)))
    }

    static func matchesLayout(
        actualFrame: CGRect,
        targetFrame: CGRect,
        screens: [FullScreenInfo],
        coordinateTolerance: CGFloat = 0.03,
        sizeTolerance: CGFloat = 0.05,
        overshootTolerance: CGFloat = 0.08
    ) -> Bool {
        guard let actual = relativeLayout(for: actualFrame, in: screens, overshootTolerance: overshootTolerance),
              let target = relativeLayout(for: targetFrame, in: screens, overshootTolerance: overshootTolerance) else {
            return false
        }

        guard actual.screenIndex == target.screenIndex else {
            return false
        }

        return abs(actual.xPercent - target.xPercent) <= coordinateTolerance &&
            abs(actual.yPercent - target.yPercent) <= coordinateTolerance &&
            abs(actual.widthPercent - target.widthPercent) <= sizeTolerance &&
            abs(actual.heightPercent - target.heightPercent) <= sizeTolerance
    }

    static func relativeLayout(
        for frame: CGRect,
        in screens: [FullScreenInfo],
        overshootTolerance: CGFloat = 0.08
    ) -> RelativeLayout? {
        let orderedScreens = WorkspaceDisplayTopology.sortScreens(screens)
        guard !orderedScreens.isEmpty else { return nil }

        let geometries = screenGeometries(for: orderedScreens)
        guard let screenIndex = screenIndex(for: frame, geometries: geometries) else {
            return nil
        }

        let visibleFrame = geometries[screenIndex].visibleFrame
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return nil }

        let rawX = (frame.minX - visibleFrame.minX) / visibleFrame.width
        let rawY = (frame.minY - visibleFrame.minY) / visibleFrame.height
        let rawWidth = frame.width / visibleFrame.width
        let rawHeight = frame.height / visibleFrame.height

        return RelativeLayout(
            screenIndex: screenIndex,
            xPercent: normalizedCoordinate(rawX, overshootTolerance: overshootTolerance),
            yPercent: normalizedCoordinate(rawY, overshootTolerance: overshootTolerance),
            widthPercent: normalizedExtent(rawWidth, overshootTolerance: overshootTolerance),
            heightPercent: normalizedExtent(rawHeight, overshootTolerance: overshootTolerance)
        )
    }

    private static func screenGeometries(for screens: [FullScreenInfo]) -> [ScreenGeometry] {
        let globalMaxY = WorkspaceDisplayTopology.windowCoordinateAnchorY(from: screens)
        return screens.map { screen in
            ScreenGeometry(
                frame: CGRect(
                    x: screen.frame.minX,
                    y: globalMaxY - screen.frame.maxY,
                    width: screen.frame.width,
                    height: screen.frame.height
                ),
                visibleFrame: screen.visibleFrameInWindowCoordinates(globalMaxY: globalMaxY)
            )
        }
    }

    private static func screenIndex(
        for frame: CGRect,
        geometries: [ScreenGeometry]
    ) -> Int? {
        let centerPoint = CGPoint(x: frame.midX, y: frame.midY)
        if let directIndex = geometries.firstIndex(where: { $0.frame.contains(centerPoint) }) {
            return directIndex
        }

        return geometries.enumerated().min { lhs, rhs in
            let lhsDistance = distance(from: centerPoint, to: lhs.element.frame)
            let rhsDistance = distance(from: centerPoint, to: rhs.element.frame)
            return lhsDistance < rhsDistance
        }?.offset
    }

    private static func normalizedCoordinate(
        _ value: CGFloat,
        overshootTolerance: CGFloat
    ) -> CGFloat {
        if value < 0, abs(value) <= overshootTolerance {
            return 0
        }
        if value > 1, value - 1 <= overshootTolerance {
            return 1
        }
        return value
    }

    private static func normalizedExtent(
        _ value: CGFloat,
        overshootTolerance: CGFloat
    ) -> CGFloat {
        if value > 1, value - 1 <= overshootTolerance {
            return 1
        }
        return value
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx: CGFloat
        if point.x < rect.minX {
            dx = rect.minX - point.x
        } else if point.x > rect.maxX {
            dx = point.x - rect.maxX
        } else {
            dx = 0
        }

        let dy: CGFloat
        if point.y < rect.minY {
            dy = rect.minY - point.y
        } else if point.y > rect.maxY {
            dy = point.y - rect.maxY
        } else {
            dy = 0
        }

        return hypot(dx, dy)
    }
}

