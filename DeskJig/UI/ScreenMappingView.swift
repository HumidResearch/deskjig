//  ScreenMappingView.swift
//  DeskJig
//
//  Created by AI Assistant on 21.10.2025.
//

import SwiftUI
import DeskJigShared

/// Mapping from workspace screen index to current screen index
struct ScreenMapping {
    let workspaceScreenIndex: Int
    var currentScreenIndex: Int
}

struct ScreenMappingView: View {
    let workspace: Workspace
    let currentScreens: [FullScreenInfo]
    let onRestore: ([ScreenMapping]) -> Void
    let onCancel: () -> Void

    @State private var mappings: [ScreenMapping] = []
    @FocusState private var isFocused: Bool

    init(
        workspace: Workspace,
        currentScreens: [FullScreenInfo],
        onRestore: @escaping ([ScreenMapping]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.workspace = workspace
        self.currentScreens = currentScreens
        self.onRestore = onRestore
        self.onCancel = onCancel

        // Initialize mappings with best matches
        let workspaceScreens = workspace.screens ?? []
        _mappings = State(initialValue: workspaceScreens.enumerated().map { index, savedScreen in
            // Try to find matching screen by display ID, then by primary, then use first
            let matchIndex: Int
            if let match = currentScreens.firstIndex(where: { $0.displayID == savedScreen.displayID }) {
                matchIndex = match
            } else if savedScreen.isPrimary, let primary = currentScreens.firstIndex(where: { $0.isPrimary }) {
                matchIndex = primary
            } else {
                matchIndex = 0
            }
            return ScreenMapping(workspaceScreenIndex: index, currentScreenIndex: matchIndex)
        })
    }

    var body: some View {
        VStack(spacing: 24) {
            // Title and info
            VStack(spacing: 12) {
                Text("Restore to Selected Displays")
                    .font(brand: Font.brandBody(size: 28))
                    .foregroundColor(DesignTokens.Text.primary)

                Text("Map workspace displays to your current displays")
                    .font(brand: Font.brandBody(size: 14))
                    .foregroundColor(DesignTokens.Text.primary.opacity(0.7))
            }

            // Display workspace info
            VStack(alignment: .leading, spacing: 8) {
                Text("Workspace: \(workspace.name)")
                    .font(brand: Font.brandBody(size: 16))
                    .foregroundColor(DesignTokens.Text.primary)

                Text("\(workspace.windows.count) window(s)")
                    .font(brand: Font.brandBody(size: 14))
                    .foregroundColor(DesignTokens.Text.primary.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.1))
            )

            Divider()
                .background(Color.white.opacity(0.2))

            // Screen mappings
            if let workspaceScreens = workspace.screens, !workspaceScreens.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Display Mapping")
                        .font(brand: Font.brandBody(size: 18))
                        .foregroundColor(DesignTokens.Text.primary)

                    ForEach(workspaceScreens.indices, id: \.self) { index in
                        screenMappingRow(
                            workspaceScreen: workspaceScreens[index],
                            workspaceIndex: index
                        )
                    }
                }
            } else {
                // No screen info available - show warning
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(brand: Font.brandBody(size: 32))
                        .foregroundColor(DesignTokens.Brand.accent)

                    Text("No Display Information")
                        .font(brand: Font.brandBody(size: 16))
                        .foregroundColor(DesignTokens.Text.primary)

                    Text("This workspace was saved without display information. It will be restored using the original absolute positions.")
                        .font(brand: Font.brandBody(size: 14))
                        .foregroundColor(DesignTokens.Text.primary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DesignTokens.Brand.accent.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(DesignTokens.Brand.accent.opacity(0.3), lineWidth: 1)
                        )
                )
            }

            Spacer()

            // Action buttons
            HStack(spacing: 16) {
                Button(action: onCancel) {
                    Text("Cancel")
                        .font(brand: Font.brandBody(size: 16))
                        .foregroundColor(DesignTokens.Text.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button(action: { onRestore(mappings) }) {
                    Text("Restore Workspace")
                        .font(brand: Font.brandBody(size: 16))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.white)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 600)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onAppear {
            isFocused = true
        }
    }

    @ViewBuilder
    private func screenMappingRow(workspaceScreen: WorkspaceScreen, workspaceIndex: Int) -> some View {
        HStack(spacing: 16) {
            // Source display
            VStack(alignment: .leading, spacing: 4) {
                Text("Source")
                    .font(brand: Font.brandBody(size: 12))
                    .foregroundColor(DesignTokens.Text.primary.opacity(0.6))

                Text("Monitor \(workspaceIndex + 1)")
                    .font(brand: Font.brandBody(size: 14))
                    .foregroundColor(DesignTokens.Text.primary)

                Text("\(Int(workspaceScreen.resolution.width))×\(Int(workspaceScreen.resolution.height))")
                    .font(brand: Font.brandBody(size: 12))
                    .foregroundColor(DesignTokens.Text.primary.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.05))
            )

            // Arrow
            Image(systemName: "arrow.right")
                .font(brand: Font.brandBody(size: 16))
                .foregroundColor(DesignTokens.Text.primary.opacity(0.5))

            // Target display picker
            VStack(alignment: .leading, spacing: 4) {
                Text("Target")
                    .font(brand: Font.brandBody(size: 12))
                    .foregroundColor(DesignTokens.Text.primary.opacity(0.6))

                Picker("", selection: Binding(
                    get: { mappings[workspaceIndex].currentScreenIndex },
                    set: { newValue in
                        mappings[workspaceIndex].currentScreenIndex = newValue
                    }
                )) {
                    ForEach(currentScreens.indices, id: \.self) { index in
                        Text("Monitor \(index + 1)")
                            .tag(index)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
            )
        }
    }
}

//#Preview {
//    let workspace = Workspace(
//        name: "Test Workspace",
//        workspaceWindows: [],
//        screens: [
//            WorkspaceScreen(
//                displayID: 1,
//                name: "LG UltraWide",
//                resolution: CGSize(width: 3440, height: 1440),
//                frame: CGRect(x: 0, y: 0, width: 3440, height: 1440),
//                visibleFrame: CGRect(x: 0, y: 0, width: 3440, height: 1415),
//                isPrimary: true
//            ),
//            WorkspaceScreen(
//                displayID: 2,
//                name: "MacBook Pro",
//                resolution: CGSize(width: 1680, height: 1050),
//                frame: CGRect(x: -1680, y: 390, width: 1680, height: 1050),
//                visibleFrame: CGRect(x: -1680, y: 390, width: 1680, height: 1025),
//                isPrimary: false
//            )
//        ]
//    )
//
//    let currentScreens = [
//        FullScreenInfo(
//            displayID: 1,
//            name: "LG UltraWide",
//            resolution: CGSize(width: 3440, height: 1440),
//            frame: CGRect(x: 0, y: 0, width: 3440, height: 1440),
//            visibleFrame: CGRect(x: 0, y: 0, width: 3440, height: 1415),
//            isPrimary: true
//        )
//    ]
//
//    ScreenMappingView(
//        workspace: workspace,
//        currentScreens: currentScreens,
//        onRestore: { mappings in
//            print("Restore with mappings: \(mappings)")
//        },
//        onCancel: {
//            print("Cancelled")
//        }
//    )
//    .background(Color.black)
//}
