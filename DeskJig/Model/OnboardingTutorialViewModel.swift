//  OnboardingTutorialViewModel.swift
//  DeskJig
//
//  Created by Jake Sax on 10/16/25.
//

import SwiftUI
import Combine
import DeskJigShared
import KeyboardShortcuts
import OrderedCollections

@MainActor @Observable
final class OnboardingTutorialViewModel {

    // MARK: - Published State

    var isPresented: Bool = false
    private(set) var activeStage: Stage?
    private(set) var activeMovementSubstage: MovementSubstage = .leftRight
    private(set) var completedStages: OrderedSet<Stage> = []
    private(set) var simulationState: SimulationState = .init(
        normalizedFrame: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
    )
    private(set) var leftRightActions: Set<WindowMovementAction> = []
    private(set) var upDownActions: Set<WindowMovementAction> = []
    private(set) var didMaximize = false
    private(set) var didCenter = false

    // MARK: - Configuration

    private static let basePersistenceKey = "OnboardingTutorial.Progress"
    static let progressResetNotification = Notification.Name("OnboardingTutorial.ProgressReset")

    private let userDefaults: UserDefaults
    private let progressStore: TutorialProgressStore
    private let horizontalCycle: [CGFloat] = [1 / 3, 2 / 3, 1 / 2]
    private let verticalCycle: [CGFloat] = [1 / 3, 2 / 3, 1 / 2]
    private var horizontalIndex: Int = 0
    private var verticalIndex: Int = 0
    private var shortcutTasks: [KeyboardShortcuts.Name: Task<Void, Never>] = [:]
    private var pendingSimulatedActions: Set<WindowMovementAction> = []
    private var ignoredWindowActions: Set<WindowMovementAction> = []
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(userDefaults: UserDefaults = .standard, progressStore: TutorialProgressStore = .shared) {
        self.userDefaults = userDefaults
        self.progressStore = progressStore
        loadProgress()
        setupObservers()
    }

    // MARK: - Persistence Key

    private var persistenceKey: String {
        Self.basePersistenceKey
    }

    // MARK: - Entry Points
    func presentIfIncomplete() {
        guard !isPresented else {
            DeskJigLog.info(.onboarding, "OnboardingTutorial: Will not present, already presented")
            return
        }
        guard !isTutorialCompleted else {
            DeskJigLog.info(.onboarding, "OnboardingTutorial: Will not present, already complete")
            return
        }
        let nextStage: Stage?
        if completedStages.isEmpty {
            nextStage = .first
        } else {
            nextStage = completedStages.last?.next
        }
        guard let nextStage else {
            DeskJigLog.info(.onboarding, "OnboardingTutorial: Will not present, no next stage, should be complete")
            return
        }
        startTutorial(stage: nextStage)
    }

    func startTutorial(stage: Stage) {
        activeStage = stage
        isPresented = true

        DeskJigLog.info(.onboarding, "OnboardingTutorial: Starting tutorial stage: \(stage.title)")
        switch stage {
        case .launchHotkey:
            stopListeningForShortcuts()
        case .basics:
            stopListeningForShortcuts()
        case .hotkeys:
            stopListeningForShortcuts()
        case .movement:
            resetMovementState()
            startListeningForShortcuts()
        }
    }

    func closeTutorial() {
        isPresented = false
        activeStage = nil
        stopListeningForShortcuts()
    }

    func didExitTutorial() {
        activeStage = nil
        stopListeningForShortcuts()
        completedStages = .init(Stage.allCases)
        saveProgress()
    }

    func advanceStage() {
        guard let stage = activeStage else { return }

        markStageCompleted(stage)
        guard let nextStage = stage.next else {
            closeTutorial()
            return
        }
        startTutorial(stage: nextStage)
    }

    func advanceMovementSubstage() {
        guard let currentIndex = MovementSubstage.allCases.firstIndex(of: activeMovementSubstage) else {
            return
        }

        let nextIndex = MovementSubstage.allCases.index(after: currentIndex)

        if nextIndex < MovementSubstage.allCases.endIndex {
            activeMovementSubstage = MovementSubstage.allCases[nextIndex]
            resetMovementStateForCurrentSubstage()
        } else {
            advanceStage()
        }
    }

    func isStageCompleted(_ stage: Stage) -> Bool {
        completedStages.contains(stage)
    }

    var isTutorialCompleted: Bool {
        completedStages.count == Stage.allCases.count
    }

    /// Returns whether the current stage/substage has met its completion requirements.
    var canAdvanceCurrentStage: Bool {
        canAdvanceFromCurrentStage()
    }

    /// Label for the shortcut the user should press next when practicing movement.
    var currentShortcutLabel: String? {
        guard let action = nextRequiredAction(), let shortcut = shortcutName(for: action).shortcut else {
            return nil
        }
        return shortcut.description
    }

    func canAdvanceFromCurrentStage() -> Bool {
        guard let stage = activeStage else { return false }

        return switch stage {
        case .launchHotkey: true
        case .basics: true
        case .hotkeys: areRequiredHotkeysSet
        case .movement:
            switch activeMovementSubstage {
            case .leftRight: leftRightActions.contains(.left) && leftRightActions.contains(.right)
            case .upDown: upDownActions.contains(.up) && upDownActions.contains(.down)
            case .maximize: didMaximize
            case .center: didCenter
            }
        }
    }

    /// Returns true if all required hotkeys for the movement tutorial are set
    var areRequiredHotkeysSet: Bool {
        KeyboardShortcuts.Name.moveWindowLeft.shortcut != nil &&
        KeyboardShortcuts.Name.moveWindowRight.shortcut != nil &&
        KeyboardShortcuts.Name.moveWindowUp.shortcut != nil &&
        KeyboardShortcuts.Name.moveWindowDown.shortcut != nil &&
        KeyboardShortcuts.Name.maximizeWindow.shortcut != nil &&
        KeyboardShortcuts.Name.centerWindow.shortcut != nil
    }

    /// Returns the list of hotkeys that are not set
    var missingHotkeys: [KeyboardShortcuts.Name] {
        var missing: [KeyboardShortcuts.Name] = []
        if KeyboardShortcuts.Name.moveWindowLeft.shortcut == nil { missing.append(.moveWindowLeft) }
        if KeyboardShortcuts.Name.moveWindowRight.shortcut == nil { missing.append(.moveWindowRight) }
        if KeyboardShortcuts.Name.moveWindowUp.shortcut == nil { missing.append(.moveWindowUp) }
        if KeyboardShortcuts.Name.moveWindowDown.shortcut == nil { missing.append(.moveWindowDown) }
        if KeyboardShortcuts.Name.maximizeWindow.shortcut == nil { missing.append(.maximizeWindow) }
        if KeyboardShortcuts.Name.centerWindow.shortcut == nil { missing.append(.centerWindow) }
        return missing
    }

    private func nextRequiredAction() -> WindowMovementAction? {
        guard activeStage == .movement else { return nil }
        switch activeMovementSubstage {
        case .leftRight:
            if !leftRightActions.contains(.left) { return .left }
            if !leftRightActions.contains(.right) { return .right }
            return nil
        case .upDown:
            if !upDownActions.contains(.up) { return .up }
            if !upDownActions.contains(.down) { return .down }
            return nil
        case .maximize:
            return didMaximize ? nil : .maximize
        case .center:
            return didCenter ? nil : .center
        }
    }

    // MARK: - Private Helpers

    private func markStageCompleted(_ stage: Stage) {
        completedStages.append(stage)
        saveProgress()
    }

    private func setupObservers() {
        NotificationCenter.default.publisher(for: Self.progressResetNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyExternalReset()
            }
            .store(in: &cancellables)
    }

    private func resetMovementState() {
        DeskJigLog.info(.onboarding, "OnboardingTutorial: Resetting movement state")
        horizontalIndex = 0
        verticalIndex = 0
        leftRightActions = []
        upDownActions = []
        didMaximize = false
        didCenter = false
        activeMovementSubstage = .leftRight
        simulationState = .init(normalizedFrame: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        resetMovementStateForCurrentSubstage()
        ignoredWindowActions.removeAll()
        pendingSimulatedActions.removeAll()
    }

    private func resetMovementStateForCurrentSubstage() {
        switch activeMovementSubstage {
        case .leftRight:
            horizontalIndex = 0
            leftRightActions = []
            simulationState = .init(normalizedFrame: CGRect(x: 0.35, y: 0, width: 0.3, height: 1))
        case .upDown:
            verticalIndex = 0
            upDownActions = []
            simulationState = .init(normalizedFrame: CGRect(x: 0, y: 0.35, width: 1, height: 0.3))
        case .maximize:
            simulationState = .init(normalizedFrame: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        case .center:
            simulationState = .init(normalizedFrame: CGRect(x: 0.025, y: 0.475, width: 0.5, height: 0.5))
        }
    }

    private func applyHorizontalMove(direction: WindowMovementAction) {
        guard direction == .left || direction == .right else { return }

        let width = horizontalCycle[horizontalIndex]
        horizontalIndex = (horizontalIndex + 1) % horizontalCycle.count

        let x: CGFloat = direction == .left ? 0 : (1 - width)
        simulationState = .init(
            normalizedFrame: CGRect(
                x: x,
                y: 0,
                width: width,
                height: 1
            )
        )

        leftRightActions.insert(direction)
    }

    private func applyVerticalMove(direction: WindowMovementAction) {
        guard direction == .up || direction == .down else { return }

        let height = verticalCycle[verticalIndex]
        verticalIndex = (verticalIndex + 1) % verticalCycle.count

        let y: CGFloat = direction == .up ? 0 : (1 - height)

        simulationState = .init(
            normalizedFrame: CGRect(
                x: 0,
                y: y,
                width: 1,
                height: height
            )
        )

        upDownActions.insert(direction)
    }

    private func applyMaximize() {
        simulationState = .init(normalizedFrame: CGRect(x: 0, y: 0, width: 1, height: 1))
        didMaximize = true
    }

    private func applyCenter() {
        simulationState = .init(normalizedFrame: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        didCenter = true
    }

    private func startListeningForShortcuts() {
        stopListeningForShortcuts()

        shortcutTasks = [
            .moveWindowLeft: makeShortcutTask(for: .moveWindowLeft, action: .left),
            .moveWindowRight: makeShortcutTask(for: .moveWindowRight, action: .right),
            .moveWindowUp: makeShortcutTask(for: .moveWindowUp, action: .up),
            .moveWindowDown: makeShortcutTask(for: .moveWindowDown, action: .down),
            .maximizeWindow: makeShortcutTask(for: .maximizeWindow, action: .maximize),
            .centerWindow: makeShortcutTask(for: .centerWindow, action: .center)
        ]
    }

    private func stopListeningForShortcuts() {
        shortcutTasks.values.forEach { $0.cancel() }
        shortcutTasks.removeAll()
        ignoredWindowActions.removeAll()
        pendingSimulatedActions.removeAll()
    }

    private func makeShortcutTask(
        for name: KeyboardShortcuts.Name,
        action: WindowMovementAction
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await _ in KeyboardShortcuts.events(.keyUp, for: name) {
                guard !Task.isCancelled else { break }
                guard let self else { continue }
                self.simulateShortcut(for: action)
            }
        }
    }

    private func simulateShortcut(for action: WindowMovementAction) {
        guard isPresented else { return }
        pendingSimulatedActions.insert(action)
        ignoredWindowActions.insert(action)
        _ = handleMovementAction(action)
        pendingSimulatedActions.remove(action)
    }

    private func shortcutName(for action: WindowMovementAction) -> KeyboardShortcuts.Name {
        switch action {
        case .left: .moveWindowLeft
        case .right: .moveWindowRight
        case .up: .moveWindowUp
        case .down: .moveWindowDown
        case .center: .centerWindow
        case .maximize: .maximizeWindow
        }
    }

    private func saveProgress() {
        saveProgressLocally()

        for stage in completedStages {
            progressStore.markOnboardingStageCompleted(stage.rawValue)
        }

        if isTutorialCompleted {
            progressStore.markOnboardingTutorialFullyCompleted()
        }
    }

    /// Saves progress to local UserDefaults.
    private func saveProgressLocally() {
        let data = Persistence(completedStages: completedStages)
        do {
            let encoded = try JSONEncoder().encode(data)
            userDefaults.set(encoded, forKey: persistenceKey)
        } catch {
            DeskJigLog.error(.onboarding, "OnboardingTutorial: Error encoding tutorial progress: \(error)")
        }
    }

    private func loadProgress() {
        guard let data = userDefaults.data(forKey: persistenceKey) else {
            // No progress yet - expected for new users
            return
        }
        do {
            let decoded = try JSONDecoder().decode(Persistence.self, from: data)
            completedStages = decoded.completedStages
            DeskJigLog.info(.onboarding, "OnboardingTutorial: Completed tutorial stages: \(self.completedStages.map(\.title).joined(separator: ", "))")
        } catch {
            DeskJigLog.info(.onboarding, "OnboardingTutorial: Error decoding tutorial progress: \(error)")
            completedStages = []
        }
    }

    func resetProgress() {
        DeskJigLog.info(.onboarding, "OnboardingTutorial: Resetting progress")
        completedStages.removeAll()
        userDefaults.removeObject(forKey: persistenceKey)
    }

    private func applyExternalReset() {
        DeskJigLog.info(.onboarding, "OnboardingTutorial: Applying external reset")
        resetProgress()
    }

    func handleMovementAction(_ action: WindowMovementAction) -> Bool {
        DeskJigLog.info(.onboarding, "OnboardingTutorial: Handling movement action: \(action.rawValue)")
        guard isPresented else {
            return false
        }

        guard let stage = activeStage else {
            return true
        }

        if ignoredWindowActions.contains(action), !pendingSimulatedActions.contains(action) {
            ignoredWindowActions.remove(action)
            return true
        }

        switch stage {
        case .launchHotkey, .basics, .hotkeys:
            return true
        case .movement:
            switch activeMovementSubstage {
            case .leftRight:
                applyHorizontalMove(direction: action)
            case .upDown:
                applyVerticalMove(direction: action)
            case .maximize:
                if action == .maximize {
                    applyMaximize()
                }
            case .center:
                if action == .center {
                    applyCenter()
                }
            }
            return true
        }
    }

    /// Attempts to advance to the next tutorial step once completion criteria are met.
    /// - Returns: `true` if the step advanced, otherwise `false`.
    @discardableResult
    func proceedToNextStepIfPossible() -> Bool {
        guard let stage = activeStage, canAdvanceFromCurrentStage() else {
            return false
        }

        switch stage {
        case .launchHotkey, .basics, .hotkeys: advanceStage()
        case .movement: advanceMovementSubstage()
        }

        return true
    }
}



extension OnboardingTutorialViewModel {

    enum Stage: String, CaseIterable, Identifiable, Codable {
        case launchHotkey
        case basics
        case hotkeys
        case movement

        var id: String { rawValue }

        var title: String {
            switch self {
            case .launchHotkey: "Launching DeskJig"
            case .basics: "Basics"
            case .hotkeys: "Hotkeys"
            case .movement: "Movement"
            }
        }

        /// The order in which the stages should be stepped through
        var step: Int {
            switch self {
            case .launchHotkey: 0
            case .basics: 1
            case .hotkeys: 2
            case .movement: 3
            }
        }

        static let first: Stage = .launchHotkey

        var previous: Stage? {
            switch self {
            case .launchHotkey: nil
            case .basics: .launchHotkey
            case .hotkeys: .basics
            case .movement: .hotkeys
            }
        }

        var next: Stage? {
            switch self {
            case .launchHotkey: .basics
            case .basics: .hotkeys
            case .hotkeys: .movement
            case .movement: nil
            }
        }

        var isLast: Bool { next == nil }

    }

    enum MovementSubstage: String, CaseIterable, Identifiable {
        case leftRight
        case upDown
        case maximize
        case center

        var id: String { rawValue }

        var title: String {
            switch self {
            case .leftRight: "Left & Right"
            case .upDown: "Up & Down"
            case .maximize: "Maximize"
            case .center: "Center"
            }
        }
    }

    struct SimulationState: Hashable {
        var normalizedFrame: CGRect
    }

    private struct Persistence: Codable {
        let completedStages: OrderedSet<Stage>
    }

    enum WindowMovementAction: String, Hashable, Sendable {
        case left, right, up, down, center, maximize
    }
}
