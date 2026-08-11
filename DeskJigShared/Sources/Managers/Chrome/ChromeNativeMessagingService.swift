//  ChromeNativeMessagingService.swift
//  DeskJigShared

import Foundation

// MARK: - Protocol

/// Protocol for Chrome native messaging service
/// Provides real-time access to Chrome tab and window state via the native messaging extension
public protocol ChromeNativeMessagingServiceProtocol: AnyObject, Sendable {
    /// Whether the native messaging connection is active
    var isConnected: Bool { get }

    /// Current connection status
    var status: ChromeNativeMessagingStatus { get }

    /// Stream of tab events from Chrome
    var tabEvents: AsyncStream<ChromeTabEvent> { get }

    /// Stream of window events from Chrome
    var windowEvents: AsyncStream<ChromeWindowEvent> { get }

    /// Stream of navigation events from Chrome
    var navigationEvents: AsyncStream<ChromeNavigationEvent> { get }

    /// Get all open tabs across all Chrome windows
    /// - Parameter forceRefresh: If true, bypass cache and fetch fresh data from Chrome
    func getAllTabs(forceRefresh: Bool) async throws -> [ChromeRealTimeTab]

    /// Get all open Chrome windows with their tabs
    /// - Parameter forceRefresh: If true, bypass cache and fetch fresh data from Chrome
    func getAllWindows(forceRefresh: Bool) async throws -> [ChromeRealTimeWindow]

    /// Get tabs for a specific window
    func getTabsForWindow(windowId: Int) async throws -> [ChromeRealTimeTab]

    /// Get the active tab for a specific window
    func getActiveTab(windowId: Int) async throws -> ChromeRealTimeTab?

    /// Send a command to Chrome and await response
    /// - Parameters:
    ///   - type: The command type (e.g., "createTab", "closeWindow")
    ///   - payload: Optional JSON payload data
    /// - Returns: Response data from Chrome
    /// - Throws: ChromeNativeMessagingError
    func sendCommand(type: String, payload: Data?) async throws -> Data

    /// Start the native messaging server
    func start() throws

    /// Stop the native messaging server
    func stop()
}

// MARK: - Implementation

/// Real implementation of Chrome native messaging service
/// Runs a Unix socket server that DeskJigNativeHost connects to
public final class ChromeNativeMessagingService: ChromeNativeMessagingServiceProtocol, @unchecked Sendable {

    // MARK: - Types

    /// A request awaiting a response from Chrome: the parked continuation plus
    /// the timeout task that fails it if the extension never replies (#518).
    /// Exactly one of {response, disconnect, timeout, send-failure} resumes the
    /// continuation: whichever path removes the entry from `pendingRequests`
    /// under `lock` wins; the losers see nil and do nothing.
    private struct PendingRequest {
        let type: String
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTask: Task<Void, Never>
    }

    // MARK: - Properties

    /// Default deadline for a request/response round-trip with the extension.
    /// Generous enough for a suspended service worker to wake and reply, but
    /// bounded so a silent extension can never stall restoration forever.
    public static let defaultRequestTimeout: TimeInterval = 15.0

    /// Default grace window after connect within which the extension must
    /// send its version handshake (#542). A current extension handshakes
    /// immediately on connect and echoes the handshake in every heartbeat
    /// (every 30s), so this is set past one heartbeat interval to cover the
    /// app-started-after-Chrome case. If nothing arrives in time the peer is
    /// classified as a legacy (pre-handshake) extension — reported as version
    /// skew, never a hang.
    public static let defaultHandshakeGracePeriod: TimeInterval = 45.0

    private let server: NativeMessagingServer
    private let lock = NSLock()
    private let requestTimeout: TimeInterval
    private let handshakeGracePeriod: TimeInterval

    /// Classifies the peer as legacy if no handshake arrives within the grace
    /// window. Created on accept, cancelled by handshake/disconnect/stop.
    private var handshakeGraceTask: Task<Void, Never>?

    private var _status: ChromeNativeMessagingStatus = .disconnected
    private var tabEventsContinuation: AsyncStream<ChromeTabEvent>.Continuation?
    private var windowEventsContinuation: AsyncStream<ChromeWindowEvent>.Continuation?
    private var navigationEventsContinuation: AsyncStream<ChromeNavigationEvent>.Continuation?

    // Cached state from Chrome
    private var cachedTabs: [Int: ChromeRealTimeTab] = [:]  // tabId -> tab
    private var cachedWindows: [Int: ChromeRealTimeWindow] = [:]  // windowId -> window

    // Pending requests waiting for responses from Chrome
    private var pendingRequests: [String: PendingRequest] = [:]

    // MARK: - Public Properties

    public var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return server.isClientConnected
    }

    public var status: ChromeNativeMessagingStatus {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    public private(set) lazy var tabEvents: AsyncStream<ChromeTabEvent> = {
        AsyncStream { continuation in
            self.tabEventsContinuation = continuation
        }
    }()

    public private(set) lazy var windowEvents: AsyncStream<ChromeWindowEvent> = {
        AsyncStream { continuation in
            self.windowEventsContinuation = continuation
        }
    }()

    public private(set) lazy var navigationEvents: AsyncStream<ChromeNavigationEvent> = {
        AsyncStream { continuation in
            self.navigationEventsContinuation = continuation
        }
    }()

    // MARK: - Initialization

    /// Initialize with default socket path
    public init(
        requestTimeout: TimeInterval = ChromeNativeMessagingService.defaultRequestTimeout,
        handshakeGracePeriod: TimeInterval = ChromeNativeMessagingService.defaultHandshakeGracePeriod
    ) {
        self.server = NativeMessagingServer()
        self.requestTimeout = requestTimeout
        self.handshakeGracePeriod = handshakeGracePeriod
        self.server.delegate = self
    }

    /// Initialize with custom socket path (for testing)
    public init(
        socketPath: String,
        requestTimeout: TimeInterval = ChromeNativeMessagingService.defaultRequestTimeout,
        handshakeGracePeriod: TimeInterval = ChromeNativeMessagingService.defaultHandshakeGracePeriod
    ) {
        self.server = NativeMessagingServer(socketPath: socketPath)
        self.requestTimeout = requestTimeout
        self.handshakeGracePeriod = handshakeGracePeriod
        self.server.delegate = self
    }

    deinit {
        stop()
    }

    // MARK: - Server Lifecycle

    public func start() throws {
        try server.start()

        lock.lock()
        _status = ChromeNativeMessagingStatus(
            isConnected: false,
            extensionId: nil,
            lastHeartbeat: nil
        )
        lock.unlock()

        DeskJigLog.info(.chrome, "ChromeNativeMessaging: Chrome native messaging service started")
    }

    public func stop() {
        server.stop()

        lock.lock()
        _status = .disconnected
        cachedTabs.removeAll()
        cachedWindows.removeAll()
        let graceTask = handshakeGraceTask
        handshakeGraceTask = nil
        lock.unlock()

        graceTask?.cancel()

        tabEventsContinuation?.finish()
        windowEventsContinuation?.finish()
        navigationEventsContinuation?.finish()

        DeskJigLog.info(.chrome, "ChromeNativeMessaging: Chrome native messaging service stopped")
    }

    // MARK: - Synchronous Cache Helpers (keep NSLock out of async context)

    private func getCachedTabs() -> [ChromeRealTimeTab] {
        lock.lock()
        defer { lock.unlock() }
        return Array(cachedTabs.values)
    }

    private func updateCachedTabs(_ tabs: [ChromeRealTimeTab]) {
        lock.lock()
        defer { lock.unlock() }
        cachedTabs.removeAll()
        for tab in tabs {
            cachedTabs[tab.id] = tab
        }
    }

    private func getCachedWindows() -> [ChromeRealTimeWindow] {
        lock.lock()
        defer { lock.unlock() }
        return Array(cachedWindows.values)
    }

    private func updateCachedWindows(_ windows: [ChromeRealTimeWindow]) {
        lock.lock()
        defer { lock.unlock() }
        cachedWindows.removeAll()
        for window in windows {
            cachedWindows[window.id] = window
        }
    }

    private func getCachedTabsForWindow(_ windowId: Int) -> [ChromeRealTimeTab] {
        lock.lock()
        defer { lock.unlock() }
        return cachedTabs.values.filter { $0.windowId == windowId }
    }

    // MARK: - Tab/Window Queries

    public func getAllTabs(forceRefresh: Bool = false) async throws -> [ChromeRealTimeTab] {
        // If not forcing refresh and we have cached tabs, return them
        if !forceRefresh {
            let tabs = getCachedTabs()

            if !tabs.isEmpty {
                return tabs.sorted { $0.index < $1.index }
            }
        }

        // Request fresh data from Chrome
        let response = try await sendRequest(type: "getAllTabs")
        let responseTabs = try JSONDecoder().decode([ChromeRealTimeTab].self, from: response)

        // Update the cache with fresh data
        updateCachedTabs(responseTabs)

        return responseTabs
    }

    public func getAllWindows(forceRefresh: Bool = false) async throws -> [ChromeRealTimeWindow] {
        // If not forcing refresh and we have cached windows, return them
        if !forceRefresh {
            let windows = getCachedWindows()

            if !windows.isEmpty {
                return windows.sorted { $0.id < $1.id }
            }
        }

        // Request fresh data from Chrome
        let response = try await sendRequest(type: "getAllWindows")
        let responseWindows = try JSONDecoder().decode([ChromeRealTimeWindow].self, from: response)

        // Update the cache with fresh data
        updateCachedWindows(responseWindows)

        return responseWindows
    }

    public func getTabsForWindow(windowId: Int) async throws -> [ChromeRealTimeTab] {
        let tabs = getCachedTabsForWindow(windowId)

        if !tabs.isEmpty {
            return Array(tabs).sorted { $0.index < $1.index }
        }

        // Request from Chrome
        let payload = try JSONEncoder().encode(["windowId": windowId])
        let response = try await sendRequest(type: "getTabsForWindow", payload: payload)
        return try JSONDecoder().decode([ChromeRealTimeTab].self, from: response)
    }

    public func getActiveTab(windowId: Int) async throws -> ChromeRealTimeTab? {
        let tabs = try await getTabsForWindow(windowId: windowId)
        return tabs.first { $0.active }
    }

    public func sendCommand(type: String, payload: Data?) async throws -> Data {
        try await sendRequest(type: type, payload: payload)
    }

    // MARK: - Private Methods

    private func sendRequest(type: String, payload: Data? = nil) async throws -> Data {
        guard isConnected else {
            throw ChromeNativeMessagingError.notConnected
        }

        let requestId = UUID().uuidString

        // Build request message
        var request: [String: Any] = [
            "type": type,
            "requestId": requestId
        ]
        if let payload = payload,
           let payloadString = String(data: payload, encoding: .utf8) {
            request["payload"] = payloadString
        }

        let requestData = try JSONSerialization.data(withJSONObject: request)

        // Send and wait for response, bounded by requestTimeout so a silent
        // extension (suspended service worker, dropped message, unknown
        // command type) can never park this continuation forever (#518).
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            // Created while holding `lock` so the task's own lock.lock() in
            // failPendingRequestOnTimeout blocks until the entry is inserted,
            // even with a very short timeout.
            let timeoutTask = Task { [weak self, requestTimeout] in
                try? await Task.sleep(nanoseconds: UInt64(requestTimeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.failPendingRequestOnTimeout(requestId: requestId, type: type)
            }
            pendingRequests[requestId] = PendingRequest(
                type: type,
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            lock.unlock()

            do {
                try server.sendToClient(requestData)
            } catch {
                lock.lock()
                let pending = pendingRequests.removeValue(forKey: requestId)
                lock.unlock()

                // Only resume if this path won the removal; the timeout task
                // may have already fired for very short timeouts.
                if let pending = pending {
                    pending.timeoutTask.cancel()
                    pending.continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Fails a still-pending request with `.timeout`. No-op if a response,
    /// disconnect, or send failure already claimed the continuation.
    private func failPendingRequestOnTimeout(requestId: String, type: String) {
        lock.lock()
        let pending = pendingRequests.removeValue(forKey: requestId)
        lock.unlock()

        guard let pending = pending else { return }

        DeskJigLog.warn(
            .chrome,
            "ChromeNativeMessaging: Request timed out after \(requestTimeout)s: type=\(type), requestId=\(requestId)"
        )
        pending.continuation.resume(throwing: ChromeNativeMessagingError.timeout)
    }

    private func handleIncomingMessage(_ data: Data) -> Data? {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                DeskJigLog.error(.chrome, "ChromeNativeMessaging: Invalid message format")
                return createErrorResponse(nil, error: "Invalid message format")
            }

            let requestId = json["requestId"] as? String
            let payloadString = json["payload"] as? String
            let payload = payloadString?.data(using: .utf8)

            switch type {
            case "tabEvent":
                handleTabEvent(payload)
                return createSuccessResponse(requestId)

            case "windowEvent":
                handleWindowEvent(payload)
                return createSuccessResponse(requestId)

            case "navigationEvent":
                handleNavigationEvent(payload)
                return createSuccessResponse(requestId)

            case "response":
                // Response to a request we sent
                handleResponse(requestId: requestId, payload: payload, success: true)
                return nil  // No response needed

            case "error":
                // Error response to a request we sent
                let errorMessage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                handleResponse(requestId: requestId, payload: payload, success: false, errorMessage: errorMessage)
                return nil  // No response needed

            case "allTabs":
                // Chrome is sending all tabs (initial sync)
                if let payload = payload {
                    handleAllTabs(payload)
                }
                return createSuccessResponse(requestId)

            case "allWindows":
                // Chrome is sending all windows (initial sync)
                if let payload = payload {
                    handleAllWindows(payload)
                }
                return createSuccessResponse(requestId)

            case "handshake":
                // Version handshake from the extension (#542)
                handleHandshake(payload)
                return createSuccessResponse(requestId)

            case "heartbeat":
                // Update last heartbeat timestamp, preserving handshake info
                lock.lock()
                _status = ChromeNativeMessagingStatus(
                    isConnected: true,
                    extensionId: _status.extensionId,
                    lastHeartbeat: Date(),
                    extensionVersion: _status.extensionVersion,
                    protocolVersion: _status.protocolVersion,
                    handshakeState: _status.handshakeState
                )
                lock.unlock()
                // Current extensions echo the handshake in every heartbeat
                // payload so an app that started after Chrome (or reconnected)
                // still learns the extension version without a fresh connect.
                if payload != nil {
                    handleHandshake(payload)
                }
                return createSuccessResponse(requestId)

            default:
                DeskJigLog.warn(.chrome, "ChromeNativeMessaging: Unknown message type: \(type)")
                return createErrorResponse(requestId, error: "Unknown message type: \(type)")
            }
        } catch {
            DeskJigLog.error(.chrome, "ChromeNativeMessaging: Failed to parse message: \(error)")
            return createErrorResponse(nil, error: error.localizedDescription)
        }
    }

    private func handleTabEvent(_ payload: Data?) {
        guard let payload = payload,
              let event = try? JSONDecoder().decode(ChromeTabEvent.self, from: payload) else {
            return
        }

        // Update cache based on event
        lock.lock()
        switch event.eventType {
        case .created, .updated:
            // Create/update tab from event data
            if let url = event.url, let title = event.title, let index = event.index {
                let tab = ChromeRealTimeTab(
                    id: event.tabId,
                    windowId: event.windowId,
                    index: index,
                    url: url,
                    title: title,
                    active: false,
                    pinned: false
                )
                cachedTabs[event.tabId] = tab
            }
        case .removed:
            cachedTabs.removeValue(forKey: event.tabId)
        case .activated:
            // Update active state for all tabs in this window
            for (id, tab) in cachedTabs where tab.windowId == event.windowId {
                let updatedTab = ChromeRealTimeTab(
                    id: tab.id,
                    windowId: tab.windowId,
                    index: tab.index,
                    url: tab.url,
                    title: tab.title,
                    active: id == event.tabId,
                    pinned: tab.pinned,
                    audible: tab.audible,
                    muted: tab.muted,
                    groupId: tab.groupId,
                    groupTitle: tab.groupTitle,
                    groupColor: tab.groupColor
                )
                cachedTabs[id] = updatedTab
            }
        default:
            break
        }
        lock.unlock()

        tabEventsContinuation?.yield(event)
    }

    private func handleWindowEvent(_ payload: Data?) {
        guard let payload = payload,
              let event = try? JSONDecoder().decode(ChromeWindowEvent.self, from: payload) else {
            return
        }

        // Update cache based on event
        lock.lock()
        switch event.eventType {
        case .created:
            // Create window (tabs will come via tab events)
            let window = ChromeRealTimeWindow(
                id: event.windowId,
                focused: event.focused ?? false,
                state: .normal,
                type: .normal,
                tabs: []
            )
            cachedWindows[event.windowId] = window
        case .removed:
            cachedWindows.removeValue(forKey: event.windowId)
            // Also remove all tabs for this window
            cachedTabs = cachedTabs.filter { $0.value.windowId != event.windowId }
        case .focusChanged:
            // Update focused state
            for (id, window) in cachedWindows {
                let updatedWindow = ChromeRealTimeWindow(
                    id: window.id,
                    focused: id == event.windowId,
                    state: window.state,
                    type: window.type,
                    tabs: window.tabs
                )
                cachedWindows[id] = updatedWindow
            }
        }
        lock.unlock()

        windowEventsContinuation?.yield(event)
    }

    private func handleNavigationEvent(_ payload: Data?) {
        guard let payload = payload,
              let event = try? JSONDecoder().decode(ChromeNavigationEvent.self, from: payload) else {
            return
        }

        navigationEventsContinuation?.yield(event)
    }

    // MARK: - Version Handshake (#542)

    /// Records the extension's version handshake into the connection status
    /// and classifies the protocol compatibility. Idempotent: heartbeats echo
    /// the handshake, so this runs repeatedly for a healthy connection.
    private func handleHandshake(_ payload: Data?) {
        guard let payload = payload,
              let handshake = try? JSONDecoder().decode(ChromeExtensionHandshake.self, from: payload) else {
            // A heartbeat payload that isn't a handshake (or a malformed
            // handshake) is ignored; the legacy grace window still applies.
            return
        }

        let appVersion = ChromeNativeMessagingProtocol.version
        let state: ChromeExtensionHandshakeState
        if handshake.protocolVersion == appVersion {
            state = .compatible
        } else {
            state = .protocolMismatch(
                extensionProtocolVersion: handshake.protocolVersion,
                appProtocolVersion: appVersion
            )
        }

        lock.lock()
        let previousState = _status.handshakeState
        _status = ChromeNativeMessagingStatus(
            isConnected: _status.isConnected,
            extensionId: handshake.extensionId ?? _status.extensionId,
            lastHeartbeat: _status.lastHeartbeat,
            extensionVersion: handshake.extensionVersion,
            protocolVersion: handshake.protocolVersion,
            handshakeState: state
        )
        let graceTask = handshakeGraceTask
        handshakeGraceTask = nil
        lock.unlock()

        graceTask?.cancel()

        // Only log on state transitions; heartbeats re-deliver the handshake.
        guard state != previousState else { return }

        switch state {
        case .compatible:
            DeskJigLog.info(
                .chrome,
                "ChromeNativeMessaging: Extension handshake OK: version=\(handshake.extensionVersion), protocolVersion=\(handshake.protocolVersion)"
            )
        case .protocolMismatch(let extensionProtocolVersion, let appProtocolVersion):
            DeskJigLog.warn(
                .chrome,
                "ChromeNativeMessaging: Protocol version skew — extension speaks v\(extensionProtocolVersion) "
                    + "(extension version \(handshake.extensionVersion)) but app speaks v\(appProtocolVersion); "
                    + "update the older side"
            )
        case .awaitingHandshake, .legacyPeer:
            break  // handleHandshake never produces these states
        }
    }

    /// Starts the per-connection grace window: if no handshake arrives before
    /// it elapses, the peer is classified as a legacy (pre-handshake)
    /// extension so absence of a handshake is reported, never a silent hang.
    private func startHandshakeGraceWindow() {
        let graceTask = Task { [weak self, handshakeGracePeriod] in
            try? await Task.sleep(nanoseconds: UInt64(handshakeGracePeriod * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.markPeerAsLegacyIfStillAwaitingHandshake()
        }

        lock.lock()
        handshakeGraceTask?.cancel()
        handshakeGraceTask = graceTask
        lock.unlock()
    }

    private func markPeerAsLegacyIfStillAwaitingHandshake() {
        lock.lock()
        guard _status.isConnected, _status.handshakeState == .awaitingHandshake else {
            // A handshake or disconnect won the race. Any referenced task is
            // completed/cancelled by now (a live grace task only exists while
            // .awaitingHandshake), so drop it instead of letting it linger
            // until the next connect/stop.
            handshakeGraceTask = nil
            lock.unlock()
            return
        }
        _status = ChromeNativeMessagingStatus(
            isConnected: true,
            extensionId: _status.extensionId,
            lastHeartbeat: _status.lastHeartbeat,
            extensionVersion: _status.extensionVersion,
            protocolVersion: _status.protocolVersion,
            handshakeState: .legacyPeer
        )
        handshakeGraceTask = nil
        lock.unlock()

        DeskJigLog.warn(
            .chrome,
            "ChromeNativeMessaging: No version handshake within \(handshakeGracePeriod)s — extension predates "
                + "the handshake protocol (app protocolVersion \(ChromeNativeMessagingProtocol.version)); "
                + "the extension needs an update"
        )
    }

    private func handleResponse(requestId: String?, payload: Data?, success: Bool, errorMessage: String? = nil) {
        guard let requestId = requestId else { return }

        lock.lock()
        let pending = pendingRequests.removeValue(forKey: requestId)
        lock.unlock()

        // Removal won the race, so the timeout task can no longer fire for
        // this request; cancel it so it doesn't linger for the full deadline.
        guard let pending = pending else { return }
        pending.timeoutTask.cancel()

        if success {
            // Success response - payload may be nil for commands that don't return data
            let responseData = payload ?? Data()
            pending.continuation.resume(returning: responseData)
        } else {
            // Error response from the extension
            let message = errorMessage ?? "Unknown error from Chrome extension"
            DeskJigLog.error(.chrome, "ChromeNativeMessaging: Chrome command failed: \(message)")
            pending.continuation.resume(throwing: ChromeNativeMessagingError.decodingError(message))
        }
    }

    private func handleAllTabs(_ payload: Data) {
        guard let tabs = try? JSONDecoder().decode([ChromeRealTimeTab].self, from: payload) else {
            return
        }

        lock.lock()
        cachedTabs.removeAll()
        for tab in tabs {
            cachedTabs[tab.id] = tab
        }
        lock.unlock()

        DeskJigLog.info(.chrome, "ChromeNativeMessaging: Cached \(tabs.count) tabs from Chrome")
    }

    private func handleAllWindows(_ payload: Data) {
        guard let windows = try? JSONDecoder().decode([ChromeRealTimeWindow].self, from: payload) else {
            return
        }

        lock.lock()
        cachedWindows.removeAll()
        for window in windows {
            cachedWindows[window.id] = window
        }
        lock.unlock()

        DeskJigLog.info(.chrome, "ChromeNativeMessaging: Cached \(windows.count) windows from Chrome")
    }

    private func createSuccessResponse(_ requestId: String?) -> Data {
        var response: [String: Any] = [
            "type": "response",
            "success": true
        ]
        if let requestId = requestId {
            response["requestId"] = requestId
        }
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }

    private func createErrorResponse(_ requestId: String?, error: String) -> Data {
        var response: [String: Any] = [
            "type": "error",
            "success": false,
            "error": error
        ]
        if let requestId = requestId {
            response["requestId"] = requestId
        }
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }
}

// MARK: - NativeMessagingServerDelegate

extension ChromeNativeMessagingService: NativeMessagingServerDelegate {
    // Delivered synchronously on the server's client-handling thread, strictly
    // before the connection's first message (see NativeMessagingServerDelegate),
    // so this status reset can never clobber a handshake already recorded for
    // this connection (#542 race).
    public func serverDidAcceptConnection(_ server: NativeMessagingServer) {
        lock.lock()
        _status = ChromeNativeMessagingStatus(
            isConnected: true,
            extensionId: nil,
            lastHeartbeat: Date(),
            handshakeState: .awaitingHandshake
        )
        lock.unlock()

        // A current extension handshakes right away; if nothing arrives
        // within the grace window the peer is a legacy extension (#542).
        startHandshakeGraceWindow()

        DeskJigLog.info(.chrome, "ChromeNativeMessaging: DeskJigNativeHost connected")
    }

    public func server(_ server: NativeMessagingServer, didReceiveMessage data: Data) -> Data? {
        return handleIncomingMessage(data)
    }

    public func serverDidDisconnect(_ server: NativeMessagingServer, error: Error?) {
        lock.lock()
        _status = ChromeNativeMessagingStatus(
            isConnected: false,
            errorMessage: error?.localizedDescription
        )
        let graceTask = handshakeGraceTask
        handshakeGraceTask = nil
        lock.unlock()

        graceTask?.cancel()

        // Fail all pending requests
        lock.lock()
        let pending = pendingRequests
        pendingRequests.removeAll()
        lock.unlock()

        for (_, request) in pending {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: ChromeNativeMessagingError.connectionLost)
        }

        DeskJigLog.info(.chrome, "ChromeNativeMessaging: DeskJigNativeHost disconnected")
    }
}
