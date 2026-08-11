//
//  ChromeExtensionStatusView.swift
//  DeskJig
//
//  Status indicator and quick setup access for Chrome extension in Settings.
//

import SwiftUI
import DeskJigShared

struct ChromeExtensionStatusView: View {
    @Bindable var setupViewModel: ChromeExtensionSetupViewModel
    var messagingService: ChromeNativeMessagingServiceProtocol?

    @State private var isConnected: Bool = false
    @State private var connectionStatus: ChromeNativeMessagingStatus = .disconnected
    @State private var installedBrowsers: [ChromeBrowser] = []
    @State private var chromeWindows: [ChromeRealTimeWindow] = []
    @State private var isLoadingWindows: Bool = false
    @State private var lastRefresh: Date?
    @State private var showDebugPanel: Bool = false

    // Timer for periodic refresh
    let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with status
            HStack(spacing: 12) {
                statusIcon
                    .font(.system(size: DesignTokens.IconSize.xxLarge))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Chrome Extension")
                        .font(brand: .h4)
                        .foregroundStyle(DesignTokens.Text.primary)

                    statusText
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.secondary)
                }

                Spacer()

                actionButton
            }

            // Details when expanded
            if isConnected {
                connectedDetails
            } else if !installedBrowsers.isEmpty {
                disconnectedDetails
            }

            // Debug panel (expandable)
            if isConnected && showDebugPanel {
                debugPanel
            }
        }
        .padding(DesignTokens.Spacing.cardPaddingSmall)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(DesignTokens.Surface.elevated)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(DesignTokens.Border.subtle, lineWidth: 1)
        }
        .onAppear {
            refreshStatus()
        }
        .onReceive(refreshTimer) { _ in
            refreshStatus()
        }
        .onChange(of: setupViewModel.isPresented) { _, isPresented in
            if !isPresented {
                // Wizard closed, refresh status
                refreshStatus()
            }
        }
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        if isConnected && connectionStatus.handshakeState.isVersionSkewed {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Status.warning)
        } else if isConnected {
            Image(systemName: "bolt.circle.fill")
                .foregroundStyle(DesignTokens.Status.success)
        } else if installedBrowsers.isEmpty {
            Image(systemName: "globe.badge.chevron.backward")
                .foregroundStyle(DesignTokens.Text.tertiary)
        } else {
            Image(systemName: "bolt.slash.circle")
                .foregroundStyle(DesignTokens.Status.warning)
        }
    }

    // MARK: - Status Text

    @ViewBuilder
    private var statusText: some View {
        if isConnected {
            HStack(spacing: 4) {
                Text("Connected")
                    .foregroundStyle(DesignTokens.Status.success)
                Circle()
                    .fill(DesignTokens.Status.success)
                    .frame(width: 6, height: 6)
                if let extensionVersion = connectionStatus.extensionVersion {
                    Text("• Extension v\(extensionVersion)")
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
                if let lastRefresh = lastRefresh {
                    Text("• Updated \(lastRefresh, style: .relative) ago")
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
            }
        } else if installedBrowsers.isEmpty {
            Text("No supported browser installed")
                .foregroundStyle(DesignTokens.Text.tertiary)
        } else {
            Text("Not connected")
                .foregroundStyle(DesignTokens.Status.warning)
        }
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        if isConnected {
            HStack(spacing: 8) {
                Button {
                    showDebugPanel.toggle()
                } label: {
                    Image(systemName: showDebugPanel ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.dsSecondary(size: .small))

                Button("Refresh") {
                    refreshStatus()
                    loadChromeWindows()
                }
                .buttonStyle(.dsSecondary(size: .small))
            }
        } else if !installedBrowsers.isEmpty {
            Button("Setup") {
                setupViewModel.present()
            }
            .buttonStyle(.dsAccent(size: .small))
        }
    }

    // MARK: - Connected Details

    private var connectedDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            if connectionStatus.handshakeState.isVersionSkewed {
                versionSkewWarning
            }
            HStack(spacing: 16) {
                Label("Real-time sync active", systemImage: "arrow.clockwise")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Status.success)

                Spacer()

                // Quick actions when connected
                HStack(spacing: 8) {
                    Button {
                        Task {
                            await setupViewModel.registerForAllBrowsers()
                        }
                    } label: {
                        Label("Re-register", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.dsSecondary(size: .small))

                    Button {
                        setupViewModel.present()
                    } label: {
                        Label("Setup Wizard", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.dsSecondary(size: .small))

                    Button {
                        Task {
                            await setupViewModel.resetSetup()
                        }
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.dsSecondary(size: .small, foreground: DesignTokens.Status.error))
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Version Skew Warning (#542)

    private var versionSkewWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignTokens.Status.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text("Extension and app versions are out of sync")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.primary)
                Text(versionSkewDetail)
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.secondary)
            }

            Spacer()
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(DesignTokens.Status.warning.opacity(0.1))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(DesignTokens.Status.warning.opacity(0.4), lineWidth: 1)
        }
    }

    private var versionSkewDetail: String {
        switch connectionStatus.handshakeState {
        case .protocolMismatch(let extensionProtocolVersion, let appProtocolVersion):
            let extensionVersion = connectionStatus.extensionVersion ?? "unknown"
            return "Extension v\(extensionVersion) speaks protocol v\(extensionProtocolVersion); "
                + "the app speaks v\(appProtocolVersion). Update the older side."
        case .legacyPeer:
            return "The installed extension predates version reporting. Update it from the Chrome Web Store."
        case .awaitingHandshake, .compatible:
            return ""
        }
    }

    // MARK: - Debug Panel

    private var debugPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            // Test connection section
            HStack {
                Text("Debug Tools")
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                Spacer()

                Button {
                    loadChromeWindows()
                } label: {
                    Label(isLoadingWindows ? "Loading..." : "Load Chrome Windows", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.dsSecondary(size: .small))
                .disabled(isLoadingWindows)
            }

            // Chrome windows list
            if !chromeWindows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Chrome Windows (\(chromeWindows.count))")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)

                    ForEach(chromeWindows, id: \.id) { window in
                        chromeWindowRow(window)
                    }
                }
            } else if !isLoadingWindows {
                Text("No Chrome windows loaded. Click 'Load Chrome Windows' to fetch.")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .padding(.vertical, 4)
            }
        }
        .padding(.top, 8)
    }

    private func chromeWindowRow(_ window: ChromeRealTimeWindow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "macwindow")
                .foregroundStyle(DesignTokens.Text.tertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Window #\(window.id)")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.primary)

                if !window.tabs.isEmpty {
                    Text("\(window.tabs.count) tab(s) • \(window.tabs.first?.title ?? "Untitled")")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                focusWindow(window.id)
            } label: {
                Label("Focus", systemImage: "arrow.up.forward.app")
            }
            .buttonStyle(.dsSecondary(size: .small))
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(DesignTokens.Surface.card)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(DesignTokens.Border.subtle, lineWidth: 1)
        }
    }

    // MARK: - Disconnected Details

    private var disconnectedDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Detected browsers:")
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.tertiary)

            HStack(spacing: 8) {
                ForEach(installedBrowsers) { browser in
                    HStack(spacing: 4) {
                        Image(systemName: "app.fill")
                            .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                            .foregroundStyle(DesignTokens.Text.secondary)
                        Text(browser.rawValue)
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(DesignTokens.Surface.card)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                    }
                }
            }

            Text("Click Setup to enable Chrome integration")
                .font(brand: .body4)
                .foregroundStyle(DesignTokens.Text.secondary)
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func refreshStatus() {
        isConnected = messagingService?.isConnected ?? false
        connectionStatus = messagingService?.status ?? .disconnected
        installedBrowsers = ChromeBrowser.installedBrowsers
        lastRefresh = Date()
    }

    private func loadChromeWindows() {
        guard let service = messagingService, service.isConnected else { return }

        isLoadingWindows = true
        Task {
            do {
                let windows = try await service.getAllWindows(forceRefresh: true)
                await MainActor.run {
                    self.chromeWindows = windows
                    self.isLoadingWindows = false
                }
            } catch {
                await MainActor.run {
                    self.chromeWindows = []
                    self.isLoadingWindows = false
                }
                DeskJigLog.error(.chrome, "ChromeExtensionStatusView: Failed to load Chrome windows", fields: ["error": "\(error)"])
            }
        }
    }

    private func focusWindow(_ windowId: Int) {
        guard let service = messagingService else { return }

        Task {
            do {
                let payload = try JSONEncoder().encode(["windowId": windowId])
                _ = try await service.sendCommand(type: "focusWindow", payload: payload)
            } catch {
                DeskJigLog.error(.chrome, "ChromeExtensionStatusView: Failed to focus window", fields: ["error": "\(error)"])
            }
        }
    }
}

// MARK: - Compact Version for Menu Bar

struct ChromeExtensionStatusCompact: View {
    var messagingService: ChromeNativeMessagingServiceProtocol?

    var body: some View {
        HStack(spacing: 4) {
            if messagingService?.isConnected == true {
                Image(systemName: "bolt.fill")
                    .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                    .foregroundStyle(DesignTokens.Status.success)
                Text("Chrome")
                    .font(brand: .body4)
                    .foregroundStyle(DesignTokens.Text.secondary)
            }
        }
    }
}

#Preview {
    ChromeExtensionStatusView(
        setupViewModel: ChromeExtensionSetupViewModel()
    )
    .padding()
    .frame(width: 500)
}
