//  OpenByPathWindowDetailPanel.swift
//  DeskJig
//
//  Per-window configuration UI for apps that support "open by path" restoration.
//

import SwiftUI
import DeskJigShared

struct OpenByPathWindowDetailPanel: View {
    let window: WorkspaceWindow
    let initialModification: OpenByPathWindowModification?
    let onModificationChanged: (OpenByPathWindowModification) -> Void
    let onDismiss: () -> Void

    @State private var openPathInput: String = ""
    @State private var verification: VerificationState = .unknown
    @State private var isVerifying: Bool = false

    enum VerificationState: Equatable {
        case unknown
        case valid(resolvedPath: String)
        case invalid(message: String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            VStack(alignment: .leading, spacing: 8) {
                Text("Open directory")
                    .font(brand: .label2)
                    .foregroundStyle(DesignTokens.Text.secondary)

                TextField("~/code/my-project", text: $openPathInput)
                    .font(brand: Font.brandBody(size: 12))
                    .foregroundStyle(DesignTokens.Text.primary)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignTokens.Surface.input)
                            .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                    }

                HStack(spacing: 10) {
                    Button(action: verifyPath) {
                        HStack(spacing: 6) {
                            if isVerifying {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(DesignTokens.Text.secondary)
                            } else {
                                Image(systemName: "checkmark.seal")
                                    .font(brand: Font.brandBody(size: 12))
                                    .foregroundStyle(DesignTokens.Text.secondary)
                            }
                            Text("Verify")
                                .font(brand: .label2)
                                .foregroundStyle(DesignTokens.Text.primary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background {
                            Capsule()
                                .fill(DesignTokens.Surface.elevated)
                        }
                    }
                    .buttonStyle(.plain)

                    Button(action: clearPath) {
                        Text("Clear")
                            .font(brand: .label2)
                            .foregroundStyle(DesignTokens.Text.primary)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background {
                                Capsule()
                                    .fill(DesignTokens.Surface.elevated)
                            }
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }

                verificationView
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                .fill(DesignTokens.Surface.card)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius)
                        .stroke(DesignTokens.Border.regular, lineWidth: 1)
                )
        }
        .onAppear {
            openPathInput = initialOpenPath
            notifyModificationChanged()
        }
        .onChange(of: openPathInput) { _, _ in
            verification = .unknown
            notifyModificationChanged()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(displayName(for: window.bundleIdentifier)) • Open by Path")
                    .font(brand: .h4)
                    .foregroundStyle(DesignTokens.Text.primary)

                Text(window.windowTitle.isEmpty ? "Window" : window.windowTitle)
                    .font(brand: Font.brandBody(size: 10))
                    .foregroundStyle(DesignTokens.Text.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(brand: Font.brandBody(size: 20))
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .brightenOnHover()
            }
            .buttonStyle(.plain)
        }
    }

    private var initialOpenPath: String {
        if let openPath = initialModification?.openPath, !openPath.isEmpty {
            return openPath
        }
        return window.openPath ?? ""
    }

    private var verificationView: some View {
        Group {
            switch verification {
            case .unknown:
                Text("Use `~/…` or `/…` and verify it exists.")
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Text.tertiary)
            case .valid(let resolvedPath):
                Label("Found: \(resolvedPath)", systemImage: "checkmark.circle.fill")
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Status.success)
            case .invalid(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(brand: .label3)
                    .foregroundStyle(DesignTokens.Status.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func clearPath() {
        openPathInput = ""
        verification = .unknown
        notifyModificationChanged()
    }

    private func verifyPath() {
        isVerifying = true
        defer { isVerifying = false }

        let trimmed = openPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            verification = .invalid(message: "Enter a path to verify.")
            return
        }

        guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else {
            verification = .invalid(message: "Path must start with `~/` or `/`.")
            return
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            verification = .invalid(message: "Path does not exist.")
            return
        }
        guard isDirectory.boolValue else {
            verification = .invalid(message: "Path is not a directory.")
            return
        }

        verification = .valid(resolvedPath: url.path)
    }

    private func notifyModificationChanged() {
        let trimmed = openPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let openPath = trimmed.isEmpty ? nil : trimmed

        let modification = OpenByPathWindowModification(
            bundleIdentifier: window.bundleIdentifier,
            windowTitle: window.windowTitle,
            openPath: openPath
        )

        onModificationChanged(modification)
    }

    private func displayName(for bundleIdentifier: String) -> String {
        switch bundleIdentifier {
        case OpenByPathBundleIdentifiers.cursor:
            return "Cursor"
        case OpenByPathBundleIdentifiers.codex:
            return "Codex"
        case OpenByPathBundleIdentifiers.ghostty:
            return "Ghostty"
        case OpenByPathBundleIdentifiers.vscode:
            return "VS Code"
        case OpenByPathBundleIdentifiers.terminal:
            return "Terminal"
        case OpenByPathBundleIdentifiers.iterm2:
            return "iTerm"
        case OpenByPathBundleIdentifiers.kitty:
            return "kitty"
        case OpenByPathBundleIdentifiers.alacritty:
            return "Alacritty"
        case OpenByPathBundleIdentifiers.xcode:
            return "Xcode"
        default:
            return window.appName
        }
    }
}
