//
//  SplashWordmark.swift
//  DeskJig
//
//  Created by Claude Code on 08/25/26.
//

import CoreGraphics

/// Geometry and choreography for the "deskjig" launch wordmark.
///
/// The wordmark is deliberately *not* a typeface: every glyph is described as a
/// set of axis-aligned rectangles on a unit grid, so the finished mark reads as
/// a tiling layout that windows have snapped into — DeskJig's own subject matter.
///
/// Grid conventions (y grows downward):
/// ```
/// 0 ┌──────────  ascender top   (d, k stems; i, j dots)
/// 2 ├──────────  x-height top
/// 7 ├──────────  baseline
/// 9 └──────────  descender bottom (j, g tails)
/// ```
enum SplashWordmark {

    // MARK: - Grid

    /// Total grid height in units: 7 above the baseline, 2 below.
    static let gridHeight: CGFloat = 9
    /// Baseline row, in units from the top of the grid.
    static let baseline: CGFloat = 7
    /// Horizontal gap between adjacent glyphs, in units.
    static let letterGap: CGFloat = 1

    // MARK: - Choreography constants

    private enum Beat {
        /// Delay added per letter, left to right.
        static let perLetter: Double = 0.085
        /// Delay added per block within a letter.
        static let withinLetter: Double = 0.030
        /// When the accent dots start dropping — after every structural block.
        static let dotsStart: Double = 0.78
        /// Delay between the two dots.
        static let perDot: Double = 0.09
    }

    /// Beat (seconds after the assembly starts) at which the layout "locks":
    /// snap guides flash, ghost slots retire, the whole mark settles once.
    static let lockBeat: Double = 1.12

    // MARK: - Block model

    enum BlockRole: Equatable {
        /// A neutral tile that forms a letter stroke.
        case structure
        /// The accent-coloured dot of `i` / `j` — lands last, on its own beat.
        case dot
    }

    struct Block: Identifiable, Equatable {
        let id: Int
        /// Final resting rectangle, in grid units, origin at the grid's top-left.
        let rect: CGRect
        let role: BlockRole
        /// Seconds to wait before this block starts its flight.
        let delay: Double
    }

    // MARK: - Glyphs

    private struct Glyph {
        let width: CGFloat
        /// Stroke tiles, ordered the way they should assemble.
        let strokes: [CGRect]
        /// Optional accent dot (lowercase `i` / `j`).
        let dot: CGRect?
        /// Manual side bearing, in units, applied before the glyph is placed.
        /// Negative values tuck a glyph under its neighbour (`j` under `k`).
        let kern: CGFloat

        init(width: CGFloat, strokes: [CGRect], dot: CGRect? = nil, kern: CGFloat = 0) {
            self.width = width
            self.strokes = strokes
            self.dot = dot
            self.kern = kern
        }
    }

    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    /// "deskjig", in order.
    private static let glyphs: [Glyph] = [
        // d — bowl plus a full-height stem on the right.
        Glyph(width: 4, strokes: [
            rect(0, 2, 1, 5),
            rect(1, 2, 2, 1),
            rect(1, 6, 2, 1),
            rect(3, 0, 1, 7)
        ]),
        // e — closed upper bowl, crossbar, open lower right.
        Glyph(width: 4, strokes: [
            rect(0, 2, 1, 5),
            rect(1, 2, 3, 1),
            rect(3, 3, 1, 1),
            rect(1, 4, 3, 1),
            rect(1, 6, 3, 1)
        ]),
        // s — three bars joined by two opposing shoulders.
        Glyph(width: 4, strokes: [
            rect(0, 2, 4, 1),
            rect(0, 3, 1, 1),
            rect(0, 4, 4, 1),
            rect(3, 5, 1, 1),
            rect(0, 6, 4, 1)
        ]),
        // k — full-height stem with a stepped arm and leg. Every step overlaps
        // its neighbour by a unit so the diagonals read as strokes, not dots.
        Glyph(width: 4, strokes: [
            rect(0, 0, 1, 7),
            rect(1, 4, 2, 1),
            rect(2, 3, 2, 1),
            rect(3, 2, 1, 1),
            rect(2, 5, 2, 1),
            rect(3, 6, 1, 1)
        ]),
        // j — descending stem with a left hook that tucks under the k.
        Glyph(width: 3, strokes: [
            rect(2, 2, 1, 7),
            rect(0, 8, 2, 1)
        ], dot: rect(2, 0, 1, 1), kern: -1),
        // i — single stem, dotted above.
        Glyph(width: 1, strokes: [
            rect(0, 2, 1, 5)
        ], dot: rect(0, 0, 1, 1)),
        // g — bowl plus a descending stem and tail.
        Glyph(width: 4, strokes: [
            rect(0, 2, 3, 1),
            rect(0, 3, 1, 3),
            rect(0, 6, 3, 1),
            rect(3, 2, 1, 7),
            rect(0, 8, 3, 1)
        ])
    ]

    // MARK: - Assembled layout

    private static let layout: (blocks: [Block], width: CGFloat) = {
        var result: [Block] = []
        var pen: CGFloat = 0
        var nextID = 0
        var dotIndex = 0
        var width: CGFloat = 0

        // Dots are collected separately so they paint (and land) last.
        var dots: [(CGRect, Double)] = []

        for (letterIndex, glyph) in glyphs.enumerated() {
            pen += glyph.kern
            for (strokeIndex, stroke) in glyph.strokes.enumerated() {
                let placed = stroke.offsetBy(dx: pen, dy: 0)
                let delay = Double(letterIndex) * Beat.perLetter
                    + Double(strokeIndex) * Beat.withinLetter
                result.append(Block(id: nextID, rect: placed, role: .structure, delay: delay))
                width = max(width, placed.maxX)
                nextID += 1
            }
            if let dot = glyph.dot {
                let placed = dot.offsetBy(dx: pen, dy: 0)
                dots.append((placed, Beat.dotsStart + Double(dotIndex) * Beat.perDot))
                width = max(width, placed.maxX)
                dotIndex += 1
            }
            pen += glyph.width + letterGap
        }

        for (rect, delay) in dots {
            result.append(Block(id: nextID, rect: rect, role: .dot, delay: delay))
            nextID += 1
        }
        return (result, width)
    }()

    /// Total wordmark width in grid units.
    static var gridWidth: CGFloat { layout.width }

    /// Every tile in the wordmark, in animation order, with its beat baked in.
    static var blocks: [Block] { layout.blocks }
}
