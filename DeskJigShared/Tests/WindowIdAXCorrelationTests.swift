//  WindowIdAXCorrelationTests.swift
//  DeskJigSharedTests

import Foundation
import ApplicationServices
import CoreGraphics
import Testing
@testable import DeskJigShared

@Suite("CGWindowID → AX correlation (#654)")
struct WindowIdAXCorrelationTests {

    private static let pid: pid_t = 4242

    /// Distinct AXUIElements so the injected provider can tell the two
    /// same-title same-frame siblings apart (AXWindow's Hashable identity is
    /// frame+title+pid, which is exactly what collides in this scenario).
    private let elementA = AXUIElementCreateApplication(101)
    private let elementB = AXUIElementCreateApplication(102)
    private let elementC = AXUIElementCreateApplication(103)

    private func makeWindow(element: AXUIElement, title: String, frame: CGRect) -> AXWindow {
        AXWindow(
            axElement: element,
            frame: frame,
            title: title,
            isMinimized: false,
            isHidden: false,
            processID: Self.pid,
            bundleIdentifier: "com.apple.finder"
        )
    }

    /// Provider mapping the two elements to the ticket's Finder window IDs.
    private func provider(_ numberA: Int?, _ numberB: Int?) -> (AXWindow) -> Int? {
        { window in
            if CFEqual(window.axElement, self.elementA) { return numberA }
            if CFEqual(window.axElement, self.elementB) { return numberB }
            return nil
        }
    }

    // MARK: - The #654 scenario: two Finder windows, both titled "code", same frame

    @Test("AXWindowNumber disambiguates same-title same-frame siblings")
    func windowNumberDisambiguatesSameTitleSameFrameSiblings() throws {
        let sharedFrame = CGRect(x: 0, y: 25, width: 960, height: 1055)
        let siblingA = makeWindow(element: elementA, title: "code", frame: sharedFrame)
        let siblingB = makeWindow(element: elementB, title: "code", frame: sharedFrame)

        for candidates in [[siblingA, siblingB], [siblingB, siblingA]] {
            let match2198 = try Window.correlateAXWindow(
                windowId: 2198,
                cgFrame: sharedFrame,
                cgTitle: "code",
                strategy: .frameOnly,
                candidates: candidates,
                windowNumberProvider: provider(2198, 2200)
            )
            #expect(match2198?.method == .windowNumber)
            #expect(match2198.map { CFEqual($0.window.axElement, elementA) } == true)

            let match2200 = try Window.correlateAXWindow(
                windowId: 2200,
                cgFrame: sharedFrame,
                cgTitle: "code",
                strategy: .frameOnly,
                candidates: candidates,
                windowNumberProvider: provider(2198, 2200)
            )
            #expect(match2200?.method == .windowNumber)
            #expect(match2200.map { CFEqual($0.window.axElement, elementB) } == true)
        }
    }

    @Test("Identity beats a closer frame match from the wrong sibling")
    func identityBeatsFrameHeuristic() throws {
        let cgFrame = CGRect(x: 0, y: 25, width: 960, height: 1055)
        // Sibling B sits exactly at the CG frame but is provably window 2200;
        // sibling A (the requested 2198) drifted a few pixels.
        let siblingA = makeWindow(element: elementA, title: "code", frame: cgFrame.offsetBy(dx: 3, dy: 3))
        let siblingB = makeWindow(element: elementB, title: "code", frame: cgFrame)

        let match = try Window.correlateAXWindow(
            windowId: 2198,
            cgFrame: cgFrame,
            cgTitle: "code",
            strategy: .frameOnly,
            candidates: [siblingB, siblingA],
            windowNumberProvider: provider(2198, 2200)
        )
        #expect(match?.method == .windowNumber)
        #expect(match.map { CFEqual($0.window.axElement, elementA) } == true)
    }

    @Test("Candidates with a different AXWindowNumber are never heuristically matched")
    func knownMismatchedSiblingsAreNeverHeuristicallyMatched() throws {
        let cgFrame = CGRect(x: 0, y: 25, width: 960, height: 1055)
        let siblingA = makeWindow(element: elementA, title: "code", frame: cgFrame)
        let siblingB = makeWindow(element: elementB, title: "code", frame: cgFrame)

        // The requested window ID belongs to neither candidate: correlating must
        // fail honestly rather than move a provably different window.
        let match = try Window.correlateAXWindow(
            windowId: 9999,
            cgFrame: cgFrame,
            cgTitle: "code",
            strategy: .frameOnly,
            candidates: [siblingA, siblingB],
            windowNumberProvider: provider(2198, 2200)
        )
        #expect(match == nil)
    }

    // MARK: - Fallback behavior for apps that do not expose AXWindowNumber

    @Test("Frame fallback still works when no candidate reports a window number")
    func frameFallbackWhenWindowNumberUnavailable() throws {
        let cgFrame = CGRect(x: 480, y: 100, width: 960, height: 800)
        let other = makeWindow(element: elementA, title: "code", frame: CGRect(x: 0, y: 25, width: 400, height: 400))
        let target = makeWindow(element: elementB, title: "code", frame: cgFrame)

        let match = try Window.correlateAXWindow(
            windowId: 2198,
            cgFrame: cgFrame,
            cgTitle: "code",
            strategy: .frameOnly,
            candidates: [other, target],
            windowNumberProvider: { _ in nil }
        )
        #expect(match?.method == .strategy(.frameOnly))
        #expect(match.map { CFEqual($0.window.axElement, elementB) } == true)
    }

    @Test("Ambiguous frame fallback picks the closest candidate deterministically")
    func frameFallbackPrefersClosestAmongAmbiguous() throws {
        let cgFrame = CGRect(x: 0, y: 25, width: 960, height: 1055)
        // Both are within the 5px tolerance; the exact-frame one must win
        // regardless of candidate order.
        let drifted = makeWindow(element: elementA, title: "code", frame: cgFrame.offsetBy(dx: 2, dy: 2))
        let exact = makeWindow(element: elementB, title: "code", frame: cgFrame)

        for candidates in [[drifted, exact], [exact, drifted]] {
            let match = try Window.correlateAXWindow(
                windowId: 2198,
                cgFrame: cgFrame,
                cgTitle: "code",
                strategy: .frameOnly,
                candidates: candidates,
                windowNumberProvider: { _ in nil }
            )
            #expect(match?.method == .strategy(.frameOnly))
            #expect(match.map { CFEqual($0.window.axElement, elementB) } == true)
        }
    }

    @Test("Identity resolution applies to non-frame strategies too")
    func windowNumberAppliesToTitleOnlyStrategy() throws {
        let sharedFrame = CGRect(x: 0, y: 25, width: 960, height: 1055)
        let siblingA = makeWindow(element: elementA, title: "code", frame: sharedFrame)
        let siblingB = makeWindow(element: elementB, title: "code", frame: sharedFrame)

        let match = try Window.correlateAXWindow(
            windowId: 2200,
            cgFrame: sharedFrame,
            cgTitle: "code",
            strategy: .titleOnly,
            candidates: [siblingA, siblingB],
            windowNumberProvider: provider(2198, 2200)
        )
        #expect(match?.method == .windowNumber)
        #expect(match.map { CFEqual($0.window.axElement, elementB) } == true)
    }

    // MARK: - Fail-honestly tie case (#657 Mini bounce: Finder exposes no AXWindowNumber)

    @Test("Distance-0 tie without identity throws instead of guessing")
    func identicalFrameTieWithoutIdentityThrows() {
        let sharedFrame = CGRect(x: 0, y: 30, width: 960, height: 1050)
        let siblingA = makeWindow(element: elementA, title: "code", frame: sharedFrame)
        let siblingB = makeWindow(element: elementB, title: "code", frame: sharedFrame)

        // Exactly the Mini scenario after move 3: both siblings at left-half,
        // identical frames, provider resolves neither. Both enumeration orders
        // must refuse identically — the old "picked closest" degenerated to
        // enumeration order here.
        for candidates in [[siblingA, siblingB], [siblingB, siblingA]] {
            #expect(throws: Window.AXCorrelationError.ambiguousFrameTie(windowId: 2198, tiedCandidates: 2)) {
                try Window.correlateAXWindow(
                    windowId: 2198,
                    cgFrame: sharedFrame,
                    cgTitle: "code",
                    strategy: .frameOnly,
                    candidates: candidates,
                    windowNumberProvider: { _ in nil }
                )
            }
        }
    }

    @Test("Tie among unidentified candidates throws even when a mismatched sibling was excluded")
    func tieAmongUnidentifiedThrowsDespiteExcludedMismatch() {
        let sharedFrame = CGRect(x: 0, y: 30, width: 960, height: 1050)
        let identifiedOther = makeWindow(element: elementA, title: "code", frame: sharedFrame)
        let unidentifiedB = makeWindow(element: elementB, title: "code", frame: sharedFrame)
        let unidentifiedC = makeWindow(element: elementC, title: "code", frame: sharedFrame)

        // elementA provably is window 2200 (excluded); B and C remain an
        // identical-frame tie with no identity — still refuse to guess.
        #expect(throws: Window.AXCorrelationError.ambiguousFrameTie(windowId: 2198, tiedCandidates: 2)) {
            try Window.correlateAXWindow(
                windowId: 2198,
                cgFrame: sharedFrame,
                cgTitle: "code",
                strategy: .frameOnly,
                candidates: [identifiedOther, unidentifiedB, unidentifiedC],
                windowNumberProvider: provider(2200, nil)
            )
        }
    }

    @Test("Identity resolution defuses the distance-0 tie")
    func identityResolutionDefusesTie() throws {
        let sharedFrame = CGRect(x: 0, y: 30, width: 960, height: 1050)
        let siblingA = makeWindow(element: elementA, title: "code", frame: sharedFrame)
        let siblingB = makeWindow(element: elementB, title: "code", frame: sharedFrame)

        // Same fixture as the throwing test, but the provider resolves — the
        // production default now succeeds via _AXUIElementGetWindow for apps
        // (like Finder) that expose no AXWindowNumber attribute.
        let match = try Window.correlateAXWindow(
            windowId: 2198,
            cgFrame: sharedFrame,
            cgTitle: "code",
            strategy: .frameOnly,
            candidates: [siblingB, siblingA],
            windowNumberProvider: provider(2198, 2200)
        )
        #expect(match?.method == .windowNumber)
        #expect(match.map { CFEqual($0.window.axElement, elementA) } == true)
    }

    @Test("frameAndTitle strategy also refuses a distance-0 tie without identity")
    func frameAndTitleTieWithoutIdentityThrows() {
        let sharedFrame = CGRect(x: 0, y: 30, width: 960, height: 1050)
        let siblingA = makeWindow(element: elementA, title: "code", frame: sharedFrame)
        let siblingB = makeWindow(element: elementB, title: "code", frame: sharedFrame)

        #expect(throws: Window.AXCorrelationError.ambiguousFrameTie(windowId: 2198, tiedCandidates: 2)) {
            try Window.correlateAXWindow(
                windowId: 2198,
                cgFrame: sharedFrame,
                cgTitle: "code",
                strategy: .frameAndTitle,
                candidates: [siblingA, siblingB],
                windowNumberProvider: { _ in nil }
            )
        }
    }

    @Test("Non-identical frames within tolerance do not trip the tie guard")
    func nearbyButDistinctFramesStillResolveByClosest() throws {
        let cgFrame = CGRect(x: 0, y: 30, width: 960, height: 1050)
        // Distinct frames (one drifted): closest wins, no throw — the guard is
        // strictly for identical frames where "closest" is meaningless.
        let drifted = makeWindow(element: elementA, title: "code", frame: cgFrame.offsetBy(dx: 4, dy: 0))
        let exact = makeWindow(element: elementB, title: "code", frame: cgFrame)

        let match = try Window.correlateAXWindow(
            windowId: 2198,
            cgFrame: cgFrame,
            cgTitle: "code",
            strategy: .frameOnly,
            candidates: [drifted, exact],
            windowNumberProvider: { _ in nil }
        )
        #expect(match?.method == .strategy(.frameOnly))
        #expect(match.map { CFEqual($0.window.axElement, elementB) } == true)
    }
}
