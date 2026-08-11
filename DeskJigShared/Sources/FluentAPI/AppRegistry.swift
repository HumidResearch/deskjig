//  AppRegistry.swift
//  DeskJigShared

import Foundation

/// Registration entry for an app alias
public struct AppRegistration {
    /// The primary bundle identifier
    public let bundleID: String
    
    /// Alternative bundle identifiers (for apps with multiple variants)
    public let alternateBundleIDs: [String]
    
    /// All bundle IDs (primary + alternates)
    public var allBundleIDs: [String] {
        return [bundleID] + alternateBundleIDs
    }
    
    public init(bundleID: String, alternateBundleIDs: [String] = []) {
        self.bundleID = bundleID
        self.alternateBundleIDs = alternateBundleIDs
    }
}

/// Registry that maps app aliases to bundle identifiers.
///
/// Register aliases for quick access:
/// ```swift
/// App.register("Figma", bundleID: "com.figma.Desktop")
/// App.register("Chrome", bundleID: "com.google.Chrome", alternateBundleIDs: ["com.google.Chrome.canary"])
///
/// // Then use as:
/// App.Figma?.firstWindow()?.minimize()
/// App.Chrome?.firstWindow()?.center()  // Works with any Chrome variant
/// ```
public final class AppRegistry {
    
    /// Shared singleton instance
    public static let shared = AppRegistry()
    
    /// Maps alias names to app registrations
    private var registrations: [String: AppRegistration] = [:]
    
    /// Thread-safe access queue
    private let queue = DispatchQueue(label: "com.deskjig.appRegistry", attributes: .concurrent)
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Registration
    
    /// Registers an alias for a bundle identifier.
    ///
    /// - Parameters:
    ///   - alias: The friendly name (e.g., "Figma", "Chrome")
    ///   - bundleID: The primary bundle identifier (e.g., "com.figma.Desktop")
    ///   - alternateBundleIDs: Alternative bundle IDs (e.g., for Chrome variants)
    public func register(_ alias: String, bundleID: String, alternateBundleIDs: [String] = []) {
        let registration = AppRegistration(bundleID: bundleID, alternateBundleIDs: alternateBundleIDs)
        queue.async(flags: .barrier) {
            self.registrations[alias] = registration
        }
    }
    
    /// Unregisters an alias.
    ///
    /// - Parameter alias: The alias to remove
    public func unregister(_ alias: String) {
        queue.async(flags: .barrier) {
            self.registrations.removeValue(forKey: alias)
        }
    }
    
    /// Clears all registered aliases.
    public func clearAll() {
        queue.async(flags: .barrier) {
            self.registrations.removeAll()
        }
    }
    
    // MARK: - Lookup
    
    /// Returns the registration for a given alias.
    ///
    /// - Parameter alias: The alias to look up
    /// - Returns: The registration, or nil if not registered
    public func registration(for alias: String) -> AppRegistration? {
        return queue.sync {
            return registrations[alias]
        }
    }
    
    /// Returns the primary bundle identifier for a given alias.
    ///
    /// - Parameter alias: The alias to look up
    /// - Returns: The primary bundle identifier, or nil if not registered
    public func bundleID(for alias: String) -> String? {
        return queue.sync {
            return registrations[alias]?.bundleID
        }
    }
    
    /// Returns all bundle IDs (primary + alternates) for a given alias.
    ///
    /// - Parameter alias: The alias to look up
    /// - Returns: All bundle IDs, or empty array if not registered
    public func allBundleIDs(for alias: String) -> [String] {
        return queue.sync {
            return registrations[alias]?.allBundleIDs ?? []
        }
    }
    
    /// Returns all registered aliases and their registrations.
    ///
    /// - Returns: Dictionary of alias -> registration
    public func allRegistrations() -> [String: AppRegistration] {
        return queue.sync {
            return registrations
        }
    }
    
    /// Returns the number of registered aliases.
    public var count: Int {
        return queue.sync {
            return registrations.count
        }
    }
    
    /// Checks if an alias is registered.
    ///
    /// - Parameter alias: The alias to check
    /// - Returns: True if the alias is registered
    public func isRegistered(_ alias: String) -> Bool {
        return queue.sync {
            return registrations[alias] != nil
        }
    }
}
