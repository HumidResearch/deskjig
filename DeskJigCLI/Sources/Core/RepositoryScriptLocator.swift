//  RepositoryScriptLocator.swift
//  DeskJigCLI

import Foundation

struct RepositoryScriptLocator {
    struct ResolvedScript {
        let scriptURL: URL
        let repositoryRoot: URL
    }

    static func resolveScript(named fileName: String) -> ResolvedScript? {
        let fileManager = FileManager.default
        let relativePath = "scripts/\(fileName)"

        for root in candidateRepositoryRoots(fileManager: fileManager) {
            let scriptURL = root.appendingPathComponent(relativePath)
            if fileManager.fileExists(atPath: scriptURL.path) {
                return ResolvedScript(scriptURL: scriptURL, repositoryRoot: root)
            }
        }

        return nil
    }

    private static func candidateRepositoryRoots(fileManager: FileManager) -> [URL] {
        var candidates: [URL] = []

        if let override = ProcessInfo.processInfo.environment["BENTO_REPO_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true))
        }

        candidates.append(URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true))

        for base in executableSearchRoots(fileManager: fileManager) {
            var dir = base
            for _ in 0..<12 {
                candidates.append(dir)
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path {
                    break
                }
                dir = parent
            }
        }

        var seen: Set<String> = []
        return candidates.filter { url in
            let path = url.standardizedFileURL.path
            if seen.contains(path) {
                return false
            }
            seen.insert(path)
            return true
        }
    }

    private static func executableSearchRoots(fileManager: FileManager) -> [URL] {
        var roots: [URL] = []

        if let executableURL = Bundle.main.executableURL {
            roots.append(executableURL.resolvingSymlinksInPath().deletingLastPathComponent())
        }

        if let argumentURL = commandLineExecutableURL(fileManager: fileManager) {
            roots.append(argumentURL.resolvingSymlinksInPath().deletingLastPathComponent())
        }

        return roots
    }

    private static func commandLineExecutableURL(fileManager: FileManager) -> URL? {
        guard let executable = CommandLine.arguments.first, !executable.isEmpty else {
            return nil
        }

        if executable.hasPrefix("/") {
            return URL(fileURLWithPath: executable)
        }

        return URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(executable)
    }
}
