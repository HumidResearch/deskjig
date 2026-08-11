//
//  ChromeConfigurationOverlayView.swift
//  DeskJigShared
//
//  Created by OpenAI Codex on 01.10.2025.
//

import SwiftUI

public struct ChromeConfigurationOverlayView: View {
    @State var configuration: ChromeWindowConfiguration
    let profiles: [ChromeProfile]
    let onRefreshTabs: () -> ChromeAppleScriptWindowCapture?
    let onConfigurationChange: (ChromeWindowConfiguration) -> Void?
    let onDirectoryChange: (String?) -> Void?
    let onHeightChange: ((CGFloat) -> Void)?

    @State private var contentHeight: CGFloat = 0

    private var shouldRestoreBinding: Binding<Bool> {
        Binding<Bool>(
            get: { configuration.shouldRestoreTabs },
            set: { newValue in
                var updatedConfig = configuration
                updatedConfig.shouldRestoreTabs = newValue
                configuration = updatedConfig
                onConfigurationChange(configuration)
            }
        )
    }

    private var profileDirectoryBinding: Binding<String?> {
        Binding<String?>(
            get: { configuration.profileDirectory },
            set: { newValue in
                var updatedConfig = configuration
                updatedConfig.profileDirectory = newValue
                configuration = updatedConfig
                onDirectoryChange(newValue)
            }
        )
    }

    public var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                Text("Chrome Setup")
                    .font(.headline)
                    .foregroundColor(.primary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Profile")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Chrome Profile", selection: profileDirectoryBinding) {
                        ForEach(profiles) { profile in
                            Text(profile.appleScriptName)
                                .tag(profile.directory)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Toggle(isOn: shouldRestoreBinding) {
                    Text("Load with saved tabs")
                }

                if configuration.shouldRestoreTabs {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Saved tabs: \(configuration.savedTabURLs.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if configuration.savedTabURLs.isEmpty {
                            Text("No tabs captured yet")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(configuration.savedTabURLs.prefix(3).enumerated()), id: \.offset) { _, url in
                                    Text(url)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                if configuration.savedTabURLs.count > 3 {
                                    Text("…")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Button(action: {
                            if let capture = onRefreshTabs() {
                                var updatedConfig = configuration
                                updatedConfig.savedTabURLs = capture.tabURLs
                                updatedConfig.savedActiveTabIndex = capture.activeTabIndex
                                updatedConfig.lastCaptureDate = Date()
                                // Update profile info if available
                                if let profileName = capture.profileAppleScriptName,
                                   let profile = profiles.first(where: {
                                       $0.appleScriptName.hasPrefix(profileName)
                                   }) {
                                    updatedConfig.profileAppleScriptName = profileName
                                    if updatedConfig.profileDirectory == nil {
                                        updatedConfig.apply(profile: profile)
                                    }
                                }
                                configuration = updatedConfig
                                onConfigurationChange(configuration)
                            }
                        }) {
                            Label("Refresh from current tabs", systemImage: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.link)
                    }
                } else {
                    Button(action: {
                        // Capture tabs and enable restoration
                        if let capture = onRefreshTabs() {
                            var updatedConfig = configuration
                            updatedConfig.savedTabURLs = capture.tabURLs
                            updatedConfig.savedActiveTabIndex = capture.activeTabIndex
                            updatedConfig.lastCaptureDate = Date()
                            updatedConfig.shouldRestoreTabs = true
                            // Update profile info if available
                            if let profileName = capture.profileAppleScriptName,
                               let profile = profiles.first(where: { $0.appleScriptName == profileName }) {
                                updatedConfig.profileAppleScriptName = profileName
                                if updatedConfig.profileDirectory == nil {
                                    updatedConfig.apply(profile: profile)
                                }
                            }
                            configuration = updatedConfig
                            onConfigurationChange(configuration)
                        }
                    }) {
                        Label("Use current tabs", systemImage: "plus.square.on.square")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.black.opacity(0.25), radius: 18, x: 0, y: 8)
            .background(
                GeometryReader { contentGeometry in
                    Color.clear.preference(
                        key: HeightPreferenceKey.self,
                        value: contentGeometry.size.height
                    )
                }
            )
            .onPreferenceChange(HeightPreferenceKey.self) { newHeight in
                if abs(newHeight - contentHeight) > 1 {
                    contentHeight = newHeight
                    onHeightChange?(newHeight)
                }
            }
        }
        .frame(height: max(contentHeight, 200))
    }
}

// Preference key for tracking height changes
private struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
