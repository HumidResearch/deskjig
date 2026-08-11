import Testing
@testable import DeskJigShared

private actor ConcurrencyProbe {
    private var active = 0
    private var maxActive = 0

    func enter() {
        active += 1
        if active > maxActive {
            maxActive = active
        }
    }

    func leave() {
        active = max(0, active - 1)
    }

    func maxObserved() -> Int {
        maxActive
    }
}

/// A two-party meeting point that only completes when both parties are
/// suspended in ``arrive()`` at the same time. Used to *prove* two tasks were
/// concurrently inside their lane-held critical sections without relying on
/// sleep windows overlapping by luck: the first arriver parks on a
/// continuation and can only be resumed by the second arriver.
///
/// ``expire()`` is the bounded escape hatch for the regression direction — if
/// the coordinator wrongly serialized the lanes, the second party could never
/// arrive (it would be stuck in `acquire`), so a watchdog expires the
/// rendezvous and every ``arrive()`` (parked or future) returns `false`
/// instead of deadlocking the merge-gate job.
private actor Rendezvous {
    private var waiter: CheckedContinuation<Bool, Never>?
    private var expired = false

    /// Suspends until the other party arrives. Returns `true` iff both
    /// parties were inside ``arrive()`` concurrently before ``expire()``.
    func arrive() async -> Bool {
        if expired { return false }
        if let other = waiter {
            waiter = nil
            other.resume(returning: true)
            return true
        }
        return await withCheckedContinuation { waiter = $0 }
    }

    /// Fails the rendezvous: resumes any parked party with `false` and makes
    /// all future arrivals return `false` immediately.
    func expire() {
        expired = true
        if let stranded = waiter {
            waiter = nil
            stranded.resume(returning: false)
        }
    }
}

struct DisplayLaneCoordinatorTests {
    // FLAKE HISTORY (#673): on PR #668 the headless gate (run 29937022156,
    // attempt 1, 2026-07-22) reported this test as the sole failure. The
    // xcodebuild log shows what actually happened: ~14ms after this test
    // started, the shared test host crashed with an uncaught
    // NSInvalidArgumentException (`-[NSIndexPath count]` sent to
    // tagged-pointer garbage 0x8000000000000000) thrown from
    // BinaryPartitionLayoutCoordinator.updatePollingState's re-dispatched
    // main-queue closure — the #629 BPLC data-race crash, which lands the
    // failure on whichever test is in flight when the host dies. xcodebuild
    // relaunched the host and this suite passed in 0.125s on the automatic
    // retry. The crash's root cause was fixed by #684 (the BPLC suites are
    // now @MainActor, so the racing main-queue closure is never dispatched).
    //
    // The test itself has no timing sensitivity in its failure direction:
    // the probe's enter/leave is strictly nested inside acquire/release of a
    // 1-permit actor-backed semaphore, so `maxObserved` can only exceed 1 if
    // lane serialization is genuinely broken. The 90ms sleep does not guard
    // correctness — it only widens the overlap window that a real
    // serialization bug would need to collide in, improving detection power.
    // No scheduler load can make a correct coordinator fail this assertion.
    @Test("Display lane coordinator serializes work on the same lane")
    func sameLaneIsSerialized() async {
        let coordinator = DisplayLaneCoordinator(targetScreenIndices: [0, 1], perLaneConcurrency: 1)
        let probe = ConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    await coordinator.acquire(.screen(0))
                    await probe.enter()
                    try? await Task.sleep(for: .milliseconds(90))
                    await probe.leave()
                    await coordinator.release(.screen(0))
                }
            }
        }

        let maxObserved = await probe.maxObserved()
        #expect(maxObserved == 1)
    }

    // DETERMINISM (#673): this test used to assert `maxObserved >= 2` from
    // two tasks that each held their lane for a 120ms sleep — a genuine
    // timing assumption (the pass required the two sleep windows to overlap,
    // which a starved CI runner can defeat by running the tasks back to
    // back). It now proves cross-lane concurrency with a rendezvous instead:
    // each task acquires its own lane and then waits *inside the lane-held
    // section* for the other task to arrive. The rendezvous can only
    // complete while both tasks simultaneously hold their lanes, so a pass
    // is load-independent. If the coordinator wrongly serialized the lanes,
    // the second task could never reach the rendezvous (stuck in `acquire`
    // behind a holder that never releases), so a watchdog expires the
    // rendezvous after a generous bound and the test fails cleanly rather
    // than hanging the merge-gate job.
    @Test("Display lane coordinator allows parallel work across different lanes")
    func differentLanesRunInParallel() async {
        let coordinator = DisplayLaneCoordinator(targetScreenIndices: [0, 1], perLaneConcurrency: 1)
        let rendezvous = Rendezvous()

        let bothLanesOverlapped = await withTaskGroup(of: Bool?.self) { group in
            for lane in [RestorationLaneKey.screen(0), .screen(1)] {
                group.addTask {
                    await coordinator.acquire(lane)
                    let met = await rendezvous.arrive()
                    await coordinator.release(lane)
                    return met
                }
            }

            // Watchdog: bounds the regression direction (serialized lanes
            // would otherwise deadlock the rendezvous). Cancelled — waking
            // the sleep immediately — as soon as both lane tasks report.
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                await rendezvous.expire()
                return nil
            }

            var laneResults: [Bool] = []
            for await result in group {
                if let met = result {
                    laneResults.append(met)
                    if laneResults.count == 2 {
                        group.cancelAll()
                    }
                }
            }
            return laneResults.count == 2 && laneResults.allSatisfy { $0 }
        }

        #expect(bothLanesOverlapped)
    }
}
