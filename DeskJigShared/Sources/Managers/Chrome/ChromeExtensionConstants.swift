//  ChromeExtensionConstants.swift
//  DeskJigShared

import Foundation

/// Constants for Chrome extension configuration
public enum ChromeExtensionConstants {
    /// Native messaging host name (must match manifest)
    public static let nativeHostName = "com.bento.native"

    /// Chrome Web Store extension ID (production)
    /// Note: Update this when publishing to Chrome Web Store
    /// For unpacked extensions, this ID changes each time the extension is loaded from a different folder
    public static let productionExtensionId = "indaidlffmnblanhmmkhgbcioeaopank"

    /// UserDefaults key for storing development extension ID
    private static let developmentExtensionIdKey = "ChromeExtension.DevelopmentId"

    /// Development extension ID (stored when loaded unpacked)
    public static var developmentExtensionId: String? {
        get { UserDefaults.standard.string(forKey: developmentExtensionIdKey) }
        set { UserDefaults.standard.set(newValue, forKey: developmentExtensionIdKey) }
    }

    /// The active extension ID to use
    public static var extensionId: String {
        #if DEBUG
        return developmentExtensionId ?? productionExtensionId
        #else
        return productionExtensionId
        #endif
    }

    /// Native messaging socket path
    public static var socketPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("DeskJig/native-messaging.sock").path
    }

    /// Native host binary path (inside app bundle)
    public static var nativeHostBinaryPath: String {
        Bundle.main.bundlePath + "/Contents/MacOS/DeskJigNativeHost"
    }

    /// Chrome native messaging hosts directory
    public static func nativeMessagingHostsDirectory(for browser: ChromeBrowser) -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        switch browser {
        case .chrome:
            return "\(homeDir)/Library/Application Support/Google/Chrome/NativeMessagingHosts"
        case .chromeBeta:
            return "\(homeDir)/Library/Application Support/Google/Chrome Beta/NativeMessagingHosts"
        case .chromeCanary:
            return "\(homeDir)/Library/Application Support/Google/Chrome Canary/NativeMessagingHosts"
        case .chromium:
            return "\(homeDir)/Library/Application Support/Chromium/NativeMessagingHosts"
        case .brave:
            return "\(homeDir)/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts"
        case .edge:
            return "\(homeDir)/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
        }
    }

    /// Native host manifest path for a browser
    public static func nativeHostManifestPath(for browser: ChromeBrowser) -> String {
        "\(nativeMessagingHostsDirectory(for: browser))/\(nativeHostName).json"
    }

    /// Chrome Web Store URL for the extension
    public static let chromeWebStoreURL = URL(string: "https://chromewebstore.google.com/detail/\(productionExtensionId)")!

    /// Developer mode extension loading URL
    public static let developerModeURL = URL(string: "chrome://extensions")!
}

/// Supported Chromium-based browsers
public enum ChromeBrowser: String, CaseIterable, Identifiable {
    case chrome = "Google Chrome"
    case chromeBeta = "Google Chrome Beta"
    case chromeCanary = "Google Chrome Canary"
    case chromium = "Chromium"
    case brave = "Brave Browser"
    case edge = "Microsoft Edge"

    public var id: String { rawValue }

    /// Bundle identifier for the browser
    public var bundleId: String {
        switch self {
        case .chrome: return "com.google.Chrome"
        case .chromeBeta: return "com.google.Chrome.beta"
        case .chromeCanary: return "com.google.Chrome.canary"
        case .chromium: return "org.chromium.Chromium"
        case .brave: return "com.brave.Browser"
        case .edge: return "com.microsoft.edgemac"
        }
    }

    /// Application path
    public var applicationPath: String {
        "/Applications/\(rawValue).app"
    }

    /// Check if this browser is installed
    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: applicationPath)
    }

    /// Get all installed browsers
    public static var installedBrowsers: [ChromeBrowser] {
        allCases.filter { $0.isInstalled }
    }
}
