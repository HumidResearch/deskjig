import Testing
import Foundation

@testable import DeskJigShared

struct FluentLauncherTimeoutTests {

    @Test("Best-effort process returns exit code when command completes before timeout")
    func runProcessAsyncBestEffortCompletesBeforeTimeout() async throws {
        let result = try await LauncherUtils.runProcessAsyncBestEffort(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"],
            timeoutSeconds: 2.0,
            terminateOnTimeout: false
        )

        #expect(result.timedOut == false)
        #expect(result.exitCode == 7)
        #expect(result.duration < 2.0)
    }

    @Test("Best-effort process reports timeout and fallback exit code when command exceeds timeout")
    func runProcessAsyncBestEffortTimesOutWithoutTermination() async throws {
        let result = try await LauncherUtils.runProcessAsyncBestEffort(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 2"],
            timeoutSeconds: 0.05,
            terminateOnTimeout: false
        )

        #expect(result.timedOut == true)
        #expect(result.exitCode == 0)
        #expect(result.duration < 1.0)
    }

    @Test("Best-effort process reports timeout when terminate-on-timeout is enabled")
    func runProcessAsyncBestEffortTimesOutWithTermination() async throws {
        let result = try await LauncherUtils.runProcessAsyncBestEffort(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 3"],
            timeoutSeconds: 0.05,
            terminateOnTimeout: true
        )

        #expect(result.timedOut == true)
        #expect(result.exitCode == 0)
        #expect(result.duration < 1.0)
    }
}
