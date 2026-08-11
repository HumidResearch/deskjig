//  DeskJigLoadingIndicator.swift
//  DeskJig
//
//  Created by Jake Sax on 11/11/25.
//

import SwiftUI
import Lottie
import DeskJigShared

/// Our looping branded loading indicator. Defaults to 100x100 and colored white with 80% opacity.
struct DeskJigLoadingIndicator: View {
    
    var size: CGFloat = 100
    var color: LottieColor = .init(
        r: 255/255,
        g: 255/255,
        b: 255/255,
        a: 0.8
    )
    @State private var file: DotLottieFile? = nil
    
    var body: some View {
        VStack {
            if let file {
                LottieView(dotLottieFile: file)
                    .playing(loopMode: .loop)
                    .configure { view in
                        view.setValueProvider(
                            ColorValueProvider(color),
                            keypath: AnimationKeypath(keypath: "**.Fill 1.Color")
                        )
                    }
                    .transition(.animatedBlur)
            }
        }
        .frame(width: size, height: size)
        .task {
            if file == nil {
                do {
                    self.file = try await DotLottieFile.named("DeskJigLoadingIndicator")
                } catch {
                    DeskJigLog.error(.app, "DeskJigLoadingIndicator: Error loading lottie file", fields: ["error": error.localizedDescription])
                }
            }
        }
    }
}

#Preview {
    DeskJigLoadingIndicator()
        .padding(20)
        .background(Color.white)
}
