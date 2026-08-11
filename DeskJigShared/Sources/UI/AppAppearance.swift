//
//  AppAppearance.swift
//  DeskJigShared
//
//  Created by Codex on 02/03/26.
//

import SwiftUI

public enum AppTheme: String, Identifiable, Codable, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    case system
    case light
    case dark

    public var id: Self { self }

    public var description: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

public enum AppFontFamily: String, Identifiable, Codable, Hashable, Sendable, CaseIterable, CustomStringConvertible {
    case system

    public var id: Self { self }

    public var description: String {
        switch self {
        case .system: "SF Pro / Compact"
        }
    }
}
