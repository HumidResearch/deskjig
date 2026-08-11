//  SettingsPane.swift
//  DeskJigShared

import Foundation

/// Defines the System Preferences pane URLs
public enum SettingsPane: CaseIterable {
    case accessibility

    public var url: URL? {
        switch self {
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
}
