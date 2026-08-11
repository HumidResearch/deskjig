//  PermissionsView.swift
//  DeskJig
//
//  Created by Marco Freedom on 11.09.2025.
//

import SwiftUI
import AppKit
import DeskJigShared

struct PermissionsView: View {
    @State private var viewModel: PermissionsViewModel = .init()
    @EnvironmentObject var windowManager: WindowManager
    
    private let contentBackgroundColor: Color = .white.opacity(0.1)
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        VStack(spacing: 20) {
            // Title
            Text("Welcome to DeskJig!")
                .font(brand: .h3)
                .multilineTextAlignment(.center)
            
            // Subtitle
            Text("DeskJig is the missing workspace manager for MacOS. In order to move and configure your workspaces, we'll need you to grant us permission.")
                .font(brand: .body2)
                .italic()
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
                .padding(.bottom, 20)
            
            // Content
            HStack(spacing: 32) {
                permissionReasonsView
                screenshotView(imageName: "PermissionsScreenshot")
            }
            .frame(width: 800, height: 442)
        }
        .onAppear {
            viewModel.checkPermissions(using: windowManager)
            viewModel.startPolling(using: windowManager)
        }
        .onDisappear {
            viewModel.stopPolling()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                viewModel.checkPermissions(using: windowManager)
                viewModel.startPolling(using: windowManager)
            } else {
                viewModel.stopPolling()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

//  MARK: - Helpers

extension PermissionsView {
    
    private var permissionReasonsView: some View {
        VStack(spacing: 32) {
            // The icon and title
            VStack(spacing: 18) {
                Image("lock_open")

                Text("Grant us Permission")
                    .font(brand: .h3)
            }

            Divider()
                .frame(width: 100)

            VStack(alignment: .leading, spacing: 16) {
                Text("We need these permissions to enable:")
                    .font(brand: .h5)

                // The list of reasons why we need permissions
                Text("Moving windows and apps around when setting up a workspace's layout and configuration.")
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .font(brand: .label3)

                // The buttons
                VStack {
                    permissionButton
                }
                .padding(.top, 16)
            }
            .frame(width: 320)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .frame(height: 440)
        .background(contentBackgroundColor)
        .clipShape(.rect(cornerRadius: 16))
    }

    private var permissionButton: some View {
        let isGranted = viewModel.hasPermissionsLocally

        return Button(
            action: {
                if isGranted {
                    // Permission granted, user clicked Next - now advance
                    DeskJigLog.info(.app, "User clicked Next, advancing to next screen")
                    viewModel.advanceAfterPermissionGranted(using: windowManager)
                } else {
                    viewModel.requestPermission(using: windowManager)
                }
            },
            label: {
                HStack(spacing: 8) {
                    if isGranted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(brand: Font.brandBody(size: 16))
                    }
                    Text(isGranted ? "Next" : "Allow Access")
                }
                .frame(maxWidth: .infinity)
            }
        )
        .buttonStyle(
            .deskJig(
                backgroundStyle: isGranted ? DesignTokens.Brand.accent : DesignTokens.Brand.accentMuted
            )
        )
        .disabled(viewModel.isCheckingPermissions && !isGranted)
        .animation(.smooth(duration: 0.3), value: isGranted)
    }
    
    private func screenshotView(imageName: String) -> some View {
        VStack(spacing: 32) {
            Image(imageName)
                .resizable()
                .aspectRatio(contentMode: .fill)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    @Previewable @State var windowManager: WindowManager = .init()
    PermissionsView()
        .frame(width: 1024, height: 768)
        .background(.black.opacity(0.5))
        .environmentObject(windowManager)
}
