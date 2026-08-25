//
//  SplashMotion.swift
//  DeskJig
//
//  A native port of the original After Effects splash comp that shipped as
//  `deskjig-motion.mp4`. The video was authored as hand-keyframed AE layers
//  (see `DeskJigAnimation.dataset/DeskJigAnimation-fixed.json`) and then baked;
//  this file rebuilds the same model in code — a fixed 29.97 fps timeline,
//  irregular hand-tuned beats, and AE's default "Easy Ease" bezier on every
//  segment — so the motion feel survives without shipping a video.
//
//  Nothing here draws: this is the choreography layer only.
//

import SwiftUI

// MARK: - Easing

/// A 2D cubic bezier timing curve solved on `x` to yield `y`, i.e. the same
/// evaluation model Core Animation and After Effects use for keyframe tangents.
struct UnitBezier {
    private let ax: Double, bx: Double, cx: Double
    private let ay: Double, by: Double, cy: Double

    init(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double) {
        cx = 3 * p1x
        bx = 3 * (p2x - p1x) - cx
        ax = 1 - cx - bx
        cy = 3 * p1y
        by = 3 * (p2y - p1y) - cy
        ay = 1 - cy - by
    }

    private func sampleX(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func sampleY(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func slopeX(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    /// Eased progress for a linear `progress` in 0...1.
    func value(at progress: Double) -> Double {
        let x = min(max(progress, 0), 1)
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }

        // Newton-Raphson first — converges in 2-3 steps for well-behaved curves.
        var t = x
        for _ in 0..<8 {
            let error = sampleX(t) - x
            if abs(error) < 1e-6 { return sampleY(t) }
            let slope = slopeX(t)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }

        // Bisection fallback for the flat-slope case.
        var low = 0.0
        var high = 1.0
        t = x
        for _ in 0..<24 {
            let sampled = sampleX(t)
            if abs(sampled - x) < 1e-6 { break }
            if x > sampled { low = t } else { high = t }
            t = low + (high - low) / 2
        }
        return sampleY(t)
    }
}

enum SplashEasing {
    /// After Effects' default "Easy Ease": every keyframe in the original comp
    /// carried `o: {x: 0.333, y: 0}` / `i: {x: 0.667, y: 1}` tangents — a plain
    /// symmetric ease-in-out with no overshoot and no spring. Reusing exactly
    /// this curve on every segment is the single biggest reason the port reads
    /// as the same animation.
    static let easyEase = UnitBezier(0.333, 0, 0.667, 1)
}

// MARK: - Timeline

enum SplashClock {
    /// NTSC 29.97 fps — the comp's frame rate, and the video's (30000/1001).
    static let framesPerSecond: Double = 30_000.0 / 1_001.0

    /// The comp is 128 frames long, matching the 4.3043 s baked video.
    static let totalFrames: Double = 128

    static var duration: TimeInterval { totalFrames / framesPerSecond }

    static func frame(elapsed: TimeInterval) -> Double {
        min(max(elapsed, 0) * framesPerSecond, totalFrames)
    }
}

// MARK: - Block entry paths

/// How a block travels from off-canvas into its resting slot.
///
/// The original tiles never faded and never moved diagonally — they slid along
/// one axis, held, then slid along the other (see the null layer's L-shaped
/// 9-keyframe path). Each case encodes that same two-leg L: an approach leg on
/// one axis to a staging point, a hold, then a docking leg on the other axis.
enum SplashEntry {
    /// Enters from above, offset sideways by `lateral` units, then slides in.
    case top(lateral: CGFloat)
    /// Enters from below, offset sideways by `lateral` units, then slides in.
    case bottom(lateral: CGFloat)
    /// Enters from the left, offset vertically by `lift` units, then drops in.
    case leading(lift: CGFloat)
    /// Enters from the right, offset vertically by `lift` units, then drops in.
    case trailing(lift: CGFloat)
}

/// Per-block segment lengths, in frames. Derived from the spacing of the
/// original's keyframe pairs (moves of ~12-17 frames separated by short holds).
enum SplashSegments {
    static let approach: Double = 12
    static let hold: Double = 4
    static let dock: Double = 10
    static var total: Double { approach + hold + dock }
}

// MARK: - Block

/// One tile of the wordmark: a rounded rectangle in wordmark-unit space plus the
/// beat it enters on and the path it takes.
struct SplashBlock: Identifiable {
    let id: Int
    /// Resting rect in wordmark units (y grows downward, origin = word's top-left box corner).
    let rect: CGRect
    let tone: SplashTone
    /// Frame this block starts moving on. Hand-tuned, deliberately irregular.
    let startFrame: Double
    let entry: SplashEntry

    /// Resting rect converted to canvas points.
    func restingFrame(origin: CGPoint, unit: CGFloat) -> CGRect {
        CGRect(
            x: origin.x + rect.minX * unit,
            y: origin.y + rect.minY * unit,
            width: rect.width * unit,
            height: rect.height * unit
        )
    }

    /// Animated rect at `frame`, following the two-leg L-path.
    func frame(at frame: Double, origin: CGPoint, unit: CGFloat, canvas: CGSize) -> CGRect {
        let resting = restingFrame(origin: origin, unit: unit)
        let local = frame - startFrame
        if local >= SplashSegments.total { return resting }

        let (offscreen, staging) = waypoints(resting: resting, unit: unit, canvas: canvas)
        if local <= 0 { return resting.offsetBy(offscreen) }

        let from: CGSize
        let to: CGSize
        let progress: Double

        if local < SplashSegments.approach {
            from = offscreen
            to = staging
            progress = local / SplashSegments.approach
        } else if local < SplashSegments.approach + SplashSegments.hold {
            return resting.offsetBy(staging)
        } else {
            from = staging
            to = .zero
            progress = (local - SplashSegments.approach - SplashSegments.hold) / SplashSegments.dock
        }

        let eased = CGFloat(SplashEasing.easyEase.value(at: progress))
        return resting.offsetBy(
            CGSize(
                width: from.width + (to.width - from.width) * eased,
                height: from.height + (to.height - from.height) * eased
            )
        )
    }

    /// Offsets (relative to the resting rect) for the off-canvas start and the
    /// mid-path staging point.
    private func waypoints(resting: CGRect, unit: CGFloat, canvas: CGSize) -> (offscreen: CGSize, staging: CGSize) {
        // A little past the edge so a block is fully clear of the canvas before it starts.
        let clearance = unit * 1.5

        switch entry {
        case .top(let lateral):
            let staging = CGSize(width: lateral * unit, height: 0)
            let dy = -(resting.maxY + clearance)
            return (CGSize(width: staging.width, height: dy), staging)
        case .bottom(let lateral):
            let staging = CGSize(width: lateral * unit, height: 0)
            let dy = canvas.height - resting.minY + clearance
            return (CGSize(width: staging.width, height: dy), staging)
        case .leading(let lift):
            let staging = CGSize(width: 0, height: lift * unit)
            let dx = -(resting.maxX + clearance)
            return (CGSize(width: dx, height: staging.height), staging)
        case .trailing(let lift):
            let staging = CGSize(width: 0, height: lift * unit)
            let dx = canvas.width - resting.minX + clearance
            return (CGSize(width: dx, height: staging.height), staging)
        }
    }
}

private extension CGRect {
    func offsetBy(_ size: CGSize) -> CGRect {
        offsetBy(dx: size.width, dy: size.height)
    }
}

// MARK: - Group settle

enum SplashGroupSettle {
    /// The original parented its whole logo group to a "Null Collect" layer and
    /// nudged it on the last beats. Same idea: a barely-there group settle that
    /// lands on the final frame so the assembled word "clicks" into place.
    static let startFrame: Double = 104
    static let endFrame: Double = SplashClock.totalFrames

    static func transform(at frame: Double) -> (scale: CGFloat, dy: CGFloat) {
        let progress = (frame - startFrame) / (endFrame - startFrame)
        let eased = SplashEasing.easyEase.value(at: progress)
        return (scale: 0.986 + 0.014 * CGFloat(eased), dy: 3.0 * (1 - CGFloat(eased)))
    }
}
