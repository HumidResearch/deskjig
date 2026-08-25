//
//  BlockAssemblySplashView.swift
//  DeskJig
//
//  Created by Claude Code on 08/25/26.
//

import SwiftUI
import DeskJigShared

/// The launch splash: 31 rounded tiles fly in from off-canvas and assemble into
/// the "deskjig" wordmark, then the finished mark cures with a highlight sweep and
/// a single settle pulse.
///
/// This is a native reinterpretation of the pre-rendered motion piece the app used
/// to ship (`LottieSplashView`, an `AVPlayer` playing a baked 4.3s MP4). Everything
/// here is drawn in code:
///
/// - **No assets.** Letterforms live in ``SplashWordmark`` as grid-cell rectangles,
///   so the mark is resolution independent, theme aware, and rebrandable by editing
///   Swift rather than re-exporting video.
/// - **Springs, not keyframes, for the flight.** Each tile owns a delayed
///   `.spring(response:dampingFraction:)` on a single shared `assembled` flag. That
///   is what gives the assembly its overshoot-and-catch feel, and it means the
///   whole timeline is one boolean rather than 31 hand-placed keyframe tracks.
/// - **`keyframeAnimator` for the punctuation.** The post-assembly "thunk" is a
///   one-shot keyframe track on the mark as a whole — the one moment that genuinely
///   wants authored timing instead of physics.
/// - **Half the runtime.** ~2.5s on screen versus ~4.9s for the video.
///
/// Honours `accessibilityReduceMotion` by dropping the flight and sweep entirely in
/// favour of a staged fade, and can be dismissed early by clicking.
struct BlockAssemblySplashView: View {

    /// Presentation width of the wordmark in points. The tile grid scales from this.
    var markWidth: CGFloat = 520

    /// Invoked when the splash has finished (or was skipped by a click).
    /// Called inside a `withAnimation`, matching the previous splash's contract so a
    /// caller's `.transition(.opacity)` fades it out.
    let onComplete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var assembled = false
    @State private var sweeping = false
    @State private var settlePulse = 0
    @State private var didComplete = false

    private var cell: CGFloat { markWidth / SplashWordmark.gridWidth }
    private var markSize: CGSize {
        CGSize(width: markWidth, height: SplashWordmark.gridHeight * cell)
    }

    var body: some View {
        ZStack {
            backdrop
            mark
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement()
        .accessibilityLabel("DeskJig")
        .task { await runTimeline() }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            DesignTokens.Surface.window
            RadialGradient(
                colors: [DesignTokens.Brand.accent, .clear],
                center: .center,
                startRadius: 0,
                endRadius: markWidth * 0.85
            )
            .opacity(assembled ? 0.10 : 0)
            .animation(.easeOut(duration: 1.1), value: assembled)
        }
        .ignoresSafeArea()
    }

    // MARK: - Wordmark

    private var mark: some View {
        blockField()
            .frame(width: markSize.width, height: markSize.height)
            .overlay { sweepOverlay }
            .shadow(
                color: DesignTokens.Brand.accent.opacity(sweeping ? 0.20 : 0),
                radius: sweeping ? 32 : 0,
                y: 0
            )
            .animation(.easeOut(duration: 0.7), value: sweeping)
            .keyframeAnimator(initialValue: 1.0, trigger: settlePulse) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                // The one authored beat in the piece: a crisp compress-and-release
                // as the last tile locks in, so the assembly reads as *finished*.
                SpringKeyframe(1.030, duration: 0.16, spring: .snappy)
                SpringKeyframe(1.000, duration: 0.46, spring: .bouncy)
            }
    }

    private func blockField(uniformFill: Color? = nil) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(SplashWordmark.blocks) { block in
                SplashTileView(
                    block: block,
                    cell: cell,
                    assembled: assembled,
                    reduceMotion: reduceMotion,
                    fill: uniformFill ?? block.tint.color
                )
            }
        }
        .frame(width: markSize.width, height: markSize.height, alignment: .topLeading)
    }

    /// A soft highlight that wipes left-to-right across the assembled tiles, masked
    /// to the mark itself. Reads as the blocks fusing into a single object.
    @ViewBuilder
    private var sweepOverlay: some View {
        if !reduceMotion {
            Color.clear
                .frame(width: markSize.width, height: markSize.height)
                .overlay(alignment: .leading) {
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.65), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: markSize.width * 0.40)
                    .offset(x: sweeping ? markSize.width : -markSize.width * 0.40)
                    .animation(.easeInOut(duration: SplashTiming.sweep), value: sweeping)
                }
                .mask { blockField(uniformFill: .white) }
                .allowsHitTesting(false)
        }
    }

    // MARK: - Timeline

    private func runTimeline() async {
        guard !reduceMotion else {
            assembled = true
            _ = await Task.sleepUnlessCancelled(
                for: .seconds(SplashTiming.reducedFade) + SplashTiming.reducedHold
            )
            finish()
            return
        }

        guard await Task.sleepUnlessCancelled(for: SplashTiming.leadIn) else { return }
        assembled = true

        guard await Task.sleepUnlessCancelled(for: SplashTiming.assemblyComplete) else { return }
        sweeping = true
        settlePulse += 1

        guard await Task.sleepUnlessCancelled(for: SplashTiming.settle + SplashTiming.hold) else { return }
        finish()
    }

    private func finish() {
        guard !didComplete else { return }
        didComplete = true
        withAnimation(.easeOut(duration: SplashTiming.dismiss)) {
            onComplete()
        }
    }
}

// MARK: - Tile

/// One tile of the wordmark.
///
/// Each tile applies its own delayed animations to the shared `assembled` flag —
/// a fast ease-out for the fade so it materialises mid-flight, and a slower spring
/// for travel and scale so it arrives with a touch of overshoot.
private struct SplashTileView: View {
    let block: SplashBlock
    let cell: CGFloat
    let assembled: Bool
    let reduceMotion: Bool
    let fill: Color

    private var inset: CGFloat { cell * 0.085 }
    private var delay: Double { reduceMotion ? block.beat * 0.4 : block.beat }

    private var travel: CGSize {
        guard !reduceMotion, !assembled else { return .zero }
        return CGSize(width: block.entry.width * cell, height: block.entry.height * cell)
    }

    private var motion: Animation {
        reduceMotion
            ? .easeOut(duration: SplashTiming.reducedFade).delay(delay)
            : .spring(
                response: SplashTiming.flightResponse,
                dampingFraction: SplashTiming.flightDamping
              ).delay(delay)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: cell * 0.30, style: .continuous)
            .fill(fill)
            .frame(
                width: max(block.rect.width * cell - inset * 2, 1),
                height: max(block.rect.height * cell - inset * 2, 1)
            )
            .opacity(assembled ? 1 : 0)
            .animation(.easeOut(duration: SplashTiming.materialize).delay(delay), value: assembled)
            .scaleEffect(assembled || reduceMotion ? 1 : 0.78)
            .offset(
                x: block.rect.minX * cell + inset + travel.width,
                y: block.rect.minY * cell + inset + travel.height
            )
            .animation(motion, value: assembled)
    }
}

// MARK: - Previews

#if DEBUG

/// Replayable harness so the timeline can be scrubbed by eye in the canvas.
private struct SplashPreviewHost: View {
    @State private var runID = UUID()
    @State private var finished = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)

            if !finished {
                BlockAssemblySplashView { finished = true }
                    .id(runID)
                    .transition(.opacity)
            } else {
                Text("onComplete() fired")
                    .font(brand: .body2)
                    .foregroundStyle(DesignTokens.Text.secondary)
            }
        }
        .frame(width: 1200, height: 800)
        .overlay(alignment: .bottom) {
            Button("Replay") {
                finished = false
                runID = UUID()
            }
            .padding(.bottom, 32)
        }
    }
}

#Preview("Assembly — dark") {
    SplashPreviewHost()
        .preferredColorScheme(.dark)
}

#Preview("Assembly — light") {
    SplashPreviewHost()
        .preferredColorScheme(.light)
}

#Preview("Wordmark — letterforms") {
    // Fully assembled, no motion: the view for judging tile geometry and palette.
    let cell: CGFloat = 640 / SplashWordmark.gridWidth
    ZStack(alignment: .topLeading) {
        ForEach(SplashWordmark.blocks) { block in
            SplashTileView(
                block: block,
                cell: cell,
                assembled: true,
                reduceMotion: true,
                fill: block.tint.color
            )
        }
    }
    .frame(width: 640, height: SplashWordmark.gridHeight * cell, alignment: .topLeading)
    .padding(64)
    .background(DesignTokens.Surface.window)
    .preferredColorScheme(.dark)
}

#endif
