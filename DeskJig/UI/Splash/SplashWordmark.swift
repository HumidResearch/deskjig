//
//  SplashWordmark.swift
//  DeskJig
//
//  The "deskjig" wordmark expressed as bento tiles: every letter is built from
//  a handful of axis-aligned rounded rectangles on a shared unit grid, which is
//  what lets the same blocks that spell the word also be the blocks that fly in.
//
//  Grid (units, y grows downward):
//
//      0.0   ascender top .......  d k  stems, i j dots sit above x-height
//      3.0   x-height top
//      9.0   baseline
//     12.0   descender bottom ....  j g tails
//
//  Stroke weight is 1.5 units, giving a chunky, tile-like letterform whose
//  counters stay open at splash size.
//

import SwiftUI
import DeskJigShared

/// Tile colour roles. The original comp's layers were literally named red /
/// blue / orange / green / yellow, but DeskJig's design system is deliberately
/// single-accent, so the five-way variety is recreated tonally from existing
/// tokens instead of reintroducing a rainbow.
enum SplashTone {
    case primary
    case secondary
    case accent
    case amber

    var color: Color {
        switch self {
        case .primary: DesignTokens.Text.primary
        case .secondary: DesignTokens.Text.secondary
        case .accent: DesignTokens.Brand.accent
        case .amber: DesignTokens.Brand.amber
        }
    }
}

enum SplashWordmark {
    /// Height of the full em box, ascender through descender.
    static let unitsTall: CGFloat = 12
    /// Space between letter advances.
    private static let tracking: CGFloat = 1.2

    // MARK: Glyphs

    private struct Glyph {
        let advance: CGFloat
        /// Optical correction applied to the gap *before* this glyph. Only `j`
        /// needs one: its ink hangs off to the right, which otherwise opens a
        /// word-space-sized hole after `k` and splits "desk jig".
        var kern: CGFloat = 0
        /// Rects in the glyph's own unit space.
        let parts: [CGRect]
        let tones: [SplashTone]
        let entries: [SplashEntry]
        /// Absolute comp frames each part starts on — hand-tuned, not a uniform stagger.
        let beats: [Double]
    }

    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// d — full-height stem on the right, square bowl on the left.
    private static let glyphD = Glyph(
        advance: 5,
        parts: [
            rect(3.5, 0, 1.5, 9),      // stem
            rect(0, 3, 1.5, 6),        // bowl left
            rect(1.5, 3, 2, 1.5),      // bowl top
            rect(1.5, 7.5, 2, 1.5)     // bowl bottom
        ],
        tones: [.primary, .primary, .accent, .primary],
        entries: [.top(lateral: -3), .bottom(lateral: 2.5), .top(lateral: 3), .bottom(lateral: -2.5)],
        beats: [10, 13, 17, 20]
    )

    /// e — left stem with three arms; the middle arm is the crossbar.
    private static let glyphE = Glyph(
        advance: 5,
        parts: [
            rect(0, 3, 1.5, 6),        // spine
            rect(1.5, 3, 3.5, 1.5),    // top arm
            rect(1.5, 5.25, 3.5, 1.5), // crossbar
            rect(1.5, 7.5, 3.5, 1.5)   // bottom arm
        ],
        tones: [.primary, .primary, .accent, .primary],
        entries: [.bottom(lateral: -3), .top(lateral: 2.5), .leading(lift: 2), .bottom(lateral: 3)],
        beats: [23, 26, 30, 33]
    )

    /// s — three bars joined by two small corner chips on opposite sides.
    private static let glyphS = Glyph(
        advance: 5,
        parts: [
            rect(0, 3, 5, 1.5),        // top bar
            rect(0, 4.5, 1.5, 0.75),   // upper-left joint
            rect(0, 5.25, 5, 1.5),     // middle bar
            rect(3.5, 6.75, 1.5, 0.75), // lower-right joint
            rect(0, 7.5, 5, 1.5)       // bottom bar
        ],
        tones: [.primary, .secondary, .primary, .secondary, .primary],
        entries: [
            .top(lateral: -2.5), .leading(lift: -2), .trailing(lift: 2.5),
            .bottom(lateral: 2), .bottom(lateral: -3)
        ],
        beats: [36, 38, 41, 45, 49]
    )

    /// k — full-height stem, stencil arm and leg meeting a middle junction bar.
    private static let glyphK = Glyph(
        advance: 5,
        parts: [
            rect(0, 0, 1.5, 9),        // stem
            rect(3.5, 3, 1.5, 2.25),   // upper arm
            rect(1.5, 5.25, 3.5, 1.5), // junction
            rect(3.5, 6.75, 1.5, 2.25) // leg
        ],
        tones: [.primary, .accent, .primary, .primary],
        entries: [.top(lateral: 3), .top(lateral: -2.5), .trailing(lift: -2), .bottom(lateral: 2.5)],
        beats: [52, 55, 58, 62]
    )

    /// j — tittle, descending stem, hook to the left.
    private static let glyphJ = Glyph(
        advance: 3,
        kern: -1.2,
        parts: [
            rect(1.5, 0.75, 1.5, 1.5), // tittle
            rect(1.5, 3, 1.5, 9),      // stem through the descender
            rect(0, 10.5, 1.5, 1.5)    // hook
        ],
        // The two tittles are a matched pair — same tone, so `ji` reads as a unit.
        tones: [.amber, .primary, .primary],
        entries: [.top(lateral: 2.5), .bottom(lateral: -3), .bottom(lateral: 2)],
        beats: [65, 69, 75]
    )

    /// i — tittle and stem.
    private static let glyphI = Glyph(
        advance: 1.5,
        parts: [
            rect(0, 0.75, 1.5, 1.5),   // tittle
            rect(0, 3, 1.5, 6)         // stem
        ],
        tones: [.amber, .primary],
        entries: [.top(lateral: -2), .bottom(lateral: 2.5)],
        beats: [79, 83]
    )

    /// g — bowl on the left, descending stem on the right, tail underneath.
    private static let glyphG = Glyph(
        advance: 5,
        parts: [
            rect(0, 3, 1.5, 4.5),      // bowl left
            rect(1.5, 3, 2, 1.5),      // bowl top
            rect(1.5, 6, 2, 1.5),      // bowl bottom
            rect(3.5, 3, 1.5, 9),      // stem through the descender
            rect(0, 10.5, 3.5, 1.5)    // tail
        ],
        tones: [.primary, .primary, .secondary, .primary, .accent],
        entries: [
            .bottom(lateral: -2.5), .top(lateral: 2), .leading(lift: 2.5),
            .top(lateral: -3), .bottom(lateral: 2.5)
        ],
        beats: [88, 89, 93, 97, 101]
    )

    private static let glyphs: [Glyph] = [glyphD, glyphE, glyphS, glyphK, glyphJ, glyphI, glyphG]

    // MARK: Assembly

    /// Total advance width of "deskjig" in units.
    static let unitsWide: CGFloat = {
        let advances = glyphs.reduce(0) { $0 + $1.advance + $1.kern }
        return advances + tracking * CGFloat(glyphs.count - 1)
    }()

    /// Every tile of the wordmark, laid out left to right in reading order.
    static let blocks: [SplashBlock] = {
        var result: [SplashBlock] = []
        var cursor: CGFloat = 0
        var index = 0
        for glyph in glyphs {
            cursor += glyph.kern
            for (offset, part) in glyph.parts.enumerated() {
                result.append(
                    SplashBlock(
                        id: index,
                        rect: part.offsetBy(dx: cursor, dy: 0),
                        tone: glyph.tones[offset],
                        startFrame: glyph.beats[offset],
                        entry: glyph.entries[offset]
                    )
                )
                index += 1
            }
            cursor += glyph.advance + tracking
        }
        return result
    }()
}

// MARK: - Layout

/// Maps wordmark units onto a concrete canvas.
struct SplashLayout {
    let origin: CGPoint
    let unit: CGFloat

    /// Fits the wordmark into `size`, leaving generous margins so tiles have
    /// room to travel before they clip out.
    static func fit(in size: CGSize) -> SplashLayout {
        let byWidth = size.width * 0.80 / SplashWordmark.unitsWide
        let byHeight = size.height * 0.55 / SplashWordmark.unitsTall
        let unit = max(min(byWidth, byHeight), 1)
        let wordWidth = SplashWordmark.unitsWide * unit
        let wordHeight = SplashWordmark.unitsTall * unit
        return SplashLayout(
            origin: CGPoint(
                x: (size.width - wordWidth) / 2,
                y: (size.height - wordHeight) / 2
            ),
            unit: unit
        )
    }

    /// Tile rounding: proportional to the grid, clamped so the small joint
    /// chips in `s` don't turn into lozenges.
    func cornerRadius(for rect: CGRect) -> CGFloat {
        min(unit * 0.30, min(rect.width, rect.height) * 0.34)
    }
}
