//  ChromeAutomationURLMatchingTests.swift
//  DeskJigSharedTests

import Testing
@testable import DeskJigShared

struct ChromeAutomationURLMatchingTests {

    @Test("Root target URL matches any route on same host")
    func rootTargetMatchesHostRoute() {
        #expect(
            ChromeAutomationService.urlsAreEquivalent(
                "https://mail.google.com",
                "https://mail.google.com/mail/u/0/#inbox"
            )
        )
    }

    @Test("Non-root target URL keeps strict route matching")
    func nonRootTargetDoesNotMatchRootHost() {
        #expect(
            !ChromeAutomationService.urlsAreEquivalent(
                "https://mail.google.com/mail/u/0/#inbox",
                "https://mail.google.com"
            )
        )
    }

    @Test("Trailing slash still normalizes to exact match")
    func exactNormalizationStillApplies() {
        #expect(
            ChromeAutomationService.urlsAreEquivalent(
                "https://news.ycombinator.com",
                "https://news.ycombinator.com/"
            )
        )
    }

    @Test("Host fallback does not match different host")
    func hostFallbackStaysHostScoped() {
        #expect(
            !ChromeAutomationService.urlsAreEquivalent(
                "https://mail.google.com",
                "https://google.com/mail"
            )
        )
    }

    @Test("Auth redirect fallback remains supported")
    func authRedirectFallbackStillMatches() {
        #expect(
            ChromeAutomationService.urlsAreEquivalent(
                "https://console.aws.amazon.com/console/home?region=us-east-1",
                "https://signin.aws.amazon.com/oauth?redirect_uri=https%3A%2F%2Fconsole.aws.amazon.com"
            )
        )
    }

    @Test("Localhost host fallback requires matching port")
    func localhostHostFallbackRequiresMatchingPort() {
        #expect(
            !ChromeAutomationService.urlsAreEquivalent(
                "http://localhost:62047",
                "http://localhost:3000"
            )
        )
    }

    @Test("Localhost host fallback matches same port route")
    func localhostHostFallbackMatchesSamePortRoute() {
        #expect(
            ChromeAutomationService.urlsAreEquivalent(
                "http://localhost:62047",
                "http://localhost:62047/dashboard"
            )
        )
    }

    @Test("Localhost exact tier does not collapse different ports")
    func localhostExactTierDoesNotCollapseDifferentPorts() {
        #expect(
            !ChromeAutomationService.urlsAreEquivalent(
                "http://localhost:8787/index.html",
                "http://localhost:3000"
            )
        )
    }
}
