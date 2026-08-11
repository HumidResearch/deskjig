import Foundation
import Testing
@testable import DeskJigShared

struct WorkspaceExternalChangeSignalTests {
    @Test("observer receives a posted external-change signal")
    func observerReceivesPostedSignal() {
        let received = DispatchSemaphore(value: 0)
        let observer = WorkspaceExternalChangeObserver {
            received.signal()
        }

        WorkspaceExternalChangeSignal.post()

        // Distributed notifications round-trip through notifyd, so delivery is
        // asynchronous even when poster and observer share a process. The wait
        // happens off the main thread (Swift Testing default), leaving the main
        // queue free for the observer's delivery. Generous timeout for CI load.
        #expect(received.wait(timeout: .now() + 15) == .success)
        withExtendedLifetime(observer) {}
    }
}
