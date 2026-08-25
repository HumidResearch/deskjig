//
//  BlockAssemblySplashView.swift
//  DeskJig
//
//  Native replacement for the baked-video splash (`LottieSplashView`).
//  Same contract: fills the window, plays once, calls `onComplete` when it is
//  ready to be dismissed. Same presentation box (600 x 337.5 pt), same tail
//  (0.3 s hold, then a 0.3 s ease-out fade owned by the caller's transition),
//  same total on-screen time of roughly 4.9 s.
//
//  Unlike the video it is drawn entirely in code, so it inherits the app's
//  theme, stays sharp at any size, and carries no asset.
//

import SwiftUI
import DeskJigShared

struct BlockAssemblySplashView: View {
    let onComplete: () -> Void

    /// The original video was presented in a fixed 600 x 337.5 pt box (16:9).
    /// Keeping it means the tiles enter from the same relative distances.
    static let canvasSize = CGSize(width: 600, height: 337.5)

    /// Beat of stillness on the finished wordmark before handing control back —
    /// the video player waited the same 0.3 s after `didPlayToEndTime`.
    private static let holdAfterAssembly: Duration = .milliseconds(300)
    /// Reduced-motion runs show the assembled wordmark and get out of the way.
    private static let reducedMotionDwell: Duration = .milliseconds(1200)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var startedAt = Date()
    @State private var isFinished = false
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            DesignTokens.Surface.window
                .ignoresSafeArea()

            canvas
                .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
                .clipped()
                .opacity(reduceMotion && !hasAppeared ? 0 : 1)
        }
        .task {
            startedAt = .now
            if reduceMotion {
                withAnimation(.easeOut(duration: 0.35)) { hasAppeared = true }
                guard await Task.sleepUnlessCancelled(for: Self.reducedMotionDwell) else { return }
            } else {
                let runtime = Duration.milliseconds(Int(SplashClock.duration * 1000))
                guard await Task.sleepUnlessCancelled(for: runtime + Self.holdAfterAssembly) else { return }
            }
            isFinished = true
            withAnimation(.easeOut(duration: 0.3)) {
                onComplete()
            }
        }
    }

    @ViewBuilder
    private var canvas: some View {
        if reduceMotion {
            // No travel, no timeline: just the resolved wordmark.
            SplashBlockCanvas(frame: SplashClock.totalFrames)
        } else {
            TimelineView(.animation(paused: isFinished)) { context in
                SplashBlockCanvas(
                    frame: SplashClock.frame(elapsed: context.date.timeIntervalSince(startedAt))
                )
            }
        }
    }
}

/// Pure renderer: draws the wordmark's tiles at an arbitrary comp frame.
/// Stateless, so it can be scrubbed frame by frame in a preview.
struct SplashBlockCanvas: View {
    let frame: Double

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let layout = SplashLayout.fit(in: size)
            let settle = SplashGroupSettle.transform(at: frame)

            // Group transform, mirroring the original's null-object parent.
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: settle.scale, y: settle.scale)
            context.translateBy(x: -size.width / 2, y: -size.height / 2 + settle.dy)

            for block in SplashWordmark.blocks {
                let rect = block.frame(
                    at: frame,
                    origin: layout.origin,
                    unit: layout.unit,
                    canvas: size
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: layout.cornerRadius(for: rect)),
                    with: .color(block.tone.color)
                )
            }
        }
    }
}

// MARK: - Previews

#Preview("Splash — playback") {
    SplashPreviewHost()
        .frame(width: 1200, height: 800)
}

#Preview("Splash — frame scrubber") {
    SplashScrubberHost()
        .frame(width: 900, height: 520)
}

/// Replays the splash on demand; debug builds skip it at launch, so this is the
/// normal way to look at it.
private struct SplashPreviewHost: View {
    @State private var runID = 0
    @State private var isShowing = true

    var body: some View {
        ZStack {
            Color.gray.opacity(0.2)
            Text("app content")
                .font(brand: .h2)
                .foregroundStyle(DesignTokens.Text.secondary)

            if isShowing {
                BlockAssemblySplashView { isShowing = false }
                    .id(runID)
                    .transition(.opacity)
            }

            VStack {
                Spacer()
                Button("Replay") {
                    runID += 1
                    isShowing = true
                }
                .padding(.bottom, DesignTokens.Spacing.gapLarge)
            }
        }
    }
}

/// Scrubs the comp frame by frame — the fastest way to check a beat or an
/// easing tweak without waiting out the run.
private struct SplashScrubberHost: View {
    @State private var frame: Double = 0

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.gapMedium) {
            SplashBlockCanvas(frame: frame)
                .frame(
                    width: BlockAssemblySplashView.canvasSize.width,
                    height: BlockAssemblySplashView.canvasSize.height
                )
                .clipped()
                .background(DesignTokens.Surface.window)

            HStack(spacing: DesignTokens.Spacing.gapRegular) {
                Text("f \(Int(frame))")
                    .font(brand: .monoBody4)
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .frame(width: 48, alignment: .leading)
                Slider(value: $frame, in: 0...SplashClock.totalFrames)
            }
            .padding(.horizontal, DesignTokens.Spacing.contentPaddingRegular)
        }
        .padding(DesignTokens.Spacing.contentPaddingRegular)
    }
}
