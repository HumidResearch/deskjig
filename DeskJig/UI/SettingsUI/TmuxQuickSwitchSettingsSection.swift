//  TmuxQuickSwitchSettingsSection.swift
//  DeskJig

import SwiftUI
import DeskJigShared

/// Terminal (tmux) controls for the Quick Switch settings card.
///
/// tmux fast switching is what makes Quick Switch instant for terminal-heavy
/// workspaces, so its enable/install/reset controls live here rather than in
/// the general settings tree. The `tmuxEnabled` preference read here is the
/// same key the restore gate resolves (FluentWorkspaceRestorer).
struct TmuxQuickSwitchSettingsSection: View {
    @AppStorage("tmuxEnabled") private var tmuxEnabled: Bool = false
    @State private var tmuxIsInstalled: Bool? = nil
    @State private var tmuxBinaryPath: String? = nil
    @State private var tmuxVersion: String? = nil
    @State private var tmuxSessionCount: Int = 0
    @State private var tmuxResetInProgress = false
    @State private var tmuxResetMessage: String? = nil
    @State private var tmuxResetError: String? = nil
    @State private var showTmuxResetConfirmation = false
    @State private var tmuxInstallInProgress = false
    @State private var tmuxInstallMessage: String? = nil
    @State private var tmuxInstallError: String? = nil

    private var tmuxStatusLabel: (text: String, icon: String, color: Color) {
        if let installed = tmuxIsInstalled {
            if installed {
                return ("Installed", "checkmark.circle.fill", DesignTokens.Status.success)
            }
            return ("Not Installed", "exclamationmark.triangle.fill", DesignTokens.Status.warning)
        }
        return ("Checking…", "arrow.clockwise", DesignTokens.Text.tertiary)
    }

    private var tmuxStatusDetail: String? {
        guard let installed = tmuxIsInstalled else { return nil }
        if installed {
            return tmuxVersion
        }
        return "tmux is required for fast terminal switching"
    }

    private var tmuxToggleIsEnabled: Bool {
        tmuxIsInstalled == true
    }

    private var tmuxEnabledBinding: Binding<Bool> {
        Binding(
            get: { tmuxToggleIsEnabled ? tmuxEnabled : false },
            set: { newValue in
                guard tmuxToggleIsEnabled else {
                    tmuxEnabled = false
                    return
                }
                tmuxEnabled = newValue
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("Terminal (tmux)")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)

                DSTag(
                    label: "Beta",
                    color: DesignTokens.Status.success,
                    size: .small
                )
            }

            SettingsToggle(
                title: "Enable tmux fast switching",
                subtitle: "Use tmux sessions for instant terminal window switching during restore",
                isOn: tmuxEnabledBinding
            )
            .disabled(!tmuxToggleIsEnabled)
            .opacity(tmuxToggleIsEnabled ? 1.0 : 0.6)

            SettingsRow("Status", controlWidth: 320) {
                VStack(alignment: .trailing, spacing: 4) {
                    DSStatusLabel(
                        text: tmuxStatusLabel.text,
                        systemIcon: tmuxStatusLabel.icon,
                        color: tmuxStatusLabel.color
                    )

                    if let detail = tmuxStatusDetail {
                        Text(detail)
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.tertiary)
                    }

                    if let path = tmuxBinaryPath {
                        Text("Path: \(path)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(DesignTokens.Text.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            if tmuxIsInstalled == false {
                SettingsRow("Install") {
                    Button {
                        performTmuxInstall()
                    } label: {
                        if tmuxInstallInProgress {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.8)
                        } else {
                            Text("Install via Homebrew")
                        }
                    }
                    .buttonStyle(.dsAccent(size: .small))
                    .disabled(tmuxInstallInProgress)
                }

                if let tmuxInstallMessage {
                    tmuxInstallOutputBlock(
                        title: "Install Output",
                        icon: "checkmark.circle.fill",
                        color: DesignTokens.Status.success,
                        text: tmuxInstallMessage
                    )
                }

                if let tmuxInstallError {
                    tmuxInstallOutputBlock(
                        title: "Install Error",
                        icon: "exclamationmark.triangle.fill",
                        color: DesignTokens.Status.error,
                        text: tmuxInstallError
                    )

                    if tmuxInstallError.contains("brew.sh") {
                        Button {
                            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                                Text("Open brew.sh")
                            }
                        }
                        .buttonStyle(.dsSecondary(size: .small))
                    }
                }
            }

            SettingsRow("Socket Path") {
                Text(TmuxCommandService.deskJigSocketPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(DesignTokens.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .opacity(tmuxIsInstalled == true ? 1.0 : 0.5)

            if tmuxSessionCount > 0 {
                SettingsRow("Active Sessions") {
                    Text("\(tmuxSessionCount)")
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.primary)
                }
            }

            SettingsRow("Reset Sessions") {
                Button {
                    showTmuxResetConfirmation = true
                } label: {
                    if tmuxResetInProgress {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.8)
                    } else {
                        Text("Reset")
                    }
                }
                .buttonStyle(.dsSecondary(size: .small, foreground: DesignTokens.Status.error))
                .disabled(tmuxIsInstalled != true || tmuxResetInProgress)
            }

            if let tmuxResetMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                    Text(tmuxResetMessage)
                        .font(brand: .body4)
                }
                .foregroundStyle(DesignTokens.Status.success)
            }

            if let tmuxResetError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                    Text(tmuxResetError)
                        .font(brand: .body4)
                }
                .foregroundStyle(DesignTokens.Status.error)
            }

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                Text("Reset kills all DeskJig-managed tmux sessions. They are recreated on next workspace restore.")
            }
            .font(brand: .body4)
            .foregroundStyle(DesignTokens.Text.tertiary)
        }
        .onAppear {
            loadTmuxInfo()
        }
        .onChange(of: tmuxIsInstalled) { _, newValue in
            if newValue != true {
                tmuxEnabled = false
            }
        }
        .onChange(of: tmuxEnabled) { oldValue, newValue in
            guard oldValue != newValue else { return }
            DeskJigLog.info(.app, "Setting changed", fields: ["setting": "tmux_enabled", "value": "\(newValue)", "previousValue": "\(oldValue)"])
        }
        .alert("Reset Tmux Sessions?", isPresented: $showTmuxResetConfirmation) {
            Button("Reset", role: .destructive) {
                performTmuxReset()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will kill all DeskJig-managed tmux sessions and disconnect any active terminal sessions. Sessions will be recreated on next workspace restore.")
        }
    }

    private func tmuxInstallOutputBlock(title: String, icon: String, color: Color, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: DesignTokens.IconSize.small, weight: .medium))
                Text(title)
                    .font(brand: .body4)
            }
            .foregroundStyle(color)

            ScrollView(.vertical) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                    .fill(DesignTokens.Surface.window)
                    .overlay {
                        RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                            .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                    }
            }
        }
    }

    private func loadTmuxInfo() {
        Task.detached(priority: .utility) {
            DeskJigLog.info(.app, "[QuickSwitchSettings] Starting tmux status refresh")
            let service = TmuxCommandService()
            let installed = await service.isAvailable
            let binary = await service.binaryPath
            let ver = await service.version()
            let sessionCount = installed ? ((try? await service.listManagedSessions().count) ?? 0) : 0
            await MainActor.run {
                tmuxIsInstalled = installed
                tmuxBinaryPath = binary
                tmuxVersion = ver
                tmuxSessionCount = sessionCount
                if !installed {
                    tmuxEnabled = false
                }
            }
            DeskJigLog.info(.app, "[QuickSwitchSettings] Finished tmux status refresh", fields: ["installed": "\(installed)", "sessions": "\(sessionCount)"])
        }
    }

    private func performTmuxInstall() {
        guard !tmuxInstallInProgress else { return }
        tmuxInstallInProgress = true
        tmuxInstallMessage = nil
        tmuxInstallError = nil

        Task {
            let result = await TmuxCommandService.installViaHomebrew()
            await MainActor.run {
                if result.success {
                    tmuxInstallMessage = result.output
                } else {
                    tmuxInstallError = result.output
                }
                tmuxInstallInProgress = false
            }
            // Refresh tmux info after install attempt
            loadTmuxInfo()
        }
    }

    private func performTmuxReset() {
        guard !tmuxResetInProgress else { return }
        tmuxResetInProgress = true
        tmuxResetMessage = nil
        tmuxResetError = nil

        Task {
            let service = TmuxCommandService()
            do {
                try await service.killServer()
                await MainActor.run {
                    tmuxResetMessage = "All DeskJig-managed tmux sessions have been reset."
                    tmuxResetInProgress = false
                    tmuxSessionCount = 0
                }
            } catch {
                await MainActor.run {
                    tmuxResetError = "Failed to reset: \(error.localizedDescription)"
                    tmuxResetInProgress = false
                }
            }
            // Refresh info after reset
            loadTmuxInfo()
        }
    }
}
