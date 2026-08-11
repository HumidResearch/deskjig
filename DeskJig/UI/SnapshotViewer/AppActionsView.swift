//
//  AppActionsView.swift
//  DeskJig
//
//  Actions panel for testing Fluent API app-level operations
//

import SwiftUI
import DeskJigShared

struct AppActionsView: View {
    let window: SnapshotWindow?
    let onRefresh: () -> Void
    @State private var actionInProgress = false
    @State private var lastActionResult: String?
    @State private var appInfo: AppInfoDisplay?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App Actions")
                .font(.headline)

            if window == nil {
                Text("Select a window to perform app actions")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else if let bundleId = window?.bundleId {
                // App Info Section
                if let info = appInfo {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(info.name)
                                .fontWeight(.medium)
                            Spacer()
                            if info.isActive {
                                Text("ACTIVE")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(DesignTokens.Brand.accent.opacity(0.2))
                                    .cornerRadius(4)
                            }
                            if info.isHidden {
                                Text("HIDDEN")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(DesignTokens.Brand.accent.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }
                        Text("PIDs: \(info.processIDs.map { String($0) }.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.secondary.opacity(0.1))
                    .cornerRadius(8)
                }

                // State Actions
                VStack(alignment: .leading, spacing: 6) {
                    Text("State")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 4) {
                        ActionButton(label: "Activate", icon: "star.fill") {
                            performAppAction(bundleId: bundleId) { $0.activate() }
                        }
                        ActionButton(label: "Hide", icon: "eye.slash") {
                            performAppAction(bundleId: bundleId) { $0.hide() }
                        }
                        ActionButton(label: "Unhide", icon: "eye") {
                            performAppAction(bundleId: bundleId) { $0.unhide() }
                        }
                    }
                }

                Divider()

                // Lifecycle Actions
                VStack(alignment: .leading, spacing: 6) {
                    Text("Lifecycle")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 4) {
                        ActionButton(label: "Launch", icon: "play.fill") {
                            performAppAction(bundleId: bundleId) { $0.launch() }
                        }
                    }

                    HStack(spacing: 4) {
                        ActionButton(label: "Terminate", icon: "stop.fill", destructive: true) {
                            performAppAction(bundleId: bundleId) { $0.terminate() }
                        }
                        ActionButton(label: "Force Quit", icon: "xmark.octagon.fill", destructive: true) {
                            performAppAction(bundleId: bundleId) { $0.forceTerminate() }
                        }
                    }
                }

                Divider()

                // Window Discovery
                VStack(alignment: .leading, spacing: 6) {
                    Text("Window Discovery")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 4) {
                        Button {
                            queryWindows(bundleId: bundleId)
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "square.stack.3d.up")
                                    .font(.caption)
                                Text("List Windows")
                                    .font(.caption2)
                            }
                            .frame(minWidth: 80, minHeight: 40)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            queryFirstWindow(bundleId: bundleId)
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "1.square")
                                    .font(.caption)
                                Text("First Window")
                                    .font(.caption2)
                            }
                            .frame(minWidth: 80, minHeight: 40)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // Status
                if actionInProgress {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Performing action...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let result = lastActionResult {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.contains("Failed") || result.contains("not found") ? DesignTokens.Status.error : DesignTokens.Brand.accent)
                        .lineLimit(3)
                }
            } else {
                Text("No bundle ID available for this window")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .disabled(window == nil || actionInProgress)
        .onChange(of: window?.bundleId) { _, newBundleId in
            if let bundleId = newBundleId {
                refreshAppInfo(bundleId: bundleId)
            } else {
                appInfo = nil
            }
        }
        .onAppear {
            if let bundleId = window?.bundleId {
                refreshAppInfo(bundleId: bundleId)
            }
        }
    }

    private func refreshAppInfo(bundleId: String) {
        if let appHandle = App.find(bundleID: bundleId) {
            appInfo = AppInfoDisplay(
                name: appHandle.localizedName ?? "Unknown",
                isRunning: appHandle.isRunning,
                isHidden: appHandle.isHidden,
                isActive: appHandle.isActive,
                processIDs: appHandle.processIDs
            )
        } else {
            appInfo = nil
        }
    }

    private func performAppAction(bundleId: String, _ action: @escaping (AppHandle) -> AppHandle?) {
        actionInProgress = true
        lastActionResult = nil

        Task { @MainActor in
            if let appHandle = App.find(bundleID: bundleId) {
                let result = action(appHandle)
                if result != nil {
                    lastActionResult = "Success"
                    // Show red border highlight around the selected window
                    if let windowFrame = window?.frame {
                        WindowHighlightOverlay.shared.showHighlight(around: windowFrame)
                    }
                } else {
                    lastActionResult = "Action returned nil"
                }
            } else {
                lastActionResult = "App not found"
            }

            await Task.sleepUnlessCancelled(for: .milliseconds(300))
            if let bundleId = window?.bundleId {
                refreshAppInfo(bundleId: bundleId)
            }
            onRefresh()
            actionInProgress = false
        }
    }

    private func queryWindows(bundleId: String) {
        if let appHandle = App.find(bundleID: bundleId) {
            let windows = appHandle.windows()
            lastActionResult = "Found \(windows.count) windows"
        } else {
            lastActionResult = "App not found"
        }
    }

    private func queryFirstWindow(bundleId: String) {
        if let appHandle = App.find(bundleID: bundleId) {
            if let window = appHandle.firstWindow() {
                lastActionResult = "First: \"\(window.title ?? "untitled")\" @ \(Int(window.frame?.width ?? 0))×\(Int(window.frame?.height ?? 0))"
            } else {
                lastActionResult = "No windows found"
            }
        } else {
            lastActionResult = "App not found"
        }
    }
}

struct AppInfoDisplay {
    let name: String
    let isRunning: Bool
    let isHidden: Bool
    let isActive: Bool
    let processIDs: [pid_t]
}