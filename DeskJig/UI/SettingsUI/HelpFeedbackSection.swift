//
//  HelpFeedbackSection.swift
//  DeskJig
//
//  Section for submitting feedback.
//

import SwiftUI
import AppKit

import DeskJigShared

struct HelpFeedbackSection: View {

    /// Issue tracker the "Send Feedback" action hands off to. DeskJig has no
    /// feedback backend — the app only opens this page in the user's browser.
    private static let issueTrackerURL = ProjectLinks.issueTrackerURL

    @State private var feedbackText: String = ""
    @State private var feedbackSubmitMessage: String? = nil
    @State private var feedbackSubmitSuccess: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            section("Send Feedback") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Tell us what you think")
                        .font(brand: .label2)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    DSTextArea(
                        placeholder: "Share feedback or report an issue...",
                        text: $feedbackText,
                        minHeight: 160,
                        maxHeight: 240
                    )

                    HStack(spacing: DesignTokens.Spacing.gapTiny) {
                        Image(systemName: "info.circle")
                            .font(.system(size: DesignTokens.IconSize.small))
                            .foregroundStyle(DesignTokens.Text.secondary)
                        Text("Include detailed steps to reproduce any issues that you're facing or leave general feedback for the app. Opening an issue takes you to the DeskJig issue tracker in your browser with anything you typed above prefilled.")
                            .font(brand: .body4)
                            .foregroundStyle(DesignTokens.Text.secondary)
                    }

                    HStack {
                        Button {
                            openIssueTracker()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.up.forward.square")
                                Text("Open an Issue on GitHub")
                            }
                        }
                        .buttonStyle(.dsButton(variant: .primary, size: .medium))

                        if let message = feedbackSubmitMessage {
                            Text(message)
                                .font(brand: .body4)
                                .foregroundStyle(feedbackSubmitSuccess ? DesignTokens.Status.success : DesignTokens.Status.error)
                        }
                    }
                }
            }

            section("Open Source") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("DeskJig is free and open source under Apache-2.0 — contributions welcome.")
                        .font(brand: .body4)
                        .foregroundStyle(DesignTokens.Text.secondary)

                    Button {
                        openRepository()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.forward.square")
                            Text("View on GitHub")
                        }
                    }
                    .buttonStyle(.dsButton(variant: .secondary, size: .medium))
                    .help("Open the DeskJig repository in your browser")
                }
            }
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title)
                .font(brand: .h3)
                .foregroundStyle(DesignTokens.Text.primary)

            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .padding(20)
            .frame(width: 800, alignment: .leading)
            .dsCard()
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Card.cornerRadius))
        }
    }

    /// Opens the issue tracker in the default browser, prefilling the new-issue
    /// body with whatever the user typed. Nothing is sent anywhere by the app.
    private func openIssueTracker() {
        let message = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = message.isEmpty ? Self.issueTrackerURL : newIssueURL(body: message)

        let opened = NSWorkspace.shared.open(destination)
        feedbackSubmitSuccess = opened
        feedbackSubmitMessage = opened
            ? "Opened the issue tracker in your browser."
            : "Couldn't open your browser. Visit \(Self.issueTrackerURL.absoluteString) instead."

        if opened {
            DeskJigLog.info(.app, "Feedback: opened issue tracker in browser")
        } else {
            DeskJigLog.error(.app, "Feedback: failed to open issue tracker in browser")
        }

        Task { @MainActor in
            // Clear message after 5 seconds
            await Task.sleepUnlessCancelled(for: .seconds(5))
            feedbackSubmitMessage = nil
        }
    }

    /// Opens the GitHub repository in the default browser.
    private func openRepository() {
        let opened = NSWorkspace.shared.open(ProjectLinks.repositoryURL)
        if opened {
            DeskJigLog.info(.app, "Help: opened GitHub repository in browser")
        } else {
            DeskJigLog.error(.app, "Help: failed to open GitHub repository in browser")
        }
    }

    /// Builds a `.../issues/new?body=…` URL, truncating very long bodies so the
    /// resulting URL stays within what browsers accept.
    private func newIssueURL(body: String) -> URL {
        let maxBodyLength = 4000
        let truncated = body.count > maxBodyLength
            ? String(body.prefix(maxBodyLength)) + "\n\n…(truncated)"
            : body

        var components = URLComponents(
            url: Self.issueTrackerURL.appendingPathComponent("new"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "body", value: truncated)]
        return components?.url ?? Self.issueTrackerURL
    }
}

#Preview {
    HelpFeedbackSection()
        .padding()
        .background(Color.black)
}
