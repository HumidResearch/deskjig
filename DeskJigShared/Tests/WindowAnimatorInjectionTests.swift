//  WindowAnimatorInjectionTests.swift
//  DeskJigSharedTests

import Foundation
import ApplicationServices
import CoreGraphics
import Testing
@testable import DeskJigShared

@Suite("WindowAnimator service injection (#481)")
struct WindowAnimatorInjectionTests {

    private func makeWindow(frame: CGRect) -> AXWindow {
        let pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        return AXWindow(
            axElement: AXUIElementCreateApplication(pid),
            frame: frame,
            title: "test-window",
            isMinimized: false,
            isHidden: false,
            processID: pid
        )
    }

    @Test("Animation steps through the injected service and lands on the target frame")
    func animatesViaInjectedService() async {
        let mock = MockAXWindowService()
        let animator = WindowAnimator(axWindowServiceProvider: { mock })
        let window = makeWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let target = CGRect(x: 200, y: 200, width: 300, height: 300)

        let result = await animator.animate(
            window: window,
            to: target,
            options: WindowAnimationOptions(duration: 0.05, easing: .linear)
        )

        #expect(result.success)
        #expect(!result.wasInterrupted)
        // Interpolation steps plus the final exact positioning must all flow
        // through the injected service.
        #expect(mock.movedFrames.count >= 2)
        #expect(mock.movedFrames.last == target)
    }

    @Test("Missing service from the injected provider fails the animation cleanly")
    func missingServiceFailsAnimation() async {
        let animator = WindowAnimator(axWindowServiceProvider: { nil })
        let window = makeWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))

        let result = await animator.animate(
            window: window,
            to: CGRect(x: 50, y: 50, width: 100, height: 100),
            options: WindowAnimationOptions(duration: 0.05, easing: .linear)
        )

        #expect(!result.success)
    }
}
