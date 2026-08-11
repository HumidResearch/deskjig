//  URLHandoffCommand.swift
//  DeskJigCLI

import ArgumentParser
import DeskJigShared
import Foundation

enum URLHandoffMode: String, ExpressibleByArgument {
    case auto
    case tabs
    case makeRoom = "make-room"
}

enum URLHandoffDirection: String, ExpressibleByArgument {
    case auto
    case leftToRight = "left-to-right"
    case rightToLeft = "right-to-left"
}

enum URLHandoffDisplacedAnimationMode: String, ExpressibleByArgument {
    case auto
    case on
    case off
}

struct URLHandoffCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "url-handoff",
        abstract: "Open one or more URLs in Chrome without doing a workspace restore",
        discussion: """
        Sends a URL handoff request to DeskJig.app via the bento://url-handoff URL scheme.

        Modes:
          auto      Reuse an existing Chrome window when possible, otherwise make room and open a new Chrome window.
          tabs      Reuse an existing Chrome window (or open a new one if Chrome has no windows).
          make-room Make room by moving the topmost window and opening a new Chrome window on the opposite side.

        Make-room notes:
          --screen uses a 0-based monitor index.
          --direction controls entry motion:
            left-to-right = window enters from the left edge
            right-to-left = window enters from the right edge
          --displaced-animation:
            auto = DeskJig picks behavior
            on   = animate both windows (smoother when AX can keep up, may stutter on some apps)
            off  = animate Chrome only and snap displaced window (more deterministic, less jitter)
          --toast-message/--toast-subtext only apply in make-room mode and gate the restore close flow UI.

        Examples:
          # Safe default: open URL with no forced split
          deskjig url-handoff --url https://github.com/org/repo/pulls

          # Reuse current Chrome window or create one if needed
          deskjig url-handoff --url https://docs.swift.org --mode tabs

          # Make room on monitor 0, entering from the right edge
          deskjig url-handoff --url https://docs.example.com --mode make-room --screen 0 --direction right-to-left

          # Make room on monitor 1, entering from the left edge
          deskjig url-handoff --url https://docs.example.com --mode make-room --screen 1 --direction left-to-right

          # Animate both windows (can be less stable on constrained apps)
          deskjig url-handoff --url https://example.com --mode make-room --displaced-animation on

          # Reduce jitter by snapping displaced window
          deskjig url-handoff --url https://example.com --mode make-room --displaced-animation off

          # Toast-gated close flow in make-room mode
          deskjig url-handoff --url https://api.example.com --mode make-room --toast-message "API docs ready" --toast-subtext "Close preview to restore your layout."

          # Multi-URL handoff
          deskjig url-handoff --url https://example.com --url https://example.com/changelog --mode make-room

          # Requester identity for approval/toast title/icon resolution
          deskjig url-handoff --url https://example.com --mode make-room --requester-bundle-id com.openai.codex --requester-app Codex
        """
    )

    @Option(name: .customLong("url"), parsing: .upToNextOption, help: "URL(s) to hand off (repeatable)")
    var urls: [String] = []

    @Option(name: .customLong("urls"), help: "Comma-separated URLs to hand off")
    var csvURLs: [String] = []

    @Option(name: .customLong("mode"), help: "Handoff mode (auto|tabs|make-room)")
    var mode: URLHandoffMode = .auto

    @Option(name: .customLong("screen"), help: "Target screen index for make-room mode (0-based, left-to-right ordered)")
    var screenIndex: Int?

    @Option(name: .customLong("direction"), help: "Make-room entry motion (auto|left-to-right|right-to-left). left-to-right enters from offscreen left; right-to-left enters from offscreen right. Auto picks the side opposite the displaced window's center.")
    var direction: URLHandoffDirection = .auto

    @Option(name: .customLong("displaced-animation"), help: "Displaced window behavior in make-room mode (auto|on|off). 'on' animates both windows (smoother but may stutter on constrained apps); 'off' snaps displaced window for deterministic timing.")
    var displacedAnimation: URLHandoffDisplacedAnimationMode = .auto

    @Option(name: .customLong("toast-message"), help: "Make-room only: primary message for the close/restore toast shown on the preview window")
    var toastMessage: String?

    @Option(name: .customLong("toast-subtext"), help: "Make-room only: optional supporting text for the close/restore toast")
    var toastSubtext: String?

    @Option(name: .customLong("requester-bundle-id"), help: "Requester bundle identifier for approval toast title/icon")
    var requesterBundleIdentifier: String?

    @Option(name: .customLong("requester-app"), help: "Requester app name shown in the approval toast")
    var requesterAppName: String?

    @Option(name: .customLong("requester-icon-path"), help: "Optional requester app/icon path override")
    var requesterIconPath: String?

    @Option(name: .customLong("cwd"), help: "Directory context (defaults to current working directory)")
    var cwd: String?

    @OptionGroup var globalOptions: GlobalOptions

    mutating func run() async throws {
        let finalURLs = normalizedURLs(urls + csvURLs.flatMap {
            $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        })

        guard !finalURLs.isEmpty else {
            throw ValidationError("--url is required")
        }

        if let screenIndex, screenIndex < 0 {
            throw ValidationError("--screen must be >= 0")
        }

        if mode != .makeRoom {
            if screenIndex != nil || direction != .auto || displacedAnimation != .auto || toastMessage != nil || toastSubtext != nil {
                throw ValidationError("--screen, --direction, --displaced-animation, --toast-message, and --toast-subtext are only valid with --mode make-room")
            }
        }

        let directory = cwd ?? FileManager.default.currentDirectoryPath

        var components = URLComponents()
        components.scheme = BundleIdentity.urlScheme
        components.host = "url-handoff"
        components.queryItems = [
            URLQueryItem(name: "cwd", value: directory),
            URLQueryItem(name: "mode", value: mode.rawValue)
        ]
        if let screenIndex {
            components.queryItems?.append(URLQueryItem(name: "screen", value: String(screenIndex)))
        }
        components.queryItems?.append(URLQueryItem(name: "direction", value: direction.rawValue))
        if mode == .makeRoom {
            switch displacedAnimation {
            case .auto:
                break
            case .on:
                components.queryItems?.append(URLQueryItem(name: "animate_displaced", value: "true"))
            case .off:
                components.queryItems?.append(URLQueryItem(name: "animate_displaced", value: "false"))
            }
        }
        if let toastMessage {
            components.queryItems?.append(URLQueryItem(name: "toast_message", value: toastMessage))
        }
        if let toastSubtext {
            components.queryItems?.append(URLQueryItem(name: "toast_subtext", value: toastSubtext))
        }
        if let requesterBundleIdentifier {
            components.queryItems?.append(URLQueryItem(name: "requester_bundle_id", value: requesterBundleIdentifier))
        }
        if let requesterAppName {
            components.queryItems?.append(URLQueryItem(name: "requester_app_name", value: requesterAppName))
        }
        if let requesterIconPath {
            components.queryItems?.append(URLQueryItem(name: "requester_icon_path", value: requesterIconPath))
        }
        for url in finalURLs {
            components.queryItems?.append(URLQueryItem(name: "url", value: url))
        }

        guard let url = components.url else {
            print("Failed to construct url-handoff URL")
            fflush(stdout)
            Foundation.exit(1)
        }

        try await DeskJigAppResolver.openDeskJigURL(url)
    }

    private func normalizedURLs(_ rawURLs: [String]) -> [String] {
        var deduplicated: [String] = []
        for raw in rawURLs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if deduplicated.contains(trimmed) { continue }
            deduplicated.append(trimmed)
        }
        return deduplicated
    }
}
