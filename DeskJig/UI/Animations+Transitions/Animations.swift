//
//  Animations.swift
//  DeskJig
//
//  Created by Jake Sax on 10/20/25.
//

import SwiftUI

public extension Animation {
    /// A `.smooth` Animation with a duration of 0.35.
    static let smoothDefault: Animation = .smooth(duration: 0.35)
}

public extension AnyTransition {
    /// A `.blurReplace` transition with a `.smooth` animation with a duration of 0.35.
    @MainActor static let animatedBlur: AnyTransition = AnyTransition(
        BlurReplaceTransition(configuration: .downUp)
            .animation(.smoothDefault)
    )
}