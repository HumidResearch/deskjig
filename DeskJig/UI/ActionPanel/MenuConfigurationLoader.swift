//  MenuConfigurationLoader.swift
//  DeskJig

//  Loads menu configurations from bundled JSON files
//

import Foundation
import DeskJigShared

/// Responsible for loading menu configurations from bundled JSON files
class MenuConfigurationLoader {

    // MARK: - Loading

    /// Load configuration from bundled JSON file
    static func loadBundled(filename: String) throws -> MenuConfiguration {
        guard let url = Bundle.main.url(forResource: filename, withExtension: "json") else {
            DeskJigLog.error(.app, "Menu configuration file not found in bundle", fields: ["filename": "\(filename).json"])
            throw LoaderError.fileNotFound(filename)
        }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let config = try decoder.decode(MenuConfiguration.self, from: data)
            
            DeskJigLog.info(.app, "Loaded menu configuration", fields: ["filename": "\(filename).json"])
            return config
        } catch {
            DeskJigLog.error(.app, "Error loading menu configuration", fields: ["filename": "\(filename).json", "error": error.localizedDescription])
            throw error
        }
    }

    // MARK: - Validation

    /// Validates a configuration for correctness
    static func validate(_ config: MenuConfiguration) throws {
        // Check for duplicate IDs
        var seenIDs = Set<String>()
        try validateUniqueIDs(items: config.rootItems, seenIDs: &seenIDs)

        // Check for valid actions
        try validateActions(items: config.rootItems)

        // Check for orphaned dynamic items
        try validateDynamicItems(items: config.rootItems)

        DeskJigLog.info(.app, "Menu configuration validated successfully")
    }

    private static func validateUniqueIDs(items: [MenuItem], seenIDs: inout Set<String>) throws {
        for item in items {
            if seenIDs.contains(item.id) {
                throw LoaderError.duplicateID(item.id)
            }
            seenIDs.insert(item.id)

            if let children = item.children {
                try validateUniqueIDs(items: children, seenIDs: &seenIDs)
            }
        }
    }

    private static func validateActions(items: [MenuItem]) throws {
        for item in items {
            if item.type == .leaf && item.action == nil {
                throw LoaderError.leafWithoutAction(item.id)
            }

            if item.type == .branch && item.action != nil {
                DeskJigLog.warn(.app, "Branch item has action defined but won't be used", fields: ["id": item.id])
            }

            if let children = item.children {
                try validateActions(items: children)
            }
        }
    }

    private static func validateDynamicItems(items: [MenuItem]) throws {
        for item in items {
            if item.type == .dynamic && item.children != nil && !item.children!.isEmpty {
                DeskJigLog.warn(.app, "Dynamic item has static children which will be replaced", fields: ["id": item.id])
            }

            if let children = item.children {
                try validateDynamicItems(items: children)
            }
        }
    }

    // MARK: - Migration

    /// Migrates old configuration to new version
    static func migrate(_ config: MenuConfiguration, to version: String) throws -> MenuConfiguration {
        // Handle version migrations
        switch (config.version, version) {
        case ("1.0", "2.0"):
            // Example migration logic
            DeskJigLog.info(.app, "Migrating configuration from 1.0 to 2.0")
            return MenuConfiguration(
                version: "2.0",
                rootItems: config.rootItems,
                settings: config.settings
            )
        default:
            return config
        }
    }

    // MARK: - Errors
    enum LoaderError: LocalizedError {
        case fileNotFound(String)
        case notFoundInUserDefaults(String)
        case duplicateID(String)
        case leafWithoutAction(String)
        case invalidConfiguration(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let filename):
                return "Configuration file not found: \(filename)"
            case .notFoundInUserDefaults(let key):
                return "Configuration not found in UserDefaults: \(key)"
            case .duplicateID(let id):
                return "Duplicate menu item ID: \(id)"
            case .leafWithoutAction(let id):
                return "Leaf item without action: \(id)"
            case .invalidConfiguration(let reason):
                return "Invalid configuration: \(reason)"
            }
        }
    }
}
