//  DisplayLaneCoordinator.swift
//  DeskJigShared

import Foundation

enum RestorationLaneKey: Hashable, Sendable {
    case screen(Int)
    case unassigned

    var label: String {
        switch self {
        case .screen(let index):
            return "screen-\(index)"
        case .unassigned:
            return "unassigned"
        }
    }
}

public actor DisplayLaneCoordinator {
    private let perLaneConcurrency: Int
    private var semaphores: [RestorationLaneKey: AsyncSemaphore]
    private var waitSamplesMs: [Int] = []

    struct Metrics: Sendable {
        let laneCount: Int
        let waitSummary: String
    }

    init(targetScreenIndices: [Int], perLaneConcurrency: Int = 1) {
        self.perLaneConcurrency = max(1, perLaneConcurrency)

        var uniqueKeys = Set(targetScreenIndices.map { RestorationLaneKey.screen($0) })
        uniqueKeys.insert(.unassigned)

        var built: [RestorationLaneKey: AsyncSemaphore] = [:]
        for key in uniqueKeys {
            built[key] = AsyncSemaphore(permits: self.perLaneConcurrency)
        }
        self.semaphores = built
    }

    func acquire(_ key: RestorationLaneKey) async {
        let semaphore = semaphoreForKey(key)
        let startedAt = Date()
        await semaphore.wait()
        let waitedMs = max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
        waitSamplesMs.append(waitedMs)
    }

    func release(_ key: RestorationLaneKey) async {
        let semaphore = semaphoreForKey(key)
        await semaphore.signal()
    }

    func metrics() -> Metrics {
        let count = semaphores.count
        guard !waitSamplesMs.isEmpty else {
            return Metrics(laneCount: count, waitSummary: "p50=0,p90=0,p99=0,max=0")
        }

        let sorted = waitSamplesMs.sorted()
        let p50 = percentile(sorted, percentile: 0.50)
        let p90 = percentile(sorted, percentile: 0.90)
        let p99 = percentile(sorted, percentile: 0.99)
        let maxValue = sorted.last ?? 0
        let summary = "p50=\(p50),p90=\(p90),p99=\(p99),max=\(maxValue)"
        return Metrics(laneCount: count, waitSummary: summary)
    }

    private func semaphoreForKey(_ key: RestorationLaneKey) -> AsyncSemaphore {
        if let existing = semaphores[key] {
            return existing
        }
        let created = AsyncSemaphore(permits: perLaneConcurrency)
        semaphores[key] = created
        return created
    }

    private func percentile(_ sorted: [Int], percentile: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let rawIndex = Int((Double(sorted.count - 1) * percentile).rounded())
        let clamped = min(max(rawIndex, 0), sorted.count - 1)
        return sorted[clamped]
    }
}
