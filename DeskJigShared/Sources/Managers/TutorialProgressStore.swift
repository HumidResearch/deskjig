//
//  TutorialProgressStore.swift
//  DeskJigShared
//

import Foundation

/// Locally persisted tutorial progress.
public struct TutorialProgress: Codable, Equatable, Sendable {
    public var simpleOnboardingCompleted: Bool
    public var simpleOnboardingCompletedAt: Date?
    public var onboardingTutorialStages: [String]
    public var onboardingTutorialCompletedAt: Date?
    public var chromeExtensionSetupCompleted: Bool
    public var chromeExtensionSetupCompletedAt: Date?

    public init(
        simpleOnboardingCompleted: Bool = false,
        simpleOnboardingCompletedAt: Date? = nil,
        onboardingTutorialStages: [String] = [],
        onboardingTutorialCompletedAt: Date? = nil,
        chromeExtensionSetupCompleted: Bool = false,
        chromeExtensionSetupCompletedAt: Date? = nil
    ) {
        self.simpleOnboardingCompleted = simpleOnboardingCompleted
        self.simpleOnboardingCompletedAt = simpleOnboardingCompletedAt
        self.onboardingTutorialStages = onboardingTutorialStages
        self.onboardingTutorialCompletedAt = onboardingTutorialCompletedAt
        self.chromeExtensionSetupCompleted = chromeExtensionSetupCompleted
        self.chromeExtensionSetupCompletedAt = chromeExtensionSetupCompletedAt
    }

    public static var empty: TutorialProgress {
        TutorialProgress()
    }

    /// Merges progress using union semantics so completed steps are never lost.
    public func merged(with other: TutorialProgress) -> TutorialProgress {
        let mergedSimpleCompleted = simpleOnboardingCompleted || other.simpleOnboardingCompleted
        let mergedSimpleCompletedAt: Date? = {
            switch (simpleOnboardingCompletedAt, other.simpleOnboardingCompletedAt) {
            case let (a?, b?): return min(a, b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            case (nil, nil): return mergedSimpleCompleted ? Date() : nil
            }
        }()

        let mergedStages = Array(Set(onboardingTutorialStages + other.onboardingTutorialStages))
        let mergedOnboardingCompletedAt: Date? = {
            switch (onboardingTutorialCompletedAt, other.onboardingTutorialCompletedAt) {
            case let (a?, b?): return min(a, b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            case (nil, nil): return nil
            }
        }()

        let mergedChromeCompleted = chromeExtensionSetupCompleted || other.chromeExtensionSetupCompleted
        let mergedChromeCompletedAt: Date? = {
            switch (chromeExtensionSetupCompletedAt, other.chromeExtensionSetupCompletedAt) {
            case let (a?, b?): return min(a, b)
            case let (a?, nil): return a
            case let (nil, b?): return b
            case (nil, nil): return mergedChromeCompleted ? Date() : nil
            }
        }()

        return TutorialProgress(
            simpleOnboardingCompleted: mergedSimpleCompleted,
            simpleOnboardingCompletedAt: mergedSimpleCompletedAt,
            onboardingTutorialStages: mergedStages,
            onboardingTutorialCompletedAt: mergedOnboardingCompletedAt,
            chromeExtensionSetupCompleted: mergedChromeCompleted,
            chromeExtensionSetupCompletedAt: mergedChromeCompletedAt
        )
    }
}

/// Stores tutorial progress locally with no account or network dependency.
public final class TutorialProgressStore {
    public static let shared = TutorialProgressStore()

    private static let progressKey = "tutorialProgress"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: BundleIdentity.defaultsSuiteName)
            ?? .standard
    }

    public func load() -> TutorialProgress {
        if let progress = decodeProgress(forKey: Self.progressKey) {
            return progress
        }

        let legacyProgress = defaults.dictionaryRepresentation().keys
            .filter { $0.hasSuffix(".\(Self.progressKey)") }
            .compactMap(decodeProgress(forKey:))
            .reduce(TutorialProgress.empty) { $0.merged(with: $1) }

        if legacyProgress != .empty {
            save(legacyProgress)
        }
        return legacyProgress
    }

    public func save(_ progress: TutorialProgress) {
        do {
            defaults.set(try JSONEncoder().encode(progress), forKey: Self.progressKey)
        } catch {
            DeskJigLog.error(.app, "TutorialProgressStore: Failed to encode progress: \(error)")
        }
    }

    public func clear() {
        defaults.removeObject(forKey: Self.progressKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasSuffix(".\(Self.progressKey)") {
            defaults.removeObject(forKey: key)
        }
    }

    public func markSimpleOnboardingCompleted(at date: Date = Date()) {
        var progress = load()
        progress.simpleOnboardingCompleted = true
        progress.simpleOnboardingCompletedAt = date
        save(progress)
    }

    public func markOnboardingStageCompleted(_ stage: String) {
        var progress = load()
        if !progress.onboardingTutorialStages.contains(stage) {
            progress.onboardingTutorialStages.append(stage)
        }
        save(progress)
    }

    public func markOnboardingTutorialFullyCompleted(at date: Date = Date()) {
        var progress = load()
        progress.onboardingTutorialCompletedAt = date
        save(progress)
    }

    public func markChromeExtensionSetupCompleted(at date: Date = Date()) {
        var progress = load()
        progress.chromeExtensionSetupCompleted = true
        progress.chromeExtensionSetupCompletedAt = date
        save(progress)
    }

    public func resetChromeExtensionSetup() {
        var progress = load()
        progress.chromeExtensionSetupCompleted = false
        progress.chromeExtensionSetupCompletedAt = nil
        save(progress)
    }

    private func decodeProgress(forKey key: String) -> TutorialProgress? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(TutorialProgress.self, from: data)
        } catch {
            DeskJigLog.error(.app, "TutorialProgressStore: Failed to decode progress for key '\(key)': \(error)")
            return nil
        }
    }
}
