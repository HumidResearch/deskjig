//  SimpleOnboardingOverlay.swift
//  DeskJig
//
//  Simple 5-step onboarding overlay with progress indicators
//

import SwiftUI
import DeskJigShared
import AVKit
import ApplicationServices

struct SimpleOnboardingOverlay: View {
    let viewModel: SimpleOnboardingViewModel
    let currentStage: SimpleOnboardingViewModel.Stage
    var isEmbeddedInMainContent: Bool = false
    @State private var hasAccessibilityPermissions = false
    @State private var permissionsPollingTimer: Timer?

    typealias Stage = SimpleOnboardingViewModel.Stage

    /// Disable Next button on permissions step until permissions are granted
    private var nextButtonDisabled: Bool {
        currentStage == .permissions && !hasAccessibilityPermissions
    }

    private var topHorizontalPadding: CGFloat { isEmbeddedInMainContent ? 24 : 32 }
    private var topVerticalPadding: CGFloat { isEmbeddedInMainContent ? 20 : 32 }
    private var topBottomPadding: CGFloat { isEmbeddedInMainContent ? 14 : 24 }
    private var contentHorizontalPadding: CGFloat { isEmbeddedInMainContent ? 24 : 32 }
    private var stageContentSpacing: CGFloat { isEmbeddedInMainContent ? 24 : 32 }
    private var descriptionHorizontalPadding: CGFloat { isEmbeddedInMainContent ? 24 : 32 }
    private var bottomHorizontalPadding: CGFloat { isEmbeddedInMainContent ? 24 : 32 }
    private var bottomTopPadding: CGFloat { isEmbeddedInMainContent ? 16 : 24 }
    private var bottomPadding: CGFloat { isEmbeddedInMainContent ? 18 : 32 }
    private var illustrationWidth: CGFloat { isEmbeddedInMainContent ? 640 : 720 }

    private var onboardingContent: some View {
        VStack(spacing: 0) {
            // Top section with progress and skip button
            HStack(alignment: .top) {
                progressIndicator

                Spacer()

                HStack(spacing: 10) {
                    Button("Skip") {
                        viewModel.skipOnboarding()
                    }
                    .buttonStyle(
                        .deskJig(
                            backgroundStyle: { Color.white.opacity($0 ? 0.1 : 0) },
                            brightnessOnHover: 0.1
                        )
                    )

                    Button {
                        viewModel.closeOnboarding()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.Text.primary)
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, topHorizontalPadding)
            .padding(.top, topVerticalPadding)
            .padding(.bottom, topBottomPadding)

            if !isEmbeddedInMainContent {
                Spacer()
            }

            // Main content
            VStack(spacing: stageContentSpacing) {
                // Stage content
                stageContent(for: currentStage)
                    .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, contentHorizontalPadding)

            if !isEmbeddedInMainContent {
                Spacer()
            }

            // Bottom navigation
            HStack(spacing: 16) {
                if viewModel.canGoBack {
                    Button("Back") {
                        viewModel.previousStage()
                    }
                    .buttonStyle(
                        .deskJig(
                            font: .h5,
                            backgroundStyle: Color.white.opacity(0.1)
                        )
                    )
                    .transition(.animatedBlur)
                }

                Spacer()

                Button(viewModel.isLastStage ? "Get Started" : "Next") {
                    viewModel.advanceStage()
                }
                .buttonStyle(
                    .deskJig(
                        font: .h5,
                        backgroundStyle: nextButtonDisabled ? Color.white.opacity(0.05) : Color.white.opacity(0.15)
                    )
                )
                .disabled(nextButtonDisabled)
                .opacity(nextButtonDisabled ? 0.5 : 1.0)
            }
            .padding(.horizontal, bottomHorizontalPadding)
            .padding(.bottom, bottomPadding)
            .padding(.top, bottomTopPadding)
        }
    }

    var body: some View {
        Group {
            if isEmbeddedInMainContent {
                onboardingContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                onboardingContent
                    .frame(width: 1080, height: 720)
                    .presentationBackground(.black.opacity(0.8))
            }
        }
        .animation(.smooth(duration: 0.35), value: currentStage)
    }

    // MARK: - Progress Indicator

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Stage.allCases) { stage in
                let isActiveOrComplete = stage.step <= currentStage.step
                let isActive = stage == currentStage
                Capsule()
                    .fill(Color.white.opacity(isActiveOrComplete ? 1 : 0.2))
                    .frame(width: isActive ? 40 : 24, height: 4)
                    .animation(.smooth(duration: 0.3), value: isActiveOrComplete)
                    .animation(.smooth(duration: 0.3), value: isActive)
            }
        }
    }

    // MARK: - Stage Content

    @ViewBuilder
    private func stageContent(for stage: Stage) -> some View {
        VStack(spacing: stageContentSpacing) {
            // Stage number
            Text("\(stage.step + 1) of \(Stage.allCases.count)")
                .font(brand: .label3)
                .foregroundStyle(DesignTokens.Text.primary.opacity(0.5))

            // Title
            Text(stage.title)
                .font(brand: .h1)
                .foregroundStyle(DesignTokens.Text.primary)
                .multilineTextAlignment(.center)

            // Visual illustration
            stageIllustration(for: stage)

            // Description
            Text(stage.description)
                .font(brand: .body2)
                .foregroundStyle(DesignTokens.Text.primary.opacity(0.85))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, descriptionHorizontalPadding)
        }
    }

    // MARK: - Stage Illustrations

    @ViewBuilder
    private func stageIllustration(for stage: Stage) -> some View {
        switch stage {
        case .intro:
            introIllustration
        case .menuBar:
            menuBarIllustration
        case .movingWindows:
            movingWindowsIllustration
        case .zones:
            zonesIllustration
        case .tidyUp:
            tidyUpIllustration
        case .savingWorkspaces:
            savingWorkspacesIllustration
        case .permissions:
            permissionsIllustration
        }
    }

    private var introIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .stroke(Color.white.opacity(0.1), lineWidth: 1)

            // Video background with 16:9 aspect ratio (1920x1080)
            LoopingVideoPlayer(videoName: "welcome", assetName: "WelcomeVideo")
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .aspectRatio(16/9, contentMode: .fit)
        .frame(width: illustrationWidth)
    }

    private var menuBarIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .stroke(Color.white.opacity(0.1), lineWidth: 1)

            // Video background with 1.54:1 aspect ratio (1920x1246)
            LoopingVideoPlayer(videoName: "menu-bar-tutorial", assetName: "MenuBarTutorialVideo")
                .aspectRatio(1.54, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .aspectRatio(1.54, contentMode: .fit)
        .frame(width: illustrationWidth)
    }

    private var movingWindowsIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .stroke(Color.white.opacity(0.1), lineWidth: 1)

            // Video background with 1.54:1 aspect ratio (1920x1246)
            LoopingVideoPlayer(videoName: "moving-windows", assetName: "MovingWindowsVideo")
                .aspectRatio(1.54, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .aspectRatio(1.54, contentMode: .fit)
        .frame(width: illustrationWidth)
    }

    private var zonesIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .stroke(Color.white.opacity(0.1), lineWidth: 1)

            // Video background with 1.54:1 aspect ratio (3024x1964)
            LoopingVideoPlayer(videoName: "zones", assetName: "ZonesVideo")
                .aspectRatio(1.54, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .aspectRatio(1.54, contentMode: .fit)
        .frame(width: illustrationWidth)
    }

    private var tidyUpIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .stroke(Color.white.opacity(0.1), lineWidth: 1)

            // Video background with 1.54:1 aspect ratio (3024x1964)
            LoopingVideoPlayer(videoName: "tidy-up", assetName: "TidyUpVideo")
                .aspectRatio(1.54, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .aspectRatio(1.54, contentMode: .fit)
        .frame(width: illustrationWidth)
    }

    private var savingWorkspacesIllustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .stroke(Color.white.opacity(0.1), lineWidth: 1)

            // Video background with 1.54:1 aspect ratio (3024x1964)
            LoopingVideoPlayer(videoName: "saved-workspaces", assetName: "SavedWorkspacesVideo")
                .aspectRatio(1.54, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .aspectRatio(1.54, contentMode: .fit)
        .frame(width: illustrationWidth)
    }

    private var permissionsIllustration: some View {
        let showGrantedState = hasAccessibilityPermissions && !viewModel.shouldForcePermissionsSetupUIInDebug

        return ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .stroke(Color.white.opacity(0.1), lineWidth: 1)

            if showGrantedState {
                // Permissions already granted - success state
                VStack(spacing: 24) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(brand: Font.brandBody(size: 100))
                        .foregroundStyle(DesignTokens.Brand.accent)

                    Text("Accessibility Enabled!")
                        .font(brand: .h2)
                        .foregroundStyle(DesignTokens.Text.primary)

                    Text("You're all set. Click Next to continue.")
                        .font(brand: .body1)
                        .foregroundStyle(DesignTokens.Text.primary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
            } else {
                // Permissions not granted - show screenshot with button overlay
                VStack(spacing: 24) {
                    // Large screenshot matching the video dimensions
                    Image("PermissionsScreenshot")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                        .padding(.horizontal, 40)
                        .padding(.top, 24)

                    // Allow Access button
                    Button {
                        requestAccessibilityPermissions()
                    } label: {
                        Text("Allow Access")
                            .font(brand: .h5)
                            .padding(.horizontal, 40)
                            .padding(.vertical, 14)
                            .background(DesignTokens.Brand.accentMuted)
                            .foregroundStyle(DesignTokens.Text.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 24)
                }
            }
        }
        .aspectRatio(1.54, contentMode: .fit)
        .frame(width: illustrationWidth)
        .onAppear {
            hasAccessibilityPermissions = AXIsProcessTrusted()
            startPermissionsPolling()
        }
        .onDisappear {
            stopPermissionsPolling()
        }
    }

    // MARK: - Permissions Helpers

    private func requestAccessibilityPermissions() {
        // Request permissions using the native macOS dialog
        // AXIsProcessTrustedWithOptions with kAXTrustedCheckOptionPrompt will:
        // - Show the native permission dialog if not already granted
        // - Do nothing if already granted
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        hasAccessibilityPermissions = accessEnabled

        // Keep debug permissions testing deterministic: still open the Accessibility pane
        // even when permission is already granted and we are forcing the setup UI.
        if !accessEnabled || viewModel.shouldForcePermissionsSetupUIInDebug {
            openAccessibilitySettingsPane()
        }

        // Also trigger TCC Automation permission for Chrome restoration.
        // This runs osascript in the background to prompt for System Events access.
        // The warmup uses a semaphore-based state machine so that restoration will
        // block on verifyTCCPermission() until this async warmup completes.
        DispatchQueue.global(qos: .userInitiated).async {
            ChromeAutomationService.warmupTCCIfNeeded()
        }
    }

    private func openAccessibilitySettingsPane() {
        guard let url = SettingsPane.accessibility.url else {
            DeskJigLog.error(.onboarding, "SimpleOnboardingOverlay: Failed to open Accessibility settings (invalid URL)")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSWorkspace.shared.open(url)
        }
    }

    private func startPermissionsPolling() {
        permissionsPollingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            let isTrusted = AXIsProcessTrusted()
            if isTrusted != hasAccessibilityPermissions {
                hasAccessibilityPermissions = isTrusted
            }
        }
    }

    private func stopPermissionsPolling() {
        permissionsPollingTimer?.invalidate()
        permissionsPollingTimer = nil
    }
}

// MARK: - Looping Video Player

struct LoopingVideoPlayer: NSViewRepresentable {
    let videoName: String
    let assetName: String

    func makeNSView(context: Context) -> PlayerContainerView {
        let playerView = PlayerContainerView()

        // Try to load from asset catalog dataset
        guard let asset = NSDataAsset(name: assetName),
              let tempURL = saveTempVideo(data: asset.data, videoName: videoName) else {
            DeskJigLog.error(.onboarding, "SimpleOnboardingOverlay: Could not find video asset: \(assetName)")
            return playerView
        }

        let player = AVPlayer(url: tempURL)
        playerView.setupPlayer(player)

        // Loop video
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { _ in
            player.seek(to: .zero)
            player.play()
        }

        player.play()
        context.coordinator.player = player

        return playerView
    }

    func updateNSView(_ nsView: PlayerContainerView, context: Context) {
        // Layout is handled by the custom NSView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func saveTempVideo(data: Data, videoName: String) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let videoURL = tempDir.appendingPathComponent("\(videoName).mp4")

        do {
            try data.write(to: videoURL)
            return videoURL
        } catch {
            DeskJigLog.error(.onboarding, "SimpleOnboardingOverlay: Failed to write video to temp: \(error)")
            return nil
        }
    }

    class Coordinator {
        var player: AVPlayer?
    }
}

// Custom NSView that properly handles player layer layout
class PlayerContainerView: NSView {
    private var player: AVPlayer?

    override func makeBackingLayer() -> CALayer {
        let playerLayer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspect
        return playerLayer
    }

    func setupPlayer(_ player: AVPlayer) {
        self.player = player
        wantsLayer = true

        if let playerLayer = layer as? AVPlayerLayer {
            playerLayer.player = player
        }
    }

    override func layout() {
        super.layout()
        layer?.frame = bounds
    }
}
