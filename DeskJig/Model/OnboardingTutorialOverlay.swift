//  OnboardingTutorialOverlay.swift
//  DeskJig
//
//  Created by Jake Sax on 10/16/25.
//

import SwiftUI
import KeyboardShortcuts
import DeskJigShared

struct OnboardingTutorialOverlay: View {
    let viewModel: OnboardingTutorialViewModel
    let activeStage: Stage
    var isEmbeddedInMainContent: Bool = false
    @FocusState private var isFocused: Bool
    @Namespace private var namespace
    typealias Stage = OnboardingTutorialViewModel.Stage

    var body: some View {
        Group {
            if isEmbeddedInMainContent {
                tutorialCard
                    .frame(width: 900, height: 700)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                tutorialCard
                    .frame(width: 900, height: 700)
                    .presentationBackground(.black.opacity(0.8))
            }
        }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .animation(.smooth(duration: 0.35), value: activeStage)
            .onAppear {
                DispatchQueue.main.async {
                    isFocused = true
                }
            }
            .onChange(of: isFocused) {
                if !isFocused {
                    isFocused = true
                }
            }
            .onDisappear {
                isFocused = false
            }
            .onKeyPress(.return) {
                if viewModel.proceedToNextStepIfPossible() {
                    return .handled
                }
                return .ignored
            }
    }

}

// MARK: - SubViews
private extension OnboardingTutorialOverlay {

    var tutorialCard: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(activeStage == .launchHotkey ? "Launch Tutorial" : "Movement Tutorial")
                        .font(brand: .label3)
                        .foregroundStyle(DesignTokens.Text.primary.opacity(0.7))
                    Text(activeStage.title)
                        .font(brand: .h1)
                        .foregroundStyle(DesignTokens.Text.primary)
                }

                Spacer()

                if let previous = activeStage.previous {
                    navButton(symbolName: "chevron.left") {
                        viewModel.startTutorial(stage: previous)
                    }
                }

                navButton(symbolName: "xmark") {
                    viewModel.closeTutorial()
                }

            }

            stageContent(for: activeStage)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 4) {
                let subtitle = stageSubtitle(for: activeStage)
                if let subtitle {
                    Text(subtitle)
                        .font(brand: .h4)
                        .foregroundStyle(DesignTokens.Text.primary)
                        .transition(.blurReplace.animation(.smooth(duration: 0.35)))
                }

                Text(stagePrimaryDirective(for: activeStage))
                    .font(brand: .body2)
                    .foregroundStyle(DesignTokens.Text.primary.opacity(subtitle == nil ? 1 : 0.75))
                    .lineLimit(2, reservesSpace: true)
            }

            HStack {
                let footer = stageFooterInfo(for: activeStage)
                Text(footer.text)
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Text.primary.opacity(footer.shouldPulse ? 0.85 : 0.7))
                    .repeatingAnimation(
                        isActive: footer.shouldPulse,
                        duration: 0.9,
                        animation: .smooth(duration: 0.9)
                    ) { content, didAnimate, isActive in
                        content
                            .opacity(!isActive ? 1 : (didAnimate ? 0.45 : 1))
                            .scaleEffect(
                                !isActive ? 1 : (didAnimate ? 1.06 : 1),
                                anchor: .init(x: 0.2, y: 0.5)
                            )
                    }

                Spacer()

                Button(nextButtonTitle(for: activeStage)) {
                    _ = viewModel.proceedToNextStepIfPossible()
                }
                .buttonStyle(.deskJig(font: .h5, backgroundStyle: Color.white.opacity(0.15)))
                .disabled(!viewModel.canAdvanceCurrentStage)
                .opacity(viewModel.canAdvanceCurrentStage ? 1 : 0.55)
            }
        }
        .padding(32)
    }

    func navButton(
        symbolName: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(brand: Font.brandBody(size: 14))
                .foregroundStyle(DesignTokens.Text.primary)
                .padding(8)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .transition(.animatedBlur)
    }

    @ViewBuilder
    func stageContent(for stage: Stage) -> some View {
        switch stage {
        case .launchHotkey: launchHotkeyStageContent
        case .basics: basicsStageContent
        case .hotkeys: hotkeysStageContent
        case .movement: movementStageContent
        }
    }

    var launchHotkeyStageContent: some View {
        contentWithBackground {
            movementRecorderRow(title: "Launch DeskJig:", name: .showWorkspaceView)
                .padding(8)
                .padding(.horizontal, 8)
                .background {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                        .shadow(radius: 6)
                }
        }
    }

    var basicsStageContent: some View {
        contentWithBackground {
            AutoPlayingMovementSimulationCanvas()
                .padding(-16)
        }
    }

    var hotkeysStageContent: some View {
        contentWithBackground {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    movementRecorderRow(title: "Move left:", name: .moveWindowLeft)
                    movementRecorderRow(title: "Move right:", name: .moveWindowRight)
                    movementRecorderRow(title: "Move up:", name: .moveWindowUp)
                    movementRecorderRow(title: "Move down:", name: .moveWindowDown)
                    movementRecorderRow(title: "Center:", name: .centerWindow)
                    movementRecorderRow(title: "Maximize:", name: .maximizeWindow)
                }
                .padding(16)
                .background {
                    RoundedRectangle(cornerRadius: 32)
                        .fill(Color.white.opacity(0.1))
                        .shadow(radius: 8)
                }

                // Warning when hotkeys are not all set
                if !viewModel.areRequiredHotkeysSet {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DesignTokens.Brand.accent)
                        Text("Please set all hotkeys above to continue to the practice tutorial.")
                            .font(brand: .label3)
                            .foregroundStyle(DesignTokens.Text.primary.opacity(0.85))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(DesignTokens.Brand.accent.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    func movementRecorderRow(
        title: String,
        name: KeyboardShortcuts.Name
    ) -> some View {
        HStack(spacing: 40) {
            Text(title)
                .font(brand: .label3)
                .foregroundStyle(DesignTokens.Text.primary.opacity(0.85))
                .frame(width: 120, alignment: .leading)
            KeyboardShortcuts.Recorder("", name: name)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
    }

    var movementStageContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            contentWithBackground {
                MovementSimulationCanvas(
                    state: viewModel.simulationState,
                    labelText: viewModel.currentShortcutLabel
                )
                .padding(-16)
            }

            movementProgressIndicators
        }
    }

    var movementProgressIndicators: some View {
        HStack(spacing: 12) {
            ForEach(
                OnboardingTutorialViewModel.MovementSubstage.allCases,
                id: \.self
            ) { substage in
                let color = progressColor(for: substage)
                Capsule()
                    .fill(color)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    .frame(height: 6)
                    .animation(.smooth(duration: 0.35), value: color)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }


    func progressColor(
        for substage: OnboardingTutorialViewModel.MovementSubstage
    ) -> Color {
        if viewModel.isStageCompleted(.movement) {
            return DesignTokens.Brand.accent.opacity(0.8)
        }

        if viewModel.activeMovementSubstage == substage {
            return viewModel.didCenter ? DesignTokens.Brand.accent.opacity(0.8) : Color.white.opacity(0.9)
        }

        let completed: Bool
        switch substage {
        case .leftRight:
            completed = viewModel.leftRightActions.contains(.left) && viewModel.leftRightActions.contains(.right)
        case .upDown:
            completed = viewModel.upDownActions.contains(.up) && viewModel.upDownActions.contains(.down)
        case .maximize:
            completed = viewModel.didMaximize
        case .center:
            completed = viewModel.didCenter
        }

        return completed ? DesignTokens.Brand.accent.opacity(0.8) : Color.white.opacity(0.2)
    }

    func contentWithBackground<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.white.opacity(0.05))
            .stroke(Color.white.opacity(0.08), lineWidth: 1)
            .overlay {
                content()
                    .padding(24)
            }
            .frame(height: 360)
            .matchedGeometryEffect(id: "primaryContent", in: namespace)
    }
}

// MARK: - Content
private extension OnboardingTutorialOverlay {

    func movementInstructionText(
        for substage: OnboardingTutorialViewModel.MovementSubstage
    ) -> String {
        switch substage {
        case .leftRight:
            "Use your left and right shortcuts to cycle through different widths on each side of the screen."
        case .upDown:
            "Move windows vertically. Press your up and down shortcuts to see them stack in tidy rows."
        case .maximize:
            "Press your maximize shortcut to fill the entire display."
        case .center:
            "Press your center shortcut to bring the window back to the middle."
        }
    }

    func stagePrimaryDirective(
        for stage: Stage
    ) -> String {
        switch stage {
        case .launchHotkey: "This is the shortcut that launches the DeskJig command palette. You can always revisit Settings to change this later."
        case .basics:
            "We'll help you set up shortcuts to snap your apps to thirds, halves, and more so your workspace stays organized."
        case .hotkeys:
            "Pick the keys that feel natural. We'll use these throughout the tutorial and when managing your windows later. You can always revisit Settings to tweak these later."
        case .movement:
            movementInstructionText(for: viewModel.activeMovementSubstage)
        }
    }

    func stageSubtitle(for stage: Stage) -> String? {
        switch stage {
        case .movement: viewModel.activeMovementSubstage.title
        default: nil
        }
    }

    func stageFooterInfo(
        for stage: Stage
    ) -> (text: String, shouldPulse: Bool) {
        switch stage {
        case .launchHotkey:
            return ("Tip: Use a shortcut that you don't use in other apps.", false)
        case .basics:
            return ("Ready to choose your shortcuts?", false)
        case .hotkeys:
            if viewModel.areRequiredHotkeysSet {
                return ("All hotkeys set! Ready to practice.", false)
            } else {
                return ("Tip: Try Ctrl+Option+Arrow keys for movement.", false)
            }
        case .movement:
            return movementFooterInfo(for: viewModel.activeMovementSubstage)
        }
    }

    func nextButtonTitle(
        for stage: Stage
    ) -> String {
        switch stage {
        case .launchHotkey:
            "Next: Basics"
        case .basics:
            "Next: Hotkeys"
        case .hotkeys:
            "Next: Practice"
        case .movement:
            viewModel.activeMovementSubstage == .center ? "Finish Tutorial" : "Next step"
        }
    }

    func movementFooterInfo(
        for substage: OnboardingTutorialViewModel.MovementSubstage
    ) -> (String, Bool) {
        switch substage {
        case .leftRight:
            let left = viewModel.leftRightActions.contains(.left)
            let right = viewModel.leftRightActions.contains(.right)
            switch (left, right) {
            case (true, true):
                return ("Nice! Left and right are dialed in.", false)
            case (true, false):
                return ("Great! Now press your move right shortcut.", true)
            case (false, true):
                return ("Great! Now press your move left shortcut.", true)
            case (false, false):
                return ("Use left and right to explore every width.", false)
            }
        case .upDown:
            let up = viewModel.upDownActions.contains(.up)
            let down = viewModel.upDownActions.contains(.down)
            switch (up, down) {
            case (true, true):
                return ("Perfect! Windows are flowing vertically.", false)
            case (true, false):
                return ("Nice! Now press your move down shortcut.", true)
            case (false, true):
                return ("Nice! Now press your move up shortcut.", true)
            case (false, false):
                return ("Press up and down to see tidy rows.", false)
            }
        case .maximize:
            return (viewModel.didMaximize ? "Window maximized—ready when you are." : "Press maximize to fill the screen.", false)
        case .center:
            return (viewModel.didCenter ? "All centered—continue when ready." : "Press your center shortcut to finish up.", false)
        }
    }

}

// MARK: - Canvas Simulation
private extension OnboardingTutorialOverlay {

    struct MovementSimulationCanvas: View {
        let state: OnboardingTutorialViewModel.SimulationState
        let labelText: String?

        var body: some View {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(0.05))

                    RoundedRectangle(cornerRadius: 20)
                        .fill(DesignTokens.Brand.accent.opacity(0.35))
                        .stroke(Color.white.opacity(0.4), lineWidth: 1.5)
                        .frame(
                            width: geometry.size.width * state.normalizedFrame.width,
                            height: geometry.size.height * state.normalizedFrame.height
                        )
                        .offset(
                            x: geometry.size.width * state.normalizedFrame.origin.x,
                            y: geometry.size.height * state.normalizedFrame.origin.y
                        )
                        .overlay {
                            if let labelText {
                                Text(labelText)
                                    .font(brand: .h1)
                                    .foregroundStyle(DesignTokens.Text.primary.opacity(0.9))
                                    .padding(24)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .transition(.blurReplace.animation(.smooth(duration: 0.35)))
                            }
                        }
                }
            }
            .animation(
                .smooth(duration: 0.3, extraBounce: 0.15),
                value: state.normalizedFrame
            )
            .animation(
                .smooth(duration: 0.3, extraBounce: 0.15),
                value: labelText
            )
        }
    }

    struct AutoPlayingMovementSimulationCanvas: View {

        @State private var rectangleState: RectangleState = .leftThird
        private var simState: OnboardingTutorialViewModel.SimulationState { .init(normalizedFrame: rectangleState.rect)
        }
        @State private var timer: Timer? = nil

        var body: some View {
            MovementSimulationCanvas(state: simState, labelText: nil)
                .onAppear {
                    withTransaction(.init(animation: nil)) {
                        rectangleState = .leftThird
                    }
                    guard self.timer == nil else { return }
                    self.timer = Timer.scheduledTimer(
                        withTimeInterval: 1,
                        repeats: true
                    ) { _ in
                        rectangleState = rectangleState.next
                    }
                }
                .onDisappear {
                    self.timer?.invalidate()
                    self.timer = nil
                }
        }

        enum RectangleState: String, Hashable {
            case leftThird, rightThird, center, maximized

            var next: Self {
                switch self {
                case .leftThird: .rightThird
                case .rightThird: .center
                case .center: .maximized
                case .maximized: .leftThird
                }
            }

            var rect: CGRect {
                switch self {
                case .leftThird: CGRect(x: 0, y: 0, width: 1/3.0, height: 1)
                case .rightThird: CGRect(x: 2/3.0, y: 0, width: 1/3.0, height: 1)
                case .center: CGRect(x: 1/6.0, y: 1/6.0, width: 2/3.0, height: 2/3.0)
                case .maximized: CGRect(x: 0, y: 0, width: 1, height: 1)
                }
            }
        }
    }

}
