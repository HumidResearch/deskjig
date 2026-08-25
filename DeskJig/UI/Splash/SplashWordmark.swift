//
//  SplashWordmark.swift
//  DeskJig
//
//  Created by Claude Code on 08/25/26.
//

import CoreGraphics
import SwiftUI
import DeskJigShared

// MARK: - Tint roles

/// Tint roles for splash blocks, resolved against the shared design-system palette.
///
/// The wordmark is overwhelmingly neutral; exactly five blocks carry brand colour,
/// a deliberate callback to the five coloured tiles in the original bento motion piece.
enum SplashBlockTint {
    case neutral
    case accent
    case amber
    case verdant

    var color: Color {
        switch self {
        case .neutral: DesignTokens.Text.primary
        case .accent: DesignTokens.Brand.accent
        case .amber: DesignTokens.Brand.amber
        case .verdant: DesignTokens.Brand.communityGreen
        }
    }
}

// MARK: - Block model

/// One rounded tile of the assembled wordmark.
///
/// All geometry is expressed in *grid cells*, not points, so the mark scales cleanly
/// to any presentation width — the view multiplies by a single `cell` dimension.
struct SplashBlock: Identifiable, Equatable {
    /// Stable identity, also the global assembly index.
    let id: Int
    /// Position and size in grid cells, origin top-left of the wordmark band.
    let rect: CGRect
    /// Palette role for this tile.
    let tint: SplashBlockTint
    /// Delay, in seconds, before this tile begins its flight in.
    let beat: Double
    /// Off-canvas launch offset in grid cells. Always orthogonal — the original
    /// After Effects comp only ever moved tiles on one axis at a time.
    let entry: CGSize
}

// MARK: - Wordmark geometry

/// The block letterforms for "deskjig", authored as a coarse tile grid.
///
/// ## Grid
/// The band is `gridHeight` rows tall, laid out as a real typographic baseline grid:
///
/// ```
/// rows 0...2   ascender zone   (d, k)
/// rows 3...7   x-height        (all letters)
/// rows 8...9   descender zone  (j, g)
/// ```
///
/// Every glyph is described as a handful of chunky rectangles rather than a
/// per-pixel bitmap. That is what makes it read as *blocks assembling* instead of
/// pixel art: 31 tiles total, 2–6 per letter, each one large enough to be legible
/// in flight.
///
/// ## Ordering
/// Array order **is** animation order. Letters resolve left to right (so the word
/// reads as it is written), and within a letter the parts are authored in the order
/// they should land. Hand-tuned beats, exactly like the source comp — no procedural
/// stagger, no randomness, fully deterministic across launches.
enum SplashWordmark {

    /// Total width of the mark in grid cells.
    static let gridWidth: CGFloat = 36
    /// Total height of the mark in grid cells.
    static let gridHeight: CGFloat = 10

    /// Horizontal gap between letters, in grid cells.
    private static let letterSpacing: CGFloat = 1

    /// A single letterform: its horizontal advance plus its constituent tiles.
    private struct Glyph {
        let advance: CGFloat
        let parts: [GlyphPart]
    }

    /// One tile of a letterform, in grid cells relative to the glyph's own origin.
    private struct GlyphPart {
        let rect: CGRect
        let tint: SplashBlockTint

        init(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ tint: SplashBlockTint = .neutral) {
            self.rect = CGRect(x: x, y: y, width: width, height: height)
            self.tint = tint
        }
    }

    // MARK: Letterforms

    /// `d` — bowl plus a full-height ascender stem on the right.
    private static let d = Glyph(advance: 5, parts: [
        .init(1, 3, 3, 1),           // bowl top
        .init(4, 0, 1, 8, .accent),  // ascender stem
        .init(0, 4, 1, 3),           // bowl left
        .init(1, 7, 3, 1)            // bowl bottom
    ])

    /// `e` — the crossbar lands last and carries the amber tint.
    private static let e = Glyph(advance: 5, parts: [
        .init(1, 3, 3, 1),           // top arc
        .init(0, 4, 1, 3),           // left side
        .init(4, 4, 1, 1),           // right shoulder
        .init(1, 7, 3, 1),           // bottom
        .init(1, 5, 4, 1, .amber)    // crossbar
    ])

    /// `s` — the stepped corners are intentional; they read as stacked tiles.
    private static let s = Glyph(advance: 5, parts: [
        .init(1, 3, 4, 1),           // top bar
        .init(0, 7, 4, 1),           // bottom bar
        .init(0, 4, 1, 1),           // upper left step
        .init(4, 6, 1, 1),           // lower right step
        .init(1, 5, 3, 1)            // waist
    ])

    /// `k` — stem first, then the two arms stair-step outward.
    private static let k = Glyph(advance: 5, parts: [
        .init(0, 0, 1, 8),           // stem
        .init(1, 5, 1, 1),           // junction
        .init(2, 4, 1, 1),           // upper arm step
        .init(3, 3, 2, 1),           // upper arm tip
        .init(2, 6, 1, 1),           // lower leg step
        .init(3, 7, 2, 1)            // lower leg tip
    ])

    /// `j` — tittle, stem, and a hook that curls into the descender zone.
    private static let j = Glyph(advance: 3, parts: [
        .init(1, 3, 1, 6),           // stem
        .init(0, 9, 2, 1),           // hook
        .init(1, 1, 1, 1, .accent)   // tittle
    ])

    /// `i` — the narrowest glyph; its tittle is the amber punctuation of the mark.
    private static let i = Glyph(advance: 2, parts: [
        .init(0, 3, 1, 5),           // stem
        .init(0, 1, 1, 1, .amber)    // tittle
    ])

    /// `g` — closed bowl plus a descending tail that sweeps back to the left.
    private static let g = Glyph(advance: 5, parts: [
        .init(1, 3, 3, 1),           // bowl top
        .init(0, 4, 1, 3),           // bowl left
        .init(4, 4, 1, 3),           // bowl right
        .init(1, 7, 3, 1),           // bowl bottom
        .init(4, 7, 1, 2),           // descender stem
        .init(0, 9, 4, 1, .verdant)  // tail
    ])

    private static let word: [Glyph] = [d, e, s, k, j, i, g]

    // MARK: Assembly

    /// Every tile of the wordmark, in the order it lands.
    static let blocks: [SplashBlock] = buildBlocks()

    /// Delay of the last tile to begin its flight, in seconds.
    static let lastBeat: Double = blocks.map(\.beat).max() ?? 0

    private static func buildBlocks() -> [SplashBlock] {
        var result: [SplashBlock] = []
        var originX: CGFloat = 0

        for (letterIndex, glyph) in word.enumerated() {
            for (partIndex, part) in glyph.parts.enumerated() {
                let rect = part.rect.offsetBy(dx: originX, dy: 0)
                let index = result.count
                result.append(
                    SplashBlock(
                        id: index,
                        rect: rect,
                        tint: part.tint,
                        beat: Double(letterIndex) * SplashTiming.letterBeat
                            + Double(partIndex) * SplashTiming.partBeat,
                        entry: entryOffset(for: rect, index: index)
                    )
                )
            }
            originX += glyph.advance + letterSpacing
        }

        return result
    }

    /// Where a tile starts its life, in grid cells.
    ///
    /// Tiles always travel on a single axis and always converge *inward* — a tile in
    /// the top half drops from above, one on the left slides in from the left. Every
    /// third tile is horizontal, which breaks up what would otherwise be a uniform
    /// curtain of falling squares.
    private static func entryOffset(for rect: CGRect, index: Int) -> CGSize {
        if index.isMultiple(of: 3) {
            let dx: CGFloat = rect.midX < gridWidth / 2 ? -18 : 18
            return CGSize(width: dx, height: 0)
        }
        let dy: CGFloat = rect.midY < gridHeight / 2 ? -11 : 11
        return CGSize(width: 0, height: dy)
    }
}

// MARK: - Timing

/// Every tunable in the splash timeline, in one place.
///
/// Total on-screen time is roughly `assemblyComplete + settle + hold` ≈ 2.5s,
/// plus the caller's dismissal fade — about half the length of the video splash
/// it replaces.
enum SplashTiming {
    /// A beat of dead air so the backdrop establishes before the first tile moves.
    static let leadIn: Duration = .milliseconds(70)
    /// Delay added per letter, left to right.
    static let letterBeat: Double = 0.105
    /// Delay added per tile within a letter.
    static let partBeat: Double = 0.035

    /// Spring response for a tile's flight. Slow enough to see the travel,
    /// fast enough that 31 staggered tiles still finish inside a second and a half.
    static let flightResponse: Double = 0.60
    /// Just under critical damping: a few percent of overshoot, no visible wobble.
    static let flightDamping: Double = 0.74
    /// Tiles fade in faster than they travel, so they materialise mid-flight.
    static let materialize: Double = 0.30

    /// When the last tile has visually come to rest.
    static var assemblyComplete: Duration {
        .seconds(SplashWordmark.lastBeat + flightResponse * 1.25)
    }

    /// The post-assembly "cure": highlight sweep plus a single unified scale pulse.
    static let sweep: Double = 0.58
    static let settle: Duration = .milliseconds(620)
    /// Beat to let the finished mark read before dismissal.
    static let hold: Duration = .milliseconds(300)
    /// Duration of the dismissal animation handed to `onComplete`.
    static let dismiss: Double = 0.34

    /// Reduced-motion variant: no flight, no sweep — a plain staged fade.
    static let reducedFade: Double = 0.45
    static let reducedHold: Duration = .milliseconds(900)
}
