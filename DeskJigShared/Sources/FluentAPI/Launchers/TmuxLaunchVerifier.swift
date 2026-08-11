//  TmuxLaunchVerifier.swift
//  DeskJigShared

import Foundation

struct TmuxLaunchVerificationResult: Sendable {
    let success: Bool
    let attachedClientCount: Int
    let paneTitle: String?
}

enum TmuxLaunchVerifier {
    static func waitForClientAttachment(
        sessionName: String,
        expectedTitle: String,
        commandService: TmuxCommandService,
        timeoutMs: Int = 3_000,
        pollIntervalMs: Int = 100
    ) async -> TmuxLaunchVerificationResult {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var lastClientCount = 0

        while Date() < deadline {
            if let clients = try? await commandService.listClientsForSession(sessionName) {
                lastClientCount = clients.count
                if !clients.isEmpty {
                    let paneTitle = try? await commandService.getPaneTitle(session: sessionName)
                    return TmuxLaunchVerificationResult(
                        success: true,
                        attachedClientCount: clients.count,
                        paneTitle: paneTitle ?? expectedTitle
                    )
                }
            }

            guard await Task.sleepUnlessCancelled(for: .milliseconds(pollIntervalMs)) else { break }
        }

        let paneTitle = try? await commandService.getPaneTitle(session: sessionName)
        return TmuxLaunchVerificationResult(
            success: false,
            attachedClientCount: lastClientCount,
            paneTitle: paneTitle
        )
    }
}
