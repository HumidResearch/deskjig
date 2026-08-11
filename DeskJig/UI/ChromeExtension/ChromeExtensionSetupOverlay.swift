//
//  ChromeExtensionSetupOverlay.swift
//  DeskJig
//
//  Setup wizard overlay for Chrome extension integration.
//

import SwiftUI
import DeskJigShared

struct ChromeExtensionSetupOverlay: View {
    @Bindable var viewModel: ChromeExtensionSetupViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header with progress
            headerView

            Divider()
                .background(DesignTokens.Border.subtle)

            // Stage content
            ScrollView {
                stageContent
                    .padding(24)
            }

            Divider()
                .background(DesignTokens.Border.subtle)

            // Navigation buttons
            navigationButtons
                .padding(16)
        }
        .frame(width: 500, height: 450)
        .background(BlurBackdrop())
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 8) {
            Text(viewModel.currentStage.title)
                .font(brand: .h4)
                .foregroundStyle(DesignTokens.Text.primary)

            Text(viewModel.currentStage.description)
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
                .multilineTextAlignment(.center)

            // Progress indicator
            HStack(spacing: 4) {
                ForEach(ChromeSetupStage.allCases) { stage in
                    Circle()
                        .fill(stageColor(stage))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.top, 8)
        }
        .padding(16)
    }

    private func stageColor(_ stage: ChromeSetupStage) -> Color {
        if stage == viewModel.currentStage {
            return DesignTokens.Brand.accent
        } else if stage.stepNumber < viewModel.currentStage.stepNumber {
            return DesignTokens.Status.success
        } else {
            return DesignTokens.Text.muted
        }
    }

    // MARK: - Stage Content

    @ViewBuilder
    private var stageContent: some View {
        switch viewModel.currentStage {
        case .intro:
            introContent
        case .browserCheck:
            browserCheckContent
        case .nativeHost:
            nativeHostContent
        case .installExtension:
            installExtensionContent
        case .verifyConnection:
            verifyConnectionContent
        case .complete:
            completeContent
        }
    }

    private var introContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: DesignTokens.IconSize.xxxLarge))
                .foregroundStyle(DesignTokens.Status.info)

            Text("Real-time Chrome Integration")
                .font(brand: .h4)
                .foregroundStyle(DesignTokens.Text.primary)

            VStack(alignment: .leading, spacing: 8) {
                featureRow(icon: "arrow.clockwise", text: "Live tab synchronization")
                featureRow(icon: "square.stack.3d.up", text: "Restore Chrome tabs with workspaces")
                featureRow(icon: "rectangle.stack", text: "Tab group management")
                featureRow(icon: "bolt.fill", text: "Instant window state updates")
            }
            .padding()
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(DesignTokens.Surface.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(DesignTokens.Border.subtle, lineWidth: 1)
            }
        }
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(DesignTokens.Status.info)
                .frame(width: 24)
            Text(text)
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.primary)
        }
    }

    private var browserCheckContent: some View {
        VStack(spacing: 16) {
            if viewModel.installedBrowsers.isEmpty {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: DesignTokens.IconSize.xxxLarge))
                    .foregroundStyle(DesignTokens.Status.warning)

                Text("No supported browser found")
                    .font(brand: .h4)
                    .foregroundStyle(DesignTokens.Text.primary)

                Text("Please install Google Chrome, Brave, or another Chromium-based browser to continue.")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: DesignTokens.IconSize.xxxLarge))
                    .foregroundStyle(DesignTokens.Status.success)

                Text("Browser detected")
                    .font(brand: .h4)
                    .foregroundStyle(DesignTokens.Text.primary)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.installedBrowsers) { browser in
                        HStack {
                            Image(systemName: "app.fill")
                                .foregroundStyle(DesignTokens.Text.secondary)
                            Text(browser.rawValue)
                                .font(brand: .body3)
                                .foregroundStyle(DesignTokens.Text.primary)
                            Spacer()
                            if browser == viewModel.selectedBrowser {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(DesignTokens.Status.success)
                            }
                        }
                        .padding(8)
                        .background {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(browser == viewModel.selectedBrowser ? DesignTokens.Brand.accent.opacity(0.1) : Color.clear)
                        }
                        .onTapGesture {
                            viewModel.selectedBrowser = browser
                        }
                    }
                }
                .padding()
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DesignTokens.Surface.card)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                }
            }
        }
    }

    private var nativeHostContent: some View {
        VStack(spacing: 16) {
            if viewModel.nativeHostRegistered {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: DesignTokens.IconSize.xxxLarge))
                    .foregroundStyle(DesignTokens.Status.success)

                Text("Native host registered")
                    .font(brand: .h4)
                    .foregroundStyle(DesignTokens.Text.primary)

                Text("DeskJig can now communicate with your browser.")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)
            } else {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: DesignTokens.IconSize.xxxLarge))
                    .foregroundStyle(DesignTokens.Status.info)

                Text("Register Native Host")
                    .font(brand: .h4)
                    .foregroundStyle(DesignTokens.Text.primary)

                Text("This allows DeskJig to communicate with Chrome through a secure local connection.")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .multilineTextAlignment(.center)

                Button {
                    Task { await viewModel.registerNativeHost() }
                } label: {
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Register Native Host", systemImage: "link.badge.plus")
                    }
                }
                .buttonStyle(.dsAccent(size: .small))
                .disabled(viewModel.isLoading)

                if let browser = viewModel.selectedBrowser {
                    Text("For \(browser.rawValue)")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                }
            }

            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.Status.error)
                    Text(error)
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Status.error)
                }
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(DesignTokens.Status.error.opacity(0.1))
                }
            }
        }
    }

    private var installExtensionContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: DesignTokens.IconSize.xxxLarge))
                .foregroundStyle(DesignTokens.Status.info)

            Text("Install the DeskJig Extension")
                .font(brand: .h4)
                .foregroundStyle(DesignTokens.Text.primary)

            Text("Choose how you'd like to install the extension:")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)

            VStack(spacing: 12) {
                // Chrome Web Store option - Coming Soon
                HStack {
                    Image(systemName: "bag.fill")
                        .frame(width: 24)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                    VStack(alignment: .leading) {
                        Text("Chrome Web Store")
                            .font(brand: .body3)
                            .foregroundStyle(DesignTokens.Text.primary)
                        Text("Coming Soon")
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.tertiary)
                    }
                    Spacer()
                    Text("Coming Soon")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(DesignTokens.Border.subtle)
                        }
                }
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DesignTokens.Surface.card)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                }
                .opacity(0.6)

                // Developer mode option - Now the primary option
                DisclosureGroup(isExpanded: .constant(true)) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Early preview explanation
                        Text("This is an early preview feature. The extension must be installed manually using Chrome's developer mode.")
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.secondary)
                            .padding(8)
                            .background {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(DesignTokens.Status.info.opacity(0.1))
                            }

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 4) {
                                Text("1.")
                                    .font(brand: .body4)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Open Chrome Extensions page")
                                    Button {
                                        viewModel.openChromeExtensionsPage()
                                    } label: {
                                        Text("Open chrome://extensions →")
                                            .font(brand: .body4)
                                    }
                                    .buttonStyle(.link)
                                }
                            }
                            HStack(alignment: .top, spacing: 4) {
                                Text("2.")
                                    .font(brand: .body4)
                                Text("Enable 'Developer mode' toggle (top right corner)")
                            }
                            HStack(alignment: .top, spacing: 4) {
                                Text("3.")
                                    .font(brand: .body4)
                                Text("Click 'Load unpacked' button")
                            }
                            HStack(alignment: .top, spacing: 4) {
                                Text("4.")
                                    .font(brand: .body4)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Drag the 'DeskJigForChrome' folder into Chrome's file picker")
                                    Text("(or navigate to select it)")
                                        .foregroundStyle(DesignTokens.Text.tertiary)
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            Button {
                                viewModel.openExtensionFolder()
                            } label: {
                                Label("Show Extension Folder", systemImage: "folder")
                            }
                            .buttonStyle(.dsSecondary(size: .small))

                            Button {
                                viewModel.openChromeExtensionsPage()
                            } label: {
                                Label("Open Extensions Page", systemImage: "safari")
                            }
                            .buttonStyle(.dsSecondary(size: .small))
                        }
                    }
                    .font(brand: .body4)
                    .padding(.top, 8)
                } label: {
                    Text("Developer Mode")
                        .font(brand: .body3)
                        .foregroundStyle(DesignTokens.Text.primary)
                }
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(DesignTokens.Brand.accent.opacity(0.1))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DesignTokens.Border.subtle, lineWidth: 1)
                }
            }
        }
    }

    private var verifyConnectionContent: some View {
        VStack(spacing: 16) {
            if viewModel.isExtensionConnected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: DesignTokens.IconSize.xxxLarge))
                    .foregroundStyle(DesignTokens.Status.success)

                Text("Connected!")
                    .font(brand: .h4)
                    .foregroundStyle(DesignTokens.Text.primary)
            } else {
                ProgressView()
                    .scaleEffect(1.5)

                Text("Waiting for extension...")
                    .font(brand: .h4)
                    .foregroundStyle(DesignTokens.Text.primary)

                Text("Make sure the extension is installed and enabled in your browser.")
                    .font(brand: .body3)
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .multilineTextAlignment(.center)

                Button("Skip for now") {
                    viewModel.skipConnectionVerification()
                }
                .buttonStyle(.dsSecondary(size: .small))
            }

            if let error = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignTokens.Status.warning)
                    Text(error)
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Status.warning)
                }
                .padding(8)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(DesignTokens.Status.warning.opacity(0.1))
                }
            }
        }
    }

    private var completeContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: DesignTokens.IconSize.xxxLarge))
                .foregroundStyle(DesignTokens.Status.success)

            Text("Setup Complete!")
                .font(brand: .h4)
                .foregroundStyle(DesignTokens.Text.primary)

            Text("Chrome integration is now active. Your tabs will sync in real-time.")
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                checkItem("Native host registered", checked: viewModel.nativeHostRegistered)
                checkItem("Extension connected", checked: viewModel.isExtensionConnected)
            }
            .padding()
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(DesignTokens.Surface.card)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(DesignTokens.Border.subtle, lineWidth: 1)
            }
        }
    }

    private func checkItem(_ text: String, checked: Bool) -> some View {
        HStack {
            Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(checked ? DesignTokens.Status.success : DesignTokens.Text.tertiary)
            Text(text)
                .font(brand: .body3)
                .foregroundStyle(DesignTokens.Text.primary)
        }
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack {
            // Back button (not on first or last stage)
            if viewModel.currentStage != .intro && viewModel.currentStage != .complete {
                Button("Back") {
                    viewModel.previousStage()
                }
                .buttonStyle(.dsSecondary(size: .small))
            }

            Spacer()

            // Skip/Cancel
            if viewModel.currentStage != .complete {
                Button("Cancel") {
                    viewModel.dismiss()
                }
                .buttonStyle(.dsSecondary(size: .small))
            }

            // Next/Done
            Button(nextButtonTitle) {
                if viewModel.currentStage == .complete {
                    viewModel.dismiss()
                } else {
                    viewModel.advanceStage()
                }
            }
            .buttonStyle(.dsAccent(size: .small))
            .disabled(isNextDisabled)
        }
    }

    private var nextButtonTitle: String {
        switch viewModel.currentStage {
        case .intro: return "Get Started"
        case .complete: return "Done"
        default: return "Continue"
        }
    }

    private var isNextDisabled: Bool {
        switch viewModel.currentStage {
        case .browserCheck:
            return viewModel.installedBrowsers.isEmpty
        case .nativeHost:
            return !viewModel.nativeHostRegistered && !viewModel.isLoading
        case .verifyConnection:
            return false // Can always skip
        default:
            return false
        }
    }
}

#Preview {
    ChromeExtensionSetupOverlay(viewModel: ChromeExtensionSetupViewModel())
}
