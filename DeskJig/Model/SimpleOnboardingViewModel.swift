//  SimpleOnboardingViewModel.swift
//  DeskJig
//
//  Simple 5-step onboarding tutorial
//

import SwiftUI
import Combine
import DeskJigShared

@MainActor @Observable
final class SimpleOnboardingViewModel {

    // MARK: - Published State

    var isPresented: Bool = false
    private(set) var currentStage: Stage = .intro

    /// Completion state, mirrored into `UserDefaults` under ``persistenceKey``.
    ///
    /// Stored (not computed off `UserDefaults`) on purpose: the settings window
    /// gates navigation on `!isCompleted` and re-presents onboarding whenever
    /// `isPresented` drops while the gate is active. A computed defaults read is
    /// invisible to `@Observable`, so recording completion never invalidated the
    /// SwiftUI graph and the gate could still be evaluated against stale state.
    private(set) var isCompleted: Bool = false

    // MARK: - Configuration

    private static let basePersistenceKey = "SimpleOnboarding.Completed"
#if DEBUG
    private static let debugPermissionsJumpConsumedBaseKey = "SimpleOnboarding.DebugPermissionsJumpConsumed"
#endif
    static let progressResetNotification = Notification.Name("SimpleOnboarding.ProgressReset")

    private let userDefaults: UserDefaults
    private let progressStore: TutorialProgressStore
    private var cancellables = Set<AnyCancellable>()
#if DEBUG
    /// Runtime-only debug context. Not persisted.
    private var debugStartAtPermissionsForNewUsersEnabled: Bool = false
    private var debugCurrentSessionIsNewUser: Bool = false
    private var debugForcePermissionsSetupUI: Bool = false
#endif

    // MARK: - Init

    init(userDefaults: UserDefaults = .standard, progressStore: TutorialProgressStore = .shared) {
        self.userDefaults = userDefaults
        self.progressStore = progressStore

        // Installs upgraded from the account-scoped predecessor recorded completion
        // under `"<uid>.SimpleOnboarding.Completed"`. Without this one-time sweep
        // those users are shown first-run onboarding again.
        LegacyStoreAdoption.adoptLegacyCompletionFlagIfNeeded(
            baseKey: Self.basePersistenceKey,
            flagKey: LegacyStoreAdoption.onboardingAdoptionCompletedKey,
            in: userDefaults
        )
        self.isCompleted = userDefaults.bool(forKey: Self.basePersistenceKey)

        setupObservers()
    }

    // MARK: - Persistence Key

    private var persistenceKey: String {
        Self.basePersistenceKey
    }

#if DEBUG
    private var debugPermissionsJumpConsumedKey: String {
        Self.debugPermissionsJumpConsumedBaseKey
    }
#endif

    // MARK: - Entry Points

    enum StartEntryPoint {
        case automaticPresentation
        case manualLaunch

        fileprivate var logLabel: String {
            switch self {
            case .automaticPresentation:
                return "automatic"
            case .manualLaunch:
                return "manual"
            }
        }
    }

    func presentIfIncomplete() {
        guard !isPresented else {
            DeskJigLog.info(.app, "SimpleOnboarding: Will not present, already presented")
            return
        }
        guard !isCompleted else {
            DeskJigLog.info(.app, "SimpleOnboarding: Will not present, already completed")
            return
        }
        startOnboarding(entryPoint: .automaticPresentation)
    }

    func startOnboarding(entryPoint: StartEntryPoint = .manualLaunch) {
        var startingStage: Stage = .intro
#if DEBUG
        if shouldStartAtPermissionsForDebug(entryPoint: entryPoint) {
            startingStage = .permissions
            markDebugPermissionsJumpConsumed()
        }
#endif
        currentStage = startingStage
        isPresented = true
        DeskJigLog.info(.app, "SimpleOnboarding: Starting simple onboarding", fields: ["stage": startingStage.rawValue, "entryPoint": entryPoint.logLabel])
    }

    /// Re-presents ONLY the permissions stage for a migrated user whose
    /// completed onboarding was adopted from Bento but whose Accessibility
    /// grant did not carry over (#20 — the grant is keyed to the app
    /// signature). `isCompleted` is left untouched: advancing past the stage
    /// (it's the last one) or closing the overlay re-marks completion
    /// idempotently, and the settings-window onboarding gate never re-arms
    /// because completion never drops.
    func presentPermissionsStageForMigration() {
        guard !isPresented else {
            DeskJigLog.info(.app, "SimpleOnboarding: Will not present permissions stage, already presented")
            return
        }
        currentStage = .permissions
        isPresented = true
        DeskJigLog.info(.app, "SimpleOnboarding: Presenting permissions stage for migrated user")
    }

    func closeOnboarding() {
        isPresented = false
        DeskJigLog.info(.app, "SimpleOnboarding: Closing simple onboarding")
    }

    func completeOnboarding() {
        markCompleted()
        closeOnboarding()
        DeskJigLog.info(.app, "SimpleOnboarding: Completed simple onboarding")
        DeskJigLog.info(.app, "Tutorial completed", fields: ["stepsCompleted": Stage.allCases.count])
    }

    func advanceStage() {
        guard let nextStage = currentStage.next else {
            completeOnboarding()
            return
        }
        currentStage = nextStage
        DeskJigLog.info(.app, "SimpleOnboarding: Advanced to stage", fields: ["stage": nextStage.rawValue])
    }

    func previousStage() {
        guard let prevStage = currentStage.previous else { return }
        currentStage = prevStage
        DeskJigLog.info(.app, "SimpleOnboarding: Went back to stage", fields: ["stage": prevStage.rawValue])
    }

    func skipOnboarding() {
        completeOnboarding()
        DeskJigLog.info(.app, "SimpleOnboarding: Skipped onboarding")
    }

    /// Close button (X). Records completion before hiding, because the settings
    /// window's onboarding gate re-presents the overlay whenever it drops while
    /// `isCompleted` is still false.
    func dismissOnboarding() {
        completeOnboarding()
        DeskJigLog.info(.app, "SimpleOnboarding: Dismissed onboarding via close button")
    }

    // MARK: - State

    var canGoBack: Bool {
        currentStage.previous != nil
    }

    var isLastStage: Bool {
        currentStage.isLast
    }

    // MARK: - Private Helpers

    private func markCompleted() {
        userDefaults.set(true, forKey: persistenceKey)
        isCompleted = true
        progressStore.markSimpleOnboardingCompleted()
    }

    private func resetProgress() {
        userDefaults.removeObject(forKey: persistenceKey)
        // Keep the adoption flag set: a DEBUG reset must survive relaunch, and an
        // unset flag would let the legacy per-user copy re-complete onboarding.
        userDefaults.set(true, forKey: LegacyStoreAdoption.onboardingAdoptionCompletedKey)
        isCompleted = false
        DeskJigLog.info(.app, "SimpleOnboarding: Reset onboarding progress")
    }

    private func setupObservers() {
        NotificationCenter.default.publisher(for: Self.progressResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resetProgress()
            }
            .store(in: &cancellables)
    }

#if DEBUG
    func setDebugPermissionsJumpContext(
        isEnabled: Bool,
        isCurrentSessionNewUser: Bool,
        forcePermissionsSetupUI: Bool
    ) {
        debugStartAtPermissionsForNewUsersEnabled = isEnabled
        debugCurrentSessionIsNewUser = isCurrentSessionNewUser
        debugForcePermissionsSetupUI = forcePermissionsSetupUI
    }

    var shouldForcePermissionsSetupUIInDebug: Bool {
        debugForcePermissionsSetupUI
    }

    private func shouldStartAtPermissionsForDebug(entryPoint: StartEntryPoint) -> Bool {
        switch entryPoint {
        case .automaticPresentation:
            break
        case .manualLaunch:
            return false
        }
        guard debugStartAtPermissionsForNewUsersEnabled else { return false }
        guard debugCurrentSessionIsNewUser else { return false }
        guard !isCompleted else { return false }
        return !userDefaults.bool(forKey: debugPermissionsJumpConsumedKey)
    }

    private func markDebugPermissionsJumpConsumed() {
        userDefaults.set(true, forKey: debugPermissionsJumpConsumedKey)
        DeskJigLog.info(.app, "SimpleOnboarding: Marked DEBUG permissions jump as consumed for current session")
    }
#else
    var shouldForcePermissionsSetupUIInDebug: Bool {
        false
    }
#endif
}

// MARK: - Stage Definition

extension SimpleOnboardingViewModel {

    enum Stage: String, CaseIterable, Identifiable {
        case intro
        case menuBar
        case movingWindows
        case zones
        case tidyUp
        case savingWorkspaces
        case permissions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .intro: "Welcome to DeskJig"
            case .menuBar: "DeskJig's Menu Bar is Always Available"
            case .movingWindows: "Arrange your Apps with a Single Click"
            case .zones: "Use Zones to Snap Windows into Place"
            case .tidyUp: "Tidy Up Your Desktop to Keep Things Neat."
            case .savingWorkspaces: "Save your workspace and bring it back in 1 click"
            case .permissions: "Enable Accessibility"
            }
        }

        var description: String {
            switch self {
            case .intro:
                "DeskJig is the missing desktop manager for macOS. Save layouts with specific apps so you can jump into work. You'll always have the right apps at the right time, in the right place."
            case .menuBar:
                "You'll find it in the bottom right corner of your screen. If you have your dock bar set to not hide, it might be behind it. You can right-click on the dock to turn on auto-hiding."
            case .movingWindows:
                "Hover over the \"Move Windows\" button to access different options and snap windows into place."
            case .zones:
                "Drag any app on your screen to the top of the window and then select a zone to snap the window into place."
            case .tidyUp:
                "Tidy up arranges all your windows into groups so you can find hidden windows and bring order to desktop chaos."
            case .savingWorkspaces:
                "Click \"Create New\" to save your layouts.\n\nRestore a saved layout instantly from \"Workspace.\" You can always edit or delete a workspace later."
            case .permissions:
                "DeskJig needs accessibility permissions to move and arrange your windows. Click the button below to enable access."
            }
        }

        var step: Int {
            switch self {
            case .intro: 0
            case .menuBar: 1
            case .movingWindows: 2
            case .zones: 3
            case .tidyUp: 4
            case .savingWorkspaces: 5
            case .permissions: 6
            }
        }

        static let first: Stage = .intro

        var previous: Stage? {
            switch self {
            case .intro: nil
            case .menuBar: .intro
            case .movingWindows: .menuBar
            case .zones: .movingWindows
            case .tidyUp: .zones
            case .savingWorkspaces: .tidyUp
            case .permissions: .savingWorkspaces
            }
        }

        var next: Stage? {
            switch self {
            case .intro: .menuBar
            case .menuBar: .movingWindows
            case .movingWindows: .zones
            case .zones: .tidyUp
            case .tidyUp: .savingWorkspaces
            case .savingWorkspaces: .permissions
            case .permissions: nil
            }
        }

        var isLast: Bool { next == nil }
    }
}
