//
//  PerUserDefaultsManager.swift
//  DeskJigShared
//
//  Created by AI on 1/5/26.
//

import Foundation

/// Provides typed access to local `UserDefaults` settings.
public final class PerUserDefaultsManager {

    /// Shared singleton instance
    public static let shared = PerUserDefaultsManager()

    /// UserDefaults instance (injectable for testing)
    private let userDefaults: UserDefaults

    // MARK: - Initialization

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    // MARK: - Key Generation

    /// Returns the local storage key for a setting.
    /// - Parameter setting: The base setting key
    public func key(for setting: String) -> String {
        setting
    }

    // MARK: - Typed Accessors

    /// Gets a boolean value for the given setting
    public func bool(forKey setting: String, defaultValue: Bool = false) -> Bool {
        let storageKey = key(for: setting)
        if userDefaults.object(forKey: storageKey) != nil {
            return userDefaults.bool(forKey: storageKey)
        }
        return defaultValue
    }

    /// Sets a boolean value for the given setting
    public func set(_ value: Bool, forKey setting: String) {
        let storageKey = key(for: setting)
        userDefaults.set(value, forKey: storageKey)
    }

    /// Gets a double value for the given setting
    public func double(forKey setting: String, defaultValue: Double = 0.0) -> Double {
        let storageKey = key(for: setting)
        if userDefaults.object(forKey: storageKey) != nil {
            return userDefaults.double(forKey: storageKey)
        }
        return defaultValue
    }

    /// Sets a double value for the given setting
    public func set(_ value: Double, forKey setting: String) {
        let storageKey = key(for: setting)
        userDefaults.set(value, forKey: storageKey)
    }

    /// Gets a string value for the given setting
    public func string(forKey setting: String) -> String? {
        let storageKey = key(for: setting)
        return userDefaults.string(forKey: storageKey)
    }

    /// Sets a string value for the given setting
    public func set(_ value: String?, forKey setting: String) {
        let storageKey = key(for: setting)
        userDefaults.set(value, forKey: storageKey)
    }

    /// Gets an integer value for the given setting
    public func integer(forKey setting: String, defaultValue: Int = 0) -> Int {
        let storageKey = key(for: setting)
        if userDefaults.object(forKey: storageKey) != nil {
            return userDefaults.integer(forKey: storageKey)
        }
        return defaultValue
    }

    /// Sets an integer value for the given setting
    public func set(_ value: Int, forKey setting: String) {
        let storageKey = key(for: setting)
        userDefaults.set(value, forKey: storageKey)
    }

    /// Gets data for the given setting
    public func data(forKey setting: String) -> Data? {
        let storageKey = key(for: setting)
        return userDefaults.data(forKey: storageKey)
    }

    /// Sets data for the given setting
    public func set(_ value: Data?, forKey setting: String) {
        let storageKey = key(for: setting)
        userDefaults.set(value, forKey: storageKey)
    }

    /// Gets any object for the given setting
    public func object(forKey setting: String) -> Any? {
        let storageKey = key(for: setting)
        return userDefaults.object(forKey: storageKey)
    }

    /// Sets any object for the given setting
    public func set(_ value: Any?, forKey setting: String) {
        let storageKey = key(for: setting)
        userDefaults.set(value, forKey: storageKey)
    }

    /// Removes the value for the given setting
    public func removeObject(forKey setting: String) {
        let storageKey = key(for: setting)
        userDefaults.removeObject(forKey: storageKey)
    }

    // MARK: - Codable Support

    /// Encodes and stores a Codable value
    public func setCodable<T: Encodable>(_ value: T, forKey setting: String) {
        do {
            let data = try JSONEncoder().encode(value)
            set(data, forKey: setting)
        } catch {
            DeskJigLog.error(.app, "PerUserDefaultsManager: Failed to encode \(setting): \(error)")
        }
    }

    /// Decodes and retrieves a Codable value
    public func codable<T: Decodable>(forKey setting: String, as type: T.Type) -> T? {
        guard let data = data(forKey: setting) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            DeskJigLog.error(.app, "PerUserDefaultsManager: Failed to decode \(setting): \(error)")
            return nil
        }
    }
}
