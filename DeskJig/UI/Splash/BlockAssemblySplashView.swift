//
//  BlockAssemblySplashView.swift
//  DeskJig
//
//  Created by Claude Code on 08/25/26.
//

import SwiftUI
import DeskJigShared

/// The launch splash: tiles fly in from the edges of the window and snap into
/// the "deskjig" wordmark.
///
/// The whole animation is one idea — *window snapping* — told in four beats:
///
/// 1. **Ghost slots.** Every tile's destination appears first, drawn with the
///    app's own drag-target tokens (`DesignTokens.Drag`). The layout exists
///    before anything fills it, exactly like DeskJig's snap zones.
/// 2. **Orthogonal flights.** Tiles enter from the nearest window edge along a
///    single axis — never a diagonal — because windows slide, they don't drift.
///    They travel slightly enlarged and settle to 1.0, so each arrival reads as
///    a drop onto the desk rather than a fade-in.
/// 3. **The click.** Each tile lands on a lightly underdamped spring: one small
///    overshoot, no wobble. The two accent dots of `j` and `i` drop last,
///    straight down, on a bouncier spring — the punchline of the sequence.
/// 4. **The lock.** When the last dot lands, alignment guides shoot out from the
///    baseline and the right edge, the ghost slots retire, and the assembled
///    mark settles once by ~2%. The layout is confirmed, then it's gone.
///
/// Everything is drawn in code: no video, no Lottie, no bundled asset to go
/// stale, and nothing to fail at launch.
struct BlockAssemblySplashView: View {

    /// Size of one grid unit in points. The wordmark is 29 × 9 units, so the
    /// default renders at 638 × 198pt — roughly the footprint of the splash it
    /// replaces, inside the app's 1200 × 800 window.
    var unit: CGFloat = 22
    /// When `false` the view renders the finished mark immediately and never
    /// calls `onComplete` — useful for previews and design review.
    var autoPlay: Bool = true
    /// Called once the splash has finished and should be dismissed.
    var onComplete: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var slotsVisible = false
    @State private var assembled = false
    @State private var guidesVisible = false
    @State private var guidesExtended = false
    @State private var settle: CGFloat = 1
    @State private var didComplete = false

    private var boxWidth: CGFloat { SplashWordmark.gridWidth * unit }
    private var boxHeight: CGFloat { SplashWordmark.gridHeight * unit }

    var body: some View {
        ZStack {
            DesignTokens.Surface.window
                .ignoresSafeArea()

            wordmark
                .frame(width: boxWidth, height: boxHeight, alignment: .topLeading)
                .scaleEffect(settle)
        }
        .task {
            guard autoPlay else {
                slotsVisible = false
                assembled = true
                return
            }
            await runTimeline()
        }
        .accessibilityElement()
        .accessibilityLabel("DeskJig")
    }

    // MARK: - Wordmark

    private var wordmark: some View {
        ZStack(alignment: .topLeading) {
            ForEach(SplashWordmark.blocks) { block in
                slot(for: block)
            }
            guides
            ForEach(SplashWordmark.blocks) { block in
                tile(for: block)
            }
        }
    }

    /// The empty destination a tile snaps into.
    private func slot(for block: SplashWordmark.Block) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(DesignTokens.Drag.targetFill.opacity(0.70))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(DesignTokens.Drag.targetStroke.opacity(0.38), lineWidth: 1)
            }
            .frame(width: block.rect.width * unit - inset * 2,
                   height: block.rect.height * unit - inset * 2)
            .opacity(slotsVisible ? 1 : 0)
            .offset(x: block.rect.minX * unit + inset, y: block.rect.minY * unit + inset)
    }

    /// A landed (or in-flight) tile.
    private func tile(for block: SplashWordmark.Block) -> some View {
        let entry = entryOffset(for: block)
        return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(fill(for: block))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            }
            .frame(width: block.rect.width * unit - inset * 2,
                   height: block.rect.height * unit - inset * 2)
            .shadow(color: .black.opacity(0.30), radius: unit * 0.34, y: unit * 0.16)
            .opacity(assembled ? 1 : 0)
            .animation(fadeAnimation(for: block), value: assembled)
            .scaleEffect(assembled ? 1 : 1.08)
            .offset(
                x: block.rect.minX * unit + inset + (assembled ? 0 : entry.width),
                y: block.rect.minY * unit + inset + (assembled ? 0 : entry.height)
            )
            .animation(flightAnimation(for: block), value: assembled)
    }

    /// Alignment guides that flash once, confirming the layout locked.
    private var guides: some View {
        let anchorX = boxWidth
        let anchorY = SplashWordmark.baseline * unit
        let overhang = unit * 1.25
        let horizontalWidth = anchorX + overhang
        let verticalHeight = anchorY + overhang
        let color = DesignTokens.Brand.accent.opacity(0.65)

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(color)
                .frame(width: horizontalWidth, height: 1.5)
                .scaleEffect(x: guidesExtended ? 1 : 0, y: 1, anchor: .trailing)
                .offset(x: 0, y: anchorY - 0.75)

            Rectangle()
                .fill(color)
                .frame(width: 1.5, height: verticalHeight)
                .scaleEffect(x: 1, y: guidesExtended ? 1 : 0, anchor: .bottom)
                .offset(x: anchorX - 0.75, y: -overhang)
        }
        .opacity(guidesVisible ? 1 : 0)
        .allowsHitTesting(false)
    }

    // MARK: - Appearance

    /// Half the seam between neighbouring tiles. Deliberately hairline: wide
    /// enough to read as separate tiles up close, tight enough that adjacent
    /// tiles still read as one continuous stroke at a glance.
    private var inset: CGFloat { unit * 0.042 }
    private var cornerRadius: CGFloat { unit * 0.10 }

    private func fill(for block: SplashWordmark.Block) -> LinearGradient {
        switch block.role {
        case .structure:
            return LinearGradient(
                colors: [
                    DesignTokens.Text.primary,
                    DesignTokens.Text.primary.opacity(0.84)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .dot:
            return LinearGradient(
                colors: [
                    DesignTokens.Brand.accentLight,
                    DesignTokens.Brand.accent.opacity(0.86)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Motion

    /// Tiles enter from whichever window edge is nearest, on one axis only.
    /// Dots always drop straight down so the "dot the i" beat reads clearly.
    private func entryOffset(for block: SplashWordmark.Block) -> CGSize {
        let rect = block.rect
        let margin = unit * 2

        if block.role == .dot {
            return CGSize(width: 0, height: -(rect.maxY * unit + margin))
        }

        let normalizedX = rect.midX / SplashWordmark.gridWidth
        if normalizedX < 1.0 / 3.0 {
            return CGSize(width: -(rect.maxX * unit + margin), height: 0)
        }
        if normalizedX > 2.0 / 3.0 {
            return CGSize(width: (SplashWordmark.gridWidth - rect.minX) * unit + margin, height: 0)
        }
        let fromTop = rect.midY < SplashWordmark.gridHeight / 2
        return CGSize(
            width: 0,
            height: fromTop
                ? -(rect.maxY * unit + margin)
                : (SplashWordmark.gridHeight - rect.minY) * unit + margin
        )
    }

    private func flightAnimation(for block: SplashWordmark.Block) -> Animation {
        if reduceMotion {
            return .easeOut(duration: 0.45)
        }
        switch block.role {
        case .structure:
            return .spring(response: 0.42, dampingFraction: 0.74).delay(block.delay)
        case .dot:
            // Bouncier: the dot lands like a dropped key.
            return .spring(response: 0.36, dampingFraction: 0.58).delay(block.delay)
        }
    }

    private func fadeAnimation(for block: SplashWordmark.Block) -> Animation {
        if reduceMotion {
            return .easeOut(duration: 0.45)
        }
        return .easeOut(duration: 0.22).delay(block.delay)
    }

    // MARK: - Timeline

    private func runTimeline() async {
        guard !reduceMotion else {
            assembled = true
            guard await Task.sleepUnlessCancelled(for: .milliseconds(1_200)) else { return }
            finish()
            return
        }

        withAnimation(.easeOut(duration: 0.30)) {
            slotsVisible = true
        }
        guard await Task.sleepUnlessCancelled(for: .milliseconds(220)) else { return }

        // Per-block `.animation(_:value:)` modifiers own the staggering.
        assembled = true
        guard await Task.sleepUnlessCancelled(for: .seconds(SplashWordmark.lockBeat)) else { return }

        withAnimation(.easeOut(duration: 0.28)) {
            guidesVisible = true
            guidesExtended = true
        }
        withAnimation(.easeOut(duration: 0.35)) {
            slotsVisible = false
        }
        withAnimation(.easeOut(duration: 0.09)) {
            settle = 1.022
        }
        guard await Task.sleepUnlessCancelled(for: .milliseconds(90)) else { return }

        withAnimation(.spring(response: 0.50, dampingFraction: 0.55)) {
            settle = 1
        }
        guard await Task.sleepUnlessCancelled(for: .milliseconds(420)) else { return }

        withAnimation(.easeIn(duration: 0.40)) {
            guidesVisible = false
        }
        guard await Task.sleepUnlessCancelled(for: .milliseconds(460)) else { return }

        finish()
    }

    private func finish() {
        guard !didComplete else { return }
        didComplete = true
        withAnimation(.easeOut(duration: 0.35)) {
            onComplete()
        }
    }
}

// MARK: - Previews

#Preview("Block assembly splash") {
    SplashReplayHarness()
        .frame(width: 1_000, height: 640)
}

#Preview("Assembled wordmark") {
    BlockAssemblySplashView(autoPlay: false)
        .frame(width: 1_000, height: 640)
}

/// Preview-only wrapper with a replay button — the animation runs once per
/// identity, so replaying is a matter of handing the view a fresh one.
private struct SplashReplayHarness: View {
    @State private var runID = UUID()
    @State private var finished = false

    var body: some View {
        ZStack(alignment: .bottom) {
            BlockAssemblySplashView {
                finished = true
            }
            .id(runID)

            Button(finished ? "Replay (finished)" : "Replay") {
                finished = false
                runID = UUID()
            }
            .padding(.bottom, 28)
        }
    }
}
