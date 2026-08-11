//
//  DSFolderPicker.swift
//  DeskJig
//
//  Created by Claude Code on 02/02/26.
//

import SwiftUI
import AppKit
import DeskJigShared

/// Verification status for folder picker paths.
enum DSFolderVerificationStatus: Equatable {
    /// No verification performed yet
    case none
    /// Currently verifying the path
    case verifying
    /// Path verified successfully
    case verified
    /// Path verification failed
    case failed(String)

    var icon: String? {
        switch self {
        case .none:
            return nil
        case .verifying:
            return nil // Uses ProgressView instead
        case .verified:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .none:
            return DesignTokens.Text.tertiary
        case .verifying:
            return DesignTokens.Text.secondary
        case .verified:
            return DesignTokens.Status.success
        case .failed:
            return DesignTokens.Status.error
        }
    }

    var message: String? {
        switch self {
        case .none:
            return nil
        case .verifying:
            return "Verifying..."
        case .verified:
            return "Path verified"
        case .failed(let reason):
            return reason
        }
    }
}

/// A path input with folder browser and verification.
///
/// Features:
/// - Text input for path
/// - Browse button to open NSOpenPanel
/// - Optional verify button
/// - Verification status display
///
/// Layout: `[Folder icon][Path input][Browse btn][Verify btn]`
///
/// Usage:
/// ```swift
/// DSFolderPicker(
///     path: $projectPath,
///     placeholder: "/path/to/project",
///     verificationStatus: .verified,
///     onBrowse: { /* custom browse handler */ },
///     onVerify: { path in /* verify the path */ }
/// )
/// ```
struct DSFolderPicker: View {
    @Binding var path: String
    var placeholder: String = "Select a folder..."
    var verificationStatus: DSFolderVerificationStatus = .none
    var onBrowse: (() -> Void)? = nil
    var onVerify: ((String) -> Void)? = nil
    var onFocusChange: ((Bool) -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.gapTiny) {
            HStack(spacing: DesignTokens.Spacing.gapSmall) {
                // Path input with folder icon - takes remaining space
                HStack(spacing: 0) {
                    Image(systemName: "folder")
                        .font(.system(size: DesignTokens.IconSize.medium))
                        .foregroundStyle(DesignTokens.Text.tertiary)
                        .frame(width: 32)

                    TextField(placeholder, text: $path)
                        .textFieldStyle(.plain)
                        .font(brand: .body2)
                        .foregroundStyle(DesignTokens.Text.primary)
                        .focused($isFocused)
                        .onChange(of: isFocused) { _, newValue in
                            onFocusChange?(newValue)
                        }

                    // Verification status icon
                    if verificationStatus == .verifying {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 24)
                    } else if let icon = verificationStatus.icon {
                        Image(systemName: icon)
                            .font(.system(size: DesignTokens.IconSize.medium))
                            .foregroundStyle(verificationStatus.color)
                            .frame(width: 24)
                    }
                }
                .padding(.horizontal, DesignTokens.Form.inputPaddingHorizontal)
                .frame(height: DesignTokens.Form.inputHeight)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.Form.cornerRadius)
                        .fill(DesignTokens.Surface.input)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Form.cornerRadius)
                        .stroke(
                            isFocused ? DesignTokens.Brand.accent : borderColor,
                            lineWidth: isFocused ? DesignTokens.Form.focusRingWidth : 1
                        )
                )
                .animation(.easeInOut(duration: 0.15), value: isFocused)

                // Browse button - natural width, matches input height
                Button("Browse") {
                    if let onBrowse {
                        onBrowse()
                    } else {
                        openFolderPanel()
                    }
                }
                .buttonStyle(.dsButton(variant: .secondary, size: .medium, formHeight: true))
                .frame(height: DesignTokens.Form.inputHeight)
                .fixedSize(horizontal: true, vertical: false)

                // Verify button (if handler provided) - natural width, matches input height
                if let onVerify {
                    Button {
                        onVerify(path)
                    } label: {
                        Group {
                            switch verificationStatus {
                            case .verifying:
                                ProgressView()
                                    .controlSize(.small)
                            case .verified:
                                Image(systemName: "checkmark")
                                    .foregroundStyle(DesignTokens.Text.primary)
                            default:
                                Text("Verify")
                            }
                        }
                    }
                    .buttonStyle(.dsButton(
                        variant: verificationStatus == .verified ? .success : .tertiary,
                        size: .medium,
                        formHeight: true
                    ))
                    .frame(height: DesignTokens.Form.inputHeight)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(path.isEmpty || verificationStatus == .verifying)
                }
            }

            // Status message
            if let message = verificationStatus.message {
                HStack(spacing: DesignTokens.Spacing.gapTiny) {
                    if let icon = verificationStatus.icon {
                        Image(systemName: icon)
                            .font(.system(size: DesignTokens.IconSize.tiny))
                    } else if verificationStatus == .verifying {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(message)
                }
                .font(brand: .body4)
                .foregroundStyle(verificationStatus.color)
            }
        }
    }

    private var borderColor: Color {
        switch verificationStatus {
        case .verified:
            return DesignTokens.Status.success
        case .failed:
            return DesignTokens.Status.error
        default:
            return DesignTokens.Border.subtle
        }
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Select"
        panel.message = "Choose a folder"

        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 32) {
        Text("Folder Pickers")
            .font(brand: .h4)
            .foregroundStyle(DesignTokens.Text.primary)

        VStack(alignment: .leading, spacing: 8) {
            Text("Empty")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            DSFolderPicker(
                path: .constant(""),
                placeholder: "/path/to/project"
            )
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("With Path")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            DSFolderPicker(
                path: .constant("/Users/developer/projects/myapp"),
                verificationStatus: .none
            )
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Verifying")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            DSFolderPicker(
                path: .constant("/Users/developer/projects"),
                verificationStatus: .verifying,
                onVerify: { _ in }
            )
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Verified")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            DSFolderPicker(
                path: .constant("/Users/developer/projects/myapp"),
                verificationStatus: .verified,
                onVerify: { _ in }
            )
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Failed")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
            DSFolderPicker(
                path: .constant("/invalid/path"),
                verificationStatus: .failed("Directory does not exist"),
                onVerify: { _ in }
            )
        }
    }
    .padding(32)
    .frame(width: 600)
    .background(Color.black.opacity(0.9))
}
