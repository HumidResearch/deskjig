//
//  LaunchConfigurationSection.swift
//  DeskJig
//
//  Inline section for configuring global launch options.
//  Settings are one-time use and reset when a different workspace is selected.
//

import SwiftUI
import DeskJigShared

struct LaunchConfigurationSection: View {
    @Bindable var strategyManager: LaunchStrategyManager
    let workspace: WorkspaceHandle
    let onLaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Text("Launch Configuration")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            // Options
            VStack(alignment: .leading, spacing: 10) {
                // Window Locks toggle
                Toggle(isOn: $strategyManager.useWindowLocks) {
                    HStack {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Use Window Locks")
                                .font(.subheadline)
                            Text("Prevents window conflicts during restoration")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .toggleStyle(.checkbox)

                // Lock timeout (only shown when locks enabled)
                if strategyManager.useWindowLocks {
                    HStack {
                        Text("Lock Timeout:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $strategyManager.lockTimeout) {
                            Text("5 sec").tag(5)
                            Text("10 sec").tag(10)
                            Text("20 sec").tag(20)
                            Text("30 sec").tag(30)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 80)
                    }
                    .padding(.leading, 24)
                }

                // Execution Mode
                HStack {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Execution Mode")
                            .font(.subheadline)
                        Text(strategyManager.executionMode.description)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Picker("", selection: $strategyManager.executionMode) {
                        ForEach(LaunchExecutionMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                // Dry Run toggle
                Toggle(isOn: $strategyManager.isDryRun) {
                    HStack {
                        Image(systemName: "eye")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Dry Run (Preview Only)")
                                .font(.subheadline)
                            Text("Simulates restoration without launching apps")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(12)
            .background(DesignTokens.Surface.card)
            .cornerRadius(8)

            // Launch button
            HStack {
                Spacer()

                // Reset configuration button
                Button {
                    strategyManager.reset()
                } label: {
                    Label("Reset Config", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Reset all configuration to defaults")

                // Launch button
                Button {
                    onLaunch()
                } label: {
                    HStack {
                        if strategyManager.isLaunching {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: strategyManager.isDryRun ? "eye.fill" : "play.fill")
                        }
                        Text(strategyManager.isDryRun ? "Preview Launch" : "Launch Workspace")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(strategyManager.isLaunching)
            }

            // Per-window overrides summary
            VStack(alignment: .leading, spacing: 4) {
                if !strategyManager.windowStrategies.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.caption2)
                            .foregroundStyle(DesignTokens.Brand.accent)
                        Text("\(strategyManager.windowStrategies.count) window(s) have custom strategies")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !strategyManager.screenOverrides.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "display")
                            .font(.caption2)
                            .foregroundStyle(DesignTokens.Brand.accent)
                        Text("\(strategyManager.screenOverrides.count) window(s) have screen overrides")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    // Create a mock workspace handle (this won't work in preview without FluentServices)
    // Just showing the UI structure
    struct PreviewWrapper: View {
        @State var manager = LaunchStrategyManager()

        var body: some View {
            VStack {
                // Note: This preview won't render properly without a real WorkspaceHandle
                Text("LaunchConfigurationSection Preview")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Launch Configuration")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $manager.useWindowLocks) {
                            HStack {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("Use Window Locks")
                                        .font(.subheadline)
                                    Text("Prevents window conflicts during restoration")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)

                        Toggle(isOn: $manager.isDryRun) {
                            HStack {
                                Image(systemName: "eye")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("Dry Run (Preview Only)")
                                        .font(.subheadline)
                                    Text("Simulates restoration without launching apps")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    .padding(12)
                    .background(DesignTokens.Surface.card)
                    .cornerRadius(8)

                    HStack {
                        Spacer()
                        Button {} label: {
                            HStack {
                                Image(systemName: "play.fill")
                                Text("Launch Workspace")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
            .frame(width: 400)
        }
    }

    return PreviewWrapper()
}