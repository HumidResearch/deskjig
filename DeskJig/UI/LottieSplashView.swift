//  LottieSplashView.swift
//  DeskJig
//
//  Created by Cursor on 10/17/2025.
//

import SwiftUI
import AVKit
import DeskJigShared

struct LottieSplashView: View {
    let onComplete: () -> Void
    
    let videoAspectRatio: CGFloat = 16 / 9
    let width: CGFloat = 600
    
    var body: some View {
        ZStack {
            // White background for splash screen
            Color.white
                .ignoresSafeArea()
            
            // Video Animation
            VideoSplashPlayer(onComplete: onComplete)
                .frame(width: width, height: width / videoAspectRatio)
                .overlay { // covers up outline caused by video
                    Rectangle().stroke(.white, lineWidth: 6)
                }
        }
    }
}

struct VideoSplashPlayer: NSViewRepresentable {
    let onComplete: () -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        
        guard let videoURL = Bundle.main.url(forResource: "deskjig-motion", withExtension: "mp4") else {
            DeskJigLog.warn(.app, "LottieSplashView: Video file not found")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                onComplete()
            }
            return view
        }
        
        let player = AVPlayer(url: videoURL)
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = view.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        
        view.layer = CALayer()
        view.wantsLayer = true
        view.layer?.addSublayer(playerLayer)
        
        // Observe when video finishes playing
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            // Add a small delay before dismissing for smoother transition
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeOut(duration: 0.3)) {
                    onComplete()
                }
            }
        }
        
        // Start playing
        player.play()
        
        context.coordinator.player = player
        context.coordinator.playerLayer = playerLayer
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let playerLayer = context.coordinator.playerLayer {
            playerLayer.frame = nsView.bounds
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var player: AVPlayer?
        var playerLayer: AVPlayerLayer?
    }
}
