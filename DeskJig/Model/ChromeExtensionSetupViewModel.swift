//
//  ChromeExtensionSetupViewModel.swift
//  DeskJig
//
//  View model for Chrome extension setup wizard.
//

import SwiftUI
import DeskJigShared

/// Stages of the Chrome extension setup wizard
public enum ChromeSetupStage: String, CaseIterable, Identifiable {
    case intro           // Welcome, explain what Chrome extension does
    case browserCheck    // Verify a supported browser is installed
    case nativeHost      // Auto-register native host (one-click)
    case installExtension // Guide user to install extension
    case verifyConnection // Verify connection works
    case complete        // Success!

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .intro: return "Chrome Integration"
        case .browserCheck: return "Browser Check"
        case .nativeHost: return "Setup Connection"
        case .installExtension: return "Install Extension"
        case .verifyConnection: return "Verify Connection"
        case .complete: return "Setup Complete"
        }
    }

    public var description: String {
        switch self {
        case .intro:
            return "Enable real-time Chrome tab tracking and workspace restoration"
        case .browserCheck:
            return "Checking for a supported Chromium-based browser"
        case .nativeHost:
            return "Register the native messaging host for DeskJig"
        case .installExtension:
            return "Install the DeskJig extension in your browser"
        case .verifyConnection:
            return "Waiting for the extension to connect"
        case .complete:
            return "Chrome integration is ready to use"
        }
    }

    var next: ChromeSetupStage? {
        guard let index = Self.allCases.firstIndex(of: self),
              index + 1 < Self.allCases.count else { return nil }
        return Self.allCases[index + 1]
    }

    var previous: ChromeSetupStage? {
        guard let index = Self.allCases.firstIndex(of: self),
              index > 0 else { return nil }
        return Self.allCases[index - 1]
    }

    var stepNumber: Int {
        (Self.allCases.firstIndex(of: self) ?? 0) + 1
    }

    static var totalSteps: Int {
        allCases.count
    }
}

@MainActor @Observable
public final class ChromeExtensionSetupViewModel {

    // MARK: - State

    public var isPresented: Bool = false
    public private(set) var currentStage: ChromeSetupStage = .intro

    /// Installed browsers detected
    public private(set) var installedBrowsers: [ChromeBrowser] = []

    /// Selected browser for setup
    public var selectedBrowser: ChromeBrowser?

    /// Native host registration status
    public private(set) var nativeHostRegistered: Bool = false

    /// Whether extension is connected
    public private(set) var isExtensionConnected: Bool = false

    /// Whether an operation is in progress
    public private(set) var isLoading: Bool = false

    /// Error message to display
    public var errorMessage: String?

    /// Connection verification timer
    private var connectionCheckTask: Task<Void, Never>?

    private let setupManager = ChromeExtensionSetupManager.shared

    // MARK: - Dependencies

    private weak var _messagingService: ChromeNativeMessagingServiceProtocol?

    /// The messaging service to use for connection checks
    /// Falls back to the shared holder if not explicitly set
    private var messagingService: ChromeNativeMessagingServiceProtocol? {
        _messagingService ?? ChromeNativeMessagingServiceHolder.shared
    }

    public init(messagingService: ChromeNativeMessagingServiceProtocol? = nil) {
        self._messagingService = messagingService
    }

    // MARK: - Presentation

    /// Present the wizard if setup is incomplete
    public func presentIfNeeded() {
        let status = setupManager.checkSetupStatus(messagingService: messagingService)
        // .versionSkew means connected-but-outdated: the install wizard can't
        // fix that, so it is surfaced in the status view instead (#542).
        guard status != .complete && status != .noBrowserInstalled && status != .versionSkew else {
            return
        }
        present()
    }

    /// Present the wizard
    public func present() {
        currentStage = .intro
        errorMessage = nil
        detectInstalledBrowsers()
        isPresented = true
        DeskJigLog.info(.chrome, "ChromeExtensionSetup: Presenting Chrome extension setup wizard")
    }

    /// Dismiss the wizard
    public func dismiss() {
        connectionCheckTask?.cancel()
        isPresented = false
        DeskJigLog.info(.chrome, "ChromeExtensionSetup: Dismissed Chrome extension setup wizard")
    }

    // MARK: - Navigation

    public func advanceStage() {
        guard let nextStage = currentStage.next else {
            dismiss()
            return
        }

        currentStage = nextStage
        DeskJigLog.info(.chrome, "ChromeExtensionSetup: Advanced to stage: \(nextStage.rawValue)")

        // Auto-advance logic for certain stages
        Task {
            await handleStageEntry(nextStage)
        }
    }

    public func previousStage() {
        guard let prevStage = currentStage.previous else { return }
        currentStage = prevStage
        DeskJigLog.info(.chrome, "ChromeExtensionSetup: Went back to stage: \(prevStage.rawValue)")
    }

    public func skipToComplete() {
        currentStage = .complete
    }

    // MARK: - Stage Handlers

    private func handleStageEntry(_ stage: ChromeSetupStage) async {
        switch stage {
        case .browserCheck:
            detectInstalledBrowsers()
            // Auto-advance if browser found
            if !installedBrowsers.isEmpty {
                selectedBrowser = installedBrowsers.first
                guard await Task.sleepUnlessCancelled(for: .milliseconds(500)) else { return }
                advanceStage()
            }

        case .nativeHost:
            // Check if already registered
            if let browser = selectedBrowser {
                nativeHostRegistered = setupManager.checkNativeHostStatus(for: browser) == .registered
            }

        case .verifyConnection:
            startConnectionVerification()

        case .complete:
            syncSetupCompletion()

        default:
            break
        }
    }

    /// Record Chrome extension setup completion in local tutorial progress.
    private func syncSetupCompletion() {
        TutorialProgressStore.shared.markChromeExtensionSetupCompleted()
        DeskJigLog.info(.chrome, "ChromeExtensionSetup: Recorded Chrome extension setup completion")
    }

    /// Reset Chrome extension setup state (for testing)
    public func resetSetup() async {
        TutorialProgressStore.shared.resetChromeExtensionSetup()
        DeskJigLog.info(.chrome, "ChromeExtensionSetup: Reset Chrome extension setup state")
    }

    // MARK: - Browser Detection

    public func detectInstalledBrowsers() {
        installedBrowsers = ChromeBrowser.installedBrowsers
        if selectedBrowser == nil {
            selectedBrowser = installedBrowsers.first
        }
        let count = installedBrowsers.count
        DeskJigLog.info(.chrome, "ChromeExtensionSetup: Detected \(count) browser(s)")
    }

    // MARK: - Native Host Registration

    public func registerNativeHost() async {
        guard let browser = selectedBrowser else {
            errorMessage = "Please select a browser"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try setupManager.registerNativeHost(for: browser)
            nativeHostRegistered = true
            DeskJigLog.info(.chrome, "ChromeExtensionSetup: Registered native host for \(browser.rawValue)")
        } catch {
            errorMessage = error.localizedDescription
            DeskJigLog.error(.chrome, "ChromeExtensionSetup: Failed to register native host: \(error.localizedDescription)")
        }

        isLoading = false
    }

    public func registerForAllBrowsers() async {
        isLoading = true
        errorMessage = nil

        let results = setupManager.registerNativeHostForAllBrowsers()
        let successCount = results.values.filter { if case .success = $0 { return true }; return false }.count

        if successCount > 0 {
            nativeHostRegistered = true
            DeskJigLog.info(.chrome, "ChromeExtensionSetup: Registered native host for \(successCount) browser(s)")
        } else {
            errorMessage = "Failed to register for any browser"
        }

        isLoading = false
    }

    // MARK: - Connection Verification

    public func startConnectionVerification() {
        connectionCheckTask?.cancel()

        connectionCheckTask = Task {
            // Poll for connection every 2 seconds for up to 60 seconds
            for _ in 0..<30 {
                if Task.isCancelled { return }

                isExtensionConnected = messagingService?.isConnected ?? false

                if isExtensionConnected {
                    DeskJigLog.info(.chrome, "ChromeExtensionSetup: Extension connected!")
                    advanceStage()
                    return
                }

                guard await Task.sleepUnlessCancelled(for: .seconds(2)) else { return }
            }

            // Timeout
            errorMessage = "Connection timed out. Please check that the extension is installed and enabled."
        }
    }

    public func skipConnectionVerification() {
        connectionCheckTask?.cancel()
        advanceStage()
    }

    // MARK: - URLs

    public func openChromeWebStore() {
        NSWorkspace.shared.open(ChromeExtensionConstants.chromeWebStoreURL)
    }

    public func openDeveloperMode() {
        if selectedBrowser != nil {
            let url = URL(string: "chrome://extensions")!
            NSWorkspace.shared.open(url)
        }
    }

    public func openExtensionFolder() {
        // Open Finder showing the ChromeExtension folder with DeskJigForChrome visible inside
        // This makes it easy to drag the DeskJigForChrome folder into Chrome
        let bundledExtensionPath = Bundle.main.resourcePath.map { $0 + "/ChromeExtension/DeskJigForChrome" }
        let bundledParentPath = Bundle.main.resourcePath.map { $0 + "/ChromeExtension" }
        if let path = bundledExtensionPath, let parentPath = bundledParentPath,
           FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: parentPath)
        } else {
            DeskJigLog.error(.chrome, "ChromeExtensionSetup: Bundled Chrome extension folder not found in app resources")
        }
    }

    public func openChromeExtensionsPage() {
        // Open chrome://extensions in the default browser
        // Note: chrome:// URLs can't be opened directly via NSWorkspace, so we use AppleScript
        do {
            try AppleScriptRunner.runInProcess(ChromeAppleScript.openExtensionsPage)
        } catch {
            DeskJigLog.error(.chrome, "ChromeExtensionSetup: Failed to open chrome://extensions: \(error)")
        }
    }

    // MARK: - Status

    public var overallStatus: ChromeExtensionSetupStatus {
        setupManager.checkSetupStatus(messagingService: messagingService)
    }

    public func refreshStatus() {
        if let browser = selectedBrowser {
            nativeHostRegistered = setupManager.checkNativeHostStatus(for: browser) == .registered
        }
        isExtensionConnected = messagingService?.isConnected ?? false
    }
}
