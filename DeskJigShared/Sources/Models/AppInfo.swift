//  AppInfo.swift
//  DeskJigShared

import Foundation

public struct AppInfo: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let name: String
    public let bundleIdentifier: String?
    public let path: String
    public let icon: NSImage?

    public init(name: String, bundleIdentifier: String?, path: String, icon: NSImage?) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.icon = icon
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(path)
    }

    public static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        lhs.path == rhs.path
    }
}
