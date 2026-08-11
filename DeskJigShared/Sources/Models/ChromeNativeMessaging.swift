//  ChromeNativeMessaging.swift
//  DeskJigShared

import Foundation

// MARK: - Tab Events

/// Types of tab events received from the Chrome extension
public enum ChromeTabEventType: String, Codable, Hashable, Sendable {
    case created
    case removed
    case updated
    case activated
    case moved
    case attached
    case detached
}

/// A real-time tab event from the Chrome extension
public struct ChromeTabEvent: Codable, Hashable, Sendable {
    public let eventType: ChromeTabEventType
    public let tabId: Int
    public let windowId: Int
    public let url: String?
    public let title: String?
    public let index: Int?
    public let previousWindowId: Int?  // For attached/detached events
    public let timestamp: Date

    public init(
        eventType: ChromeTabEventType,
        tabId: Int,
        windowId: Int,
        url: String? = nil,
        title: String? = nil,
        index: Int? = nil,
        previousWindowId: Int? = nil,
        timestamp: Date = Date()
    ) {
        self.eventType = eventType
        self.tabId = tabId
        self.windowId = windowId
        self.url = url
        self.title = title
        self.index = index
        self.previousWindowId = previousWindowId
        self.timestamp = timestamp
    }
}

// MARK: - Window Events

/// Types of window events received from the Chrome extension
public enum ChromeWindowEventType: String, Codable, Hashable, Sendable {
    case created
    case removed
    case focusChanged
}

/// A real-time window event from the Chrome extension
public struct ChromeWindowEvent: Codable, Hashable, Sendable {
    public let eventType: ChromeWindowEventType
    public let windowId: Int
    public let focused: Bool?
    public let timestamp: Date

    public init(
        eventType: ChromeWindowEventType,
        windowId: Int,
        focused: Bool? = nil,
        timestamp: Date = Date()
    ) {
        self.eventType = eventType
        self.windowId = windowId
        self.focused = focused
        self.timestamp = timestamp
    }
}

// MARK: - Navigation Events

/// A navigation event from the Chrome extension (page load)
public struct ChromeNavigationEvent: Codable, Hashable, Sendable {
    public let tabId: Int
    public let windowId: Int
    public let url: String
    public let transitionType: String?
    public let timestamp: Date

    public init(
        tabId: Int,
        windowId: Int,
        url: String,
        transitionType: String? = nil,
        timestamp: Date = Date()
    ) {
        self.tabId = tabId
        self.windowId = windowId
        self.url = url
        self.transitionType = transitionType
        self.timestamp = timestamp
    }
}

// MARK: - Real-Time Tab State

/// A real-time snapshot of a Chrome tab from the native messaging extension
public struct ChromeRealTimeTab: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let windowId: Int
    public let index: Int
    public let url: String
    public let title: String
    public let active: Bool
    public let pinned: Bool
    public let audible: Bool?
    public let muted: Bool?
    public let groupId: Int?
    public let groupTitle: String?
    public let groupColor: String?

    public init(
        id: Int,
        windowId: Int,
        index: Int,
        url: String,
        title: String,
        active: Bool,
        pinned: Bool,
        audible: Bool? = nil,
        muted: Bool? = nil,
        groupId: Int? = nil,
        groupTitle: String? = nil,
        groupColor: String? = nil
    ) {
        self.id = id
        self.windowId = windowId
        self.index = index
        self.url = url
        self.title = title
        self.active = active
        self.pinned = pinned
        self.audible = audible
        self.muted = muted
        self.groupId = groupId
        self.groupTitle = groupTitle
        self.groupColor = groupColor
    }
}

// MARK: - Real-Time Window State

/// A real-time snapshot of a Chrome window from the native messaging extension
public struct ChromeRealTimeWindow: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let focused: Bool
    public let state: WindowState
    public let type: WindowType
    /// Window position - left edge (screen coordinates)
    public let left: Int?
    /// Window position - top edge (screen coordinates)
    public let top: Int?
    /// Window width in pixels
    public let width: Int?
    /// Window height in pixels
    public let height: Int?
    public let tabs: [ChromeRealTimeTab]

    public enum WindowState: String, Codable, Hashable, Sendable {
        case normal
        case minimized
        case maximized
        case fullscreen
    }

    public enum WindowType: String, Codable, Hashable, Sendable {
        case normal
        case popup
        case app
        case devtools
    }

    public init(
        id: Int,
        focused: Bool,
        state: WindowState,
        type: WindowType,
        left: Int? = nil,
        top: Int? = nil,
        width: Int? = nil,
        height: Int? = nil,
        tabs: [ChromeRealTimeTab]
    ) {
        self.id = id
        self.focused = focused
        self.state = state
        self.type = type
        self.left = left
        self.top = top
        self.width = width
        self.height = height
        self.tabs = tabs
    }

    /// Returns the window frame as a CGRect if all bounds are available.
    /// Useful for correlating with CGWindowList frames (±10px tolerance recommended).
    public var frame: CGRect? {
        guard let left = left, let top = top, let width = width, let height = height else {
            return nil
        }
        return CGRect(x: left, y: top, width: width, height: height)
    }
}

// MARK: - Tab Group

/// A Chrome tab group
public struct ChromeTabGroup: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let windowId: Int
    public let title: String
    public let color: String
    public let collapsed: Bool

    public init(
        id: Int,
        windowId: Int,
        title: String,
        color: String,
        collapsed: Bool
    ) {
        self.id = id
        self.windowId = windowId
        self.title = title
        self.color = color
        self.collapsed = collapsed
    }

    /// Available tab group colors in Chrome
    public enum Color: String, CaseIterable, Codable, Sendable {
        case grey
        case blue
        case red
        case yellow
        case green
        case pink
        case purple
        case cyan
        case orange
    }
}

// MARK: - Protocol Version / Handshake

/// Version of the DeskJig.app <-> Chrome-extension native-messaging protocol.
///
/// The app is updated via Sparkle and the extension via the Chrome Web Store,
/// so the two sides can skew at any time. Bump this integer whenever the
/// message contract changes incompatibly (new required command types, changed
/// payload shapes) so the mismatch is detected and reported instead of
/// failing silently. Must match `PROTOCOL_VERSION` in
/// ChromeExtension/DeskJigForChrome/background.js.
public enum ChromeNativeMessagingProtocol {
    public static let version = 1
}

/// Handshake sent by the Chrome extension once per connection (and echoed in
/// every heartbeat payload so a DeskJig.app that starts after Chrome still
/// learns the versions on the next heartbeat).
public struct ChromeExtensionHandshake: Codable, Sendable, Equatable {
    /// Integer protocol version the extension speaks (`PROTOCOL_VERSION` in background.js)
    public let protocolVersion: Int
    /// Extension version from `chrome.runtime.getManifest().version`
    public let extensionVersion: String
    /// Extension ID from `chrome.runtime.id`
    public let extensionId: String?

    public init(protocolVersion: Int, extensionVersion: String, extensionId: String? = nil) {
        self.protocolVersion = protocolVersion
        self.extensionVersion = extensionVersion
        self.extensionId = extensionId
    }
}

/// Where the version handshake stands for the current connection
public enum ChromeExtensionHandshakeState: Sendable, Equatable {
    /// Connected, but no handshake received yet (grace window still open)
    case awaitingHandshake
    /// Handshake received and the protocol versions match
    case compatible
    /// Handshake received but the protocol versions differ — app/extension
    /// version skew; one side needs an update
    case protocolMismatch(extensionProtocolVersion: Int, appProtocolVersion: Int)
    /// No handshake arrived within the grace window: the peer predates the
    /// handshake protocol (an old extension talking to a new app)
    case legacyPeer

    /// True when this state means the extension and app are version-skewed
    /// and one side needs an update (mismatched protocol or a pre-handshake
    /// legacy extension).
    public var isVersionSkewed: Bool {
        switch self {
        case .protocolMismatch, .legacyPeer:
            return true
        case .awaitingHandshake, .compatible:
            return false
        }
    }
}

// MARK: - Connection Status

/// Status of the native messaging connection
public struct ChromeNativeMessagingStatus: Sendable, Equatable {
    public let isConnected: Bool
    public let extensionId: String?
    public let lastHeartbeat: Date?
    public let errorMessage: String?
    /// Extension version reported in the handshake (`chrome.runtime.getManifest().version`);
    /// nil until a handshake arrives (or forever, for a legacy extension)
    public let extensionVersion: String?
    /// Protocol version the extension reported in the handshake
    public let protocolVersion: Int?
    /// Version-handshake state for the current connection
    public let handshakeState: ChromeExtensionHandshakeState

    public init(
        isConnected: Bool,
        extensionId: String? = nil,
        lastHeartbeat: Date? = nil,
        errorMessage: String? = nil,
        extensionVersion: String? = nil,
        protocolVersion: Int? = nil,
        handshakeState: ChromeExtensionHandshakeState = .awaitingHandshake
    ) {
        self.isConnected = isConnected
        self.extensionId = extensionId
        self.lastHeartbeat = lastHeartbeat
        self.errorMessage = errorMessage
        self.extensionVersion = extensionVersion
        self.protocolVersion = protocolVersion
        self.handshakeState = handshakeState
    }

    public static let disconnected = ChromeNativeMessagingStatus(isConnected: false)
}

// MARK: - Native Messaging Protocol Messages

/// Message types for the native messaging protocol
public enum NativeMessageType: String, Codable, Sendable {
    case tabEvent
    case windowEvent
    case navigationEvent
    case getAllTabs
    case getAllWindows
    case getTabsForWindow
    case handshake
    case heartbeat
    case response
    case error
}

/// A message sent to/from the native messaging host
public struct NativeMessage: Codable, Sendable {
    public let type: NativeMessageType
    public let requestId: String?
    public let payload: Data?

    public init(type: NativeMessageType, requestId: String? = nil, payload: Data? = nil) {
        self.type = type
        self.requestId = requestId
        self.payload = payload
    }

    /// Create a request message with a generated ID
    public static func request(_ type: NativeMessageType, payload: Encodable? = nil) -> NativeMessage {
        let payloadData = payload.flatMap { try? JSONEncoder().encode($0) }
        return NativeMessage(
            type: type,
            requestId: UUID().uuidString,
            payload: payloadData
        )
    }
}

// MARK: - Error Types

/// Errors that can occur during native messaging operations
public enum ChromeNativeMessagingError: Error, LocalizedError, Sendable {
    case notConnected
    case connectionLost
    case timeout
    case invalidResponse
    case extensionNotInstalled
    case hostNotFound
    case encodingError(String)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to Chrome native messaging host"
        case .connectionLost:
            return "Connection to Chrome native messaging host was lost"
        case .timeout:
            return "Request to Chrome timed out"
        case .invalidResponse:
            return "Received invalid response from Chrome"
        case .extensionNotInstalled:
            return "DeskJig Chrome extension is not installed"
        case .hostNotFound:
            return "Native messaging host not found"
        case .encodingError(let message):
            return "Failed to encode message: \(message)"
        case .decodingError(let message):
            return "Failed to decode response: \(message)"
        }
    }
}
