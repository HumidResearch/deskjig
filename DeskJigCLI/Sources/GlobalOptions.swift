//  GlobalOptions.swift
//  DeskJigCLI

import ArgumentParser
import DeskJigShared
import Foundation

struct GlobalOptions: ParsableArguments {
    @Option(name: .customLong("format"), help: "Output format (text|json).")
    var format: OutputFormat = .text

    @Flag(name: .customLong("verbose"), help: "Enable verbose logging.")
    var verbose: Bool = false
}

extension OutputFormat: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }
}

extension WindowPosition: ExpressibleByArgument {
    public init?(argument: String) {
        guard let parsed = WindowPosition(rawValue: argument.lowercased()) ?? WindowPosition.parse(argument) else {
            return nil
        }
        self = parsed
    }
}

extension CustomSize: ExpressibleByArgument {
    public init?(argument: String) {
        guard let size = CustomSize.from(string: argument) else { return nil }
        self = size
    }
}

struct WindowTargetOptions: ParsableArguments {
    @Option(name: .customLong("window-id"), help: "Match window by CGWindowID.")
    var windowId: Int?

    @Option(name: .customLong("ax-hash"), help: "Match window by AX element hash.")
    var axHash: Int?

    @Option(name: .customLong("app"), help: "Match windows by app name.")
    var app: String?

    @Option(name: .customLong("bundle-id"), help: "Match windows by bundle identifier.")
    var bundleID: String?

    @Option(name: .customLong("title"), help: "Match windows by exact title.")
    var title: String?

    @Option(name: .customLong("title-contains"), help: "Match windows by title substring.")
    var titleContains: String?

    @Flag(name: .customLong("topmost"), help: "Target the topmost window (default if no target is provided).")
    var topmost: Bool = false

    func resolve(defaultToTopmost: Bool = true) throws -> WindowTarget {
        var provided: [String] = []
        if windowId != nil { provided.append("--window-id") }
        if axHash != nil { provided.append("--ax-hash") }
        if app != nil { provided.append("--app") }
        if bundleID != nil { provided.append("--bundle-id") }
        if title != nil { provided.append("--title") }
        if titleContains != nil { provided.append("--title-contains") }
        if topmost { provided.append("--topmost") }

        if provided.count > 1 {
            throw ValidationError("Specify only one window target (\(provided.joined(separator: ", ")))")
        }

        if let windowId {
            return .byWindowId(windowId)
        }
        if let axHash {
            return .byAxHash(axHash)
        }
        if let app {
            return .byApp(app)
        }
        if let bundleID {
            return .byBundleID(bundleID)
        }
        if let title {
            return .byTitle(title)
        }
        if let titleContains {
            return .byTitleContaining(titleContains)
        }
        if topmost || defaultToTopmost {
            return .topmost
        }

        throw ValidationError("Missing window target. Use --window-id, --ax-hash, --app, --bundle-id, --title, --title-contains, or --topmost.")
    }
}
