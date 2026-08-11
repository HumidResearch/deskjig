//
//  URLHandoffAnimationPreferences.swift
//  DeskJig
//

import Foundation
import DeskJigShared

enum URLHandoffAnimationPreset: String, CaseIterable, Identifiable {
    case standardCubic
    case smoothCubic
    case classicEase
    case linear

    var id: String { rawValue }

    var settingsLabel: String {
        switch self {
        case .standardCubic:
            return "Standard Cubic"
        case .smoothCubic:
            return "Smooth Cubic"
        case .classicEase:
            return "Classic Ease"
        case .linear:
            return "Linear"
        }
    }
}

struct URLHandoffAnimationProfile: Sendable {
    let slideInOptions: WindowAnimationOptions
    let slideOutOptions: WindowAnimationOptions
    let returnOptions: WindowAnimationOptions
}

enum URLHandoffAnimationPreferences {
    static let storageKey = "urlHandoff.animationPreset"
    static let defaultPreset: URLHandoffAnimationPreset = .standardCubic

    static func currentPreset(userDefaults: UserDefaults = .standard) -> URLHandoffAnimationPreset {
        guard let raw = userDefaults.string(forKey: storageKey),
              let preset = URLHandoffAnimationPreset(rawValue: raw) else {
            return defaultPreset
        }
        return preset
    }

    static func currentProfile(userDefaults: UserDefaults = .standard) -> URLHandoffAnimationProfile {
        profile(for: currentPreset(userDefaults: userDefaults))
    }

    static func profile(for preset: URLHandoffAnimationPreset) -> URLHandoffAnimationProfile {
        switch preset {
        case .standardCubic:
            return URLHandoffAnimationProfile(
                slideInOptions: WindowAnimationOptions(duration: 0.30, easing: .easeOutCubic),
                slideOutOptions: WindowAnimationOptions(duration: 0.20, easing: .easeInCubic),
                returnOptions: WindowAnimationOptions(duration: 0.40, easing: .easeOutCubic)
            )

        case .smoothCubic:
            return URLHandoffAnimationProfile(
                slideInOptions: WindowAnimationOptions(duration: 0.45, easing: .easeOutCubic),
                slideOutOptions: WindowAnimationOptions(duration: 0.30, easing: .easeInCubic),
                returnOptions: WindowAnimationOptions(duration: 0.55, easing: .easeOutCubic)
            )

        case .classicEase:
            return URLHandoffAnimationProfile(
                slideInOptions: WindowAnimationOptions(duration: 0.35, easing: .easeOut),
                slideOutOptions: WindowAnimationOptions(duration: 0.25, easing: .easeIn),
                returnOptions: WindowAnimationOptions(duration: 0.45, easing: .easeOut)
            )

        case .linear:
            return URLHandoffAnimationProfile(
                slideInOptions: WindowAnimationOptions(duration: 0.35, easing: .linear),
                slideOutOptions: WindowAnimationOptions(duration: 0.25, easing: .linear),
                returnOptions: WindowAnimationOptions(duration: 0.45, easing: .linear)
            )
        }
    }
}
