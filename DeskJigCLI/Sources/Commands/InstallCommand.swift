//  InstallCommand.swift
//  DeskJigCLI

import ArgumentParser
import Foundation
import DeskJigShared
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ServiceManagement)
import ServiceManagement
#endif

@objc private protocol DeskJigBlessHelperProtocol {
    func installCLI(sourcePath: String, destinationPath: String, reply: @escaping (Bool, String?) -> Void)
    func removeCLI(destinationPath: String, reply: @escaping (Bool, String?) -> Void)
}

struct InstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install a /usr/local/bin/deskjig symlink"
    )

    @OptionGroup var globalOptions: GlobalOptions

    private static let helperLabel = BundleIdentity.helperBundleID
    private static let installPath = "/usr/local/bin/deskjig"

    mutating func run() async throws {
        let executablePath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path

        let result: CommandResult
        do {
            guard FileManager.default.isExecutableFile(atPath: executablePath) else {
                throw InstallError.bundledMissing
            }

            guard isInstalledInApplicationsFolder() else {
                throw InstallError.requiresApplicationsFolder
            }

            do {
                try blessHelperIfNeeded()
                try await installViaHelper(sourcePath: executablePath, destinationPath: Self.installPath)
            } catch {
                let message = localizedMessage(for: error)
                if message.localizedCaseInsensitiveContains("canceled") || message.localizedCaseInsensitiveContains("denied") {
                    throw error
                }
                try await installViaAppleScript(sourcePath: executablePath, destinationPath: Self.installPath)
            }

            result = .success(action: "install", message: "Installed symlink at \(Self.installPath)")
        } catch {
            let code: ExitCode
            let message = localizedMessage(for: error)
            if message.localizedCaseInsensitiveContains("canceled") || message.localizedCaseInsensitiveContains("denied") {
                code = .permissionDenied
            } else if (error as NSError).domain == NSCocoaErrorDomain {
                code = .permissionDenied
            } else {
                code = .actionFailed
            }
            result = .failure(action: "install", exitCode: code, error: message)
        }

        print(OutputFormatter.format(result, format: globalOptions.format))
        fflush(stdout)
        Foundation.exit(Int32(result.exitCode))
    }

    private func localizedMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func isInstalledInApplicationsFolder() -> Bool {
        let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let path = appURL.path

        #if DEBUG
        if path.contains("/DerivedData/") || path.contains("/Build/Products/") {
            return true
        }
        #endif

        return path.hasPrefix("/Applications/") || path.hasPrefix("/System/Volumes/Data/Applications/")
    }

    private func blessHelperIfNeeded() throws {
        #if canImport(ServiceManagement)
        let service = SMAppService.daemon(plistName: "DeskJigCLIBlessHelper-Launchd.plist")
        try service.register()
        #endif
    }

    private func installViaHelper(sourcePath: String, destinationPath: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let connection = NSXPCConnection(machServiceName: Self.helperLabel, options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: DeskJigBlessHelperProtocol.self)
            connection.resume()

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                connection.invalidate()
                continuation.resume(throwing: InstallError.helperConnectionFailed(error.localizedDescription))
            }

            guard let helper = proxy as? DeskJigBlessHelperProtocol else {
                connection.invalidate()
                continuation.resume(throwing: InstallError.helperConnectionFailed("Invalid helper interface."))
                return
            }

            helper.installCLI(sourcePath: sourcePath, destinationPath: destinationPath) { success, message in
                connection.invalidate()
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: InstallError.helperOperationFailed(message ?? "Installation failed."))
                }
            }
        }
    }

    private func installViaAppleScript(sourcePath: String, destinationPath: String) async throws {
        #if canImport(AppKit)
        let script = """
        do shell script "mkdir -p /usr/local/bin && rm -f \(destinationPath) && ln -sf \(sourcePath) \(destinationPath)" with administrator privileges
        """

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                var scriptError: Error?
                do {
                    try AppleScriptRunner.runInProcess(script)
                } catch {
                    scriptError = error
                }

                // Postcondition first (idempotency): if the symlink exists — e.g.
                // from a previous install — report success even when the script
                // itself failed or could not be compiled.
                if FileManager.default.fileExists(atPath: destinationPath) {
                    continuation.resume()
                    return
                }

                if let appleScriptError = scriptError as? AppleScriptError {
                    if appleScriptError.isUserCanceled {
                        continuation.resume(throwing: InstallError.authorizationFailed("Authorization was canceled."))
                    } else {
                        continuation.resume(throwing: InstallError.helperOperationFailed("AppleScript fallback failed: \(appleScriptError.message)"))
                    }
                    return
                }
                if let scriptError {
                    continuation.resume(throwing: InstallError.helperOperationFailed("AppleScript fallback failed: \(scriptError.localizedDescription)"))
                    return
                }

                continuation.resume(throwing: InstallError.helperOperationFailed("AppleScript fallback completed but symlink not found."))
            }
        }
        #else
        throw InstallError.helperOperationFailed("AppleScript fallback unavailable on this platform.")
        #endif
    }
}

private enum InstallError: LocalizedError {
    case bundledMissing
    case requiresApplicationsFolder
    case authorizationFailed(String)
    case helperConnectionFailed(String)
    case helperOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .bundledMissing:
            return "Bundled deskjig not found."
        case .requiresApplicationsFolder:
            return "DeskJig must be located in /Applications or a debug build location to install deskjig."
        case .authorizationFailed(let message):
            return message
        case .helperConnectionFailed(let message):
            return "Failed to connect to helper: \(message)"
        case .helperOperationFailed(let message):
            return message
        }
    }
}
