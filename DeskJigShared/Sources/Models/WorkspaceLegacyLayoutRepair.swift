//  WorkspaceLegacyLayoutRepair.swift
//  DeskJigShared

import Foundation
import CoreGraphics

public struct WorkspaceLegacyLayoutRepairMonitorSummary: Equatable, Sendable {
    public let title: String
    public let appNames: [String]
    public let featureSummary: String

    public init(title: String, appNames: [String], featureSummary: String) {
        self.title = title
        self.appNames = appNames
        self.featureSummary = featureSummary
    }
}

public struct WorkspaceLegacyLayoutRepairCandidate: Equatable, Sendable {
    public let repairedWorkspace: Workspace
    public let explanation: String
    public let confidence: Double
    public let score: Double
    public let selectionLabel: String
    public let monitorSummaries: [WorkspaceLegacyLayoutRepairMonitorSummary]

    public init(
        repairedWorkspace: Workspace,
        explanation: String,
        confidence: Double,
        score: Double,
        selectionLabel: String,
        monitorSummaries: [WorkspaceLegacyLayoutRepairMonitorSummary]
    ) {
        self.repairedWorkspace = repairedWorkspace
        self.explanation = explanation
        self.confidence = confidence
        self.score = score
        self.selectionLabel = selectionLabel
        self.monitorSummaries = monitorSummaries
    }
}

public enum WorkspaceLegacyLayoutRepairInference: Equatable, Sendable {
    case unavailable(reason: String)
    case resolved(WorkspaceLegacyLayoutRepairCandidate)
    case needsChoice([WorkspaceLegacyLayoutRepairCandidate])
}

private enum WorkspaceRepairRole: String, CaseIterable, Sendable {
    case terminal
    case ide
    case browser
    case messaging
    case document
    case meeting
    case music
    case other
}

private struct WorkspaceRepairMonitorFeatures: Sendable {
    let indices: [Int]
    let windows: [WorkspaceWindow]
    let appNames: [String]
    let layoutPattern: String
    let roleCounts: [WorkspaceRepairRole: Int]
    let containsPathBackedWindow: Bool
    let score: Double
    let reasons: [String]
    let signature: String
}

private struct WorkspaceRepairMonitorPrior: Sendable {
    let appCount: Int
    let layoutPattern: String
    let roleCounts: [WorkspaceRepairRole: Int]
    let containsPathBackedWindow: Bool
}

extension Workspace {
    public func monitorRepairResult(using referenceWorkspaces: [Workspace]) -> WorkspaceLegacyLayoutRepairInference {
        guard layoutHealth == .legacyFlattenedBrokenPreview else {
            return .unavailable(reason: "Workspace does not need legacy layout repair.")
        }

        guard windows.allSatisfy({ $0.relativeFrame != nil }) else {
            return .unavailable(reason: "One or more windows are missing saved geometry.")
        }

        guard windows.count >= 2 else {
            return .unavailable(reason: "Not enough saved windows to infer monitor assignments.")
        }

        let conflicts = repairConflictGraph
        let partitions = Self.uniquePartitions(for: conflicts, colorCount: 2)
        guard !partitions.isEmpty else {
            return .unavailable(reason: "No valid 2-monitor groupings could be inferred from the saved geometry.")
        }

        let priors = Self.buildMonitorPriors(from: referenceWorkspaces.filter { $0.id != id })
        let candidates = partitions.compactMap { buildCandidate(from: $0, priors: priors) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.selectionLabel < rhs.selectionLabel
                }
                return lhs.score > rhs.score
            }

        guard let topCandidate = candidates.first else {
            return .unavailable(reason: "No candidate monitor mapping passed DeskJig's structural checks.")
        }

        if candidates.count == 1 {
            return topCandidate.score >= 45
                ? .resolved(topCandidate)
                : .unavailable(reason: "No candidate monitor mapping scored confidently enough.")
        }

        let scoreGap = topCandidate.score - candidates[1].score
        if topCandidate.score >= 60, scoreGap >= 25 {
            return .resolved(topCandidate)
        }

        if topCandidate.score >= 20 {
            return .needsChoice(Array(candidates.prefix(3)))
        }

        return .unavailable(reason: "No candidate monitor mapping scored confidently enough.")
    }

    public var inferredLegacyLayoutRepair: WorkspaceLegacyLayoutRepairInference {
        monitorRepairResult(using: [])
    }

    public var hasInferredLegacyRepairAvailable: Bool {
        switch inferredLegacyLayoutRepair {
        case .resolved, .needsChoice:
            return true
        case .unavailable:
            return false
        }
    }

    public var previewWorkspace: Workspace {
        repairPreviewWorkspace(using: [])
    }

    public func repairPreviewWorkspace(using referenceWorkspaces: [Workspace]) -> Workspace {
        switch monitorRepairResult(using: referenceWorkspaces) {
        case .resolved(let candidate):
            return candidate.repairedWorkspace
        case .needsChoice(let candidates):
            return candidates.first?.repairedWorkspace ?? self
        case .unavailable:
            return self
        }
    }

    private var repairConflictGraph: [[Bool]] {
        let frames = windows.compactMap(\.relativeFrame)
        var graph = Array(
            repeating: Array(repeating: false, count: frames.count),
            count: frames.count
        )

        guard frames.count == windows.count else {
            return graph
        }

        for index in frames.indices {
            for otherIndex in frames.indices where otherIndex > index {
                let lhs = frames[index]
                let rhs = frames[otherIndex]
                let hasConflict =
                    lhs == rhs ||
                    Self.repairOverlapArea(between: lhs, and: rhs) > 0.05 ||
                    Self.contains(lhs, rhs) ||
                    Self.contains(rhs, lhs)

                guard hasConflict else { continue }
                graph[index][otherIndex] = true
                graph[otherIndex][index] = true
            }
        }

        return graph
    }

    private func buildCandidate(
        from partition: [[Int]],
        priors: [WorkspaceRepairMonitorPrior]
    ) -> WorkspaceLegacyLayoutRepairCandidate? {
        let frames = windows.compactMap(\.relativeFrame)
        guard frames.count == windows.count else { return nil }
        guard partition.count == 2 else { return nil }

        let featureGroups = partition.map { makeMonitorFeatures(for: $0) }
        guard featureGroups.count == 2 else { return nil }
        guard featureGroups.allSatisfy({ layerIsConflictFree($0.indices, using: frames) }) else { return nil }

        let pathScore = pathConsistencyScore(for: featureGroups)
        let duplicateScore = duplicateFrameScore(for: featureGroups)
        let priorScore = priorSimilarityScore(for: featureGroups, priors: priors)
        let totalScore = featureGroups.reduce(0) { $0 + $1.score } + pathScore + duplicateScore + priorScore

        let orderedGroups = featureGroups.sorted { lhs, rhs in
            if lhs.containsPathBackedWindow != rhs.containsPathBackedWindow {
                return lhs.containsPathBackedWindow && !rhs.containsPathBackedWindow
            }
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.signature < rhs.signature
        }

        let slotWidth: CGFloat = 1920
        let slotHeight: CGFloat = 1080
        let visibleHeight: CGFloat = 1050

        var repairedWindows = windows
        var displaySlots: [WorkspaceDisplaySlot] = []
        var monitorSummaries: [WorkspaceLegacyLayoutRepairMonitorSummary] = []
        displaySlots.reserveCapacity(orderedGroups.count)
        monitorSummaries.reserveCapacity(orderedGroups.count)

        for (groupIndex, group) in orderedGroups.enumerated() {
            let xOrigin = CGFloat(groupIndex) * slotWidth
            let slot = WorkspaceDisplaySlot(
                id: UUID(),
                title: "Monitor \(groupIndex + 1)",
                displayID: -(groupIndex + 1),
                displayName: "Recovered Monitor \(groupIndex + 1)",
                resolution: CGSize(width: slotWidth, height: slotHeight),
                arrangementFrame: CGRect(x: xOrigin, y: 0, width: slotWidth, height: slotHeight),
                visibleFrame: CGRect(x: xOrigin, y: 0, width: slotWidth, height: visibleHeight),
                isPrimary: groupIndex == 0
            )
            displaySlots.append(slot)

            for windowIndex in group.indices {
                repairedWindows[windowIndex] = repairedWindows[windowIndex]
                    .withDisplaySlotID(slot.id)
                    .withScreenMapping(screenIndex: groupIndex)
            }

            monitorSummaries.append(
                WorkspaceLegacyLayoutRepairMonitorSummary(
                    title: slot.title,
                    appNames: group.appNames,
                    featureSummary: group.reasons.prefix(3).joined(separator: ", ")
                )
            )
        }

        let repairedWorkspace = withResolvedDisplayMetadata(
            repairedWindows,
            screens: displaySlots.map { $0.asWorkspaceScreen() },
            displaySlots: displaySlots,
            preserveUpdatedAt: true
        )

        let explanation = buildCandidateExplanation(
            groups: orderedGroups,
            pathScore: pathScore,
            duplicateScore: duplicateScore,
            priorScore: priorScore
        )
        let confidence = max(0, min(1, totalScore / 120))
        let selectionLabel = orderedGroups
            .map { $0.appNames.joined(separator: " + ") }
            .joined(separator: " / ")

        return WorkspaceLegacyLayoutRepairCandidate(
            repairedWorkspace: repairedWorkspace,
            explanation: explanation,
            confidence: confidence,
            score: totalScore,
            selectionLabel: selectionLabel,
            monitorSummaries: monitorSummaries
        )
    }

    private func makeMonitorFeatures(for indices: [Int]) -> WorkspaceRepairMonitorFeatures {
        let monitorWindows = indices.map { windows[$0] }
        let frameKeys = indices
            .compactMap { windows[$0].relativeFrame }
            .map(Self.normalizedFrameKey)
            .sorted()
        let appNames = monitorWindows.map(\.appName)
        let layoutPattern = Self.detectLayoutPattern(for: frameKeys)
        let roleCounts = Self.roleCounts(for: monitorWindows)
        let paths = monitorWindows.compactMap { window -> String? in
            guard let path = window.openPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else {
                return nil
            }
            return path.lowercased()
        }
        let pathFrequency = Dictionary(paths.map { ($0, 1) }, uniquingKeysWith: +)
        let sharedPaths = pathFrequency.filter { $0.value >= 2 }.map(\.key).sorted()
        let containsPathBackedWindow = !paths.isEmpty

        var score = 0.0
        var reasons: [String] = []

        if !sharedPaths.isEmpty {
            score += 60
            reasons.append("shared project path")
        } else if containsPathBackedWindow {
            score += 8
            reasons.append("path-backed window")
        }

        if layoutPattern != "unknown" {
            score += 12
            reasons.append(layoutPattern)
        }

        let terminals = roleCounts[.terminal, default: 0]
        let ides = roleCounts[.ide, default: 0]
        let browsers = roleCounts[.browser, default: 0]
        let messaging = roleCounts[.messaging, default: 0]
        let documents = roleCounts[.document, default: 0]
        let meetings = roleCounts[.meeting, default: 0]
        let music = roleCounts[.music, default: 0]

        if terminals > 0, ides > 0 {
            score += 18
            reasons.append("IDE + terminal pairing")
        }

        if browsers > 0, meetings > 0 {
            score += 16
            reasons.append("browser + meeting pairing")
        }

        if messaging >= 2 {
            score += 20
            reasons.append("messaging pair")
        }

        if browsers > 0, documents > 0 {
            score += 10
            reasons.append("browser + document pairing")
        }

        if browsers > 0, music > 0 {
            score += 16
            reasons.append("browser + music pairing")
        }

        if monitorWindows.count == 1, layoutPattern == "fullscreen" {
            score += 8
            reasons.append("fullscreen app")
        }

        if containsPathBackedWindow, meetings > 0 {
            score -= 18
            reasons.append("path-backed app mixed with meeting app")
        }

        if containsPathBackedWindow, messaging > 0 {
            score -= 12
            reasons.append("path-backed app mixed with messaging app")
        }

        let signature = [
            layoutPattern,
            sharedPaths.joined(separator: ","),
            appNames.sorted().joined(separator: ","),
            frameKeys.joined(separator: "|")
        ].joined(separator: "||")

        return WorkspaceRepairMonitorFeatures(
            indices: indices.sorted(),
            windows: monitorWindows,
            appNames: appNames,
            layoutPattern: layoutPattern,
            roleCounts: roleCounts,
            containsPathBackedWindow: containsPathBackedWindow,
            score: score,
            reasons: reasons,
            signature: signature
        )
    }

    private func pathConsistencyScore(for groups: [WorkspaceRepairMonitorFeatures]) -> Double {
        let windowsByPath = Dictionary(grouping: windows.enumerated(), by: { _, window in
            window.openPath?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })

        var score = 0.0
        for (rawPath, entries) in windowsByPath {
            guard let path = rawPath, !path.isEmpty, entries.count >= 2 else { continue }
            let monitorIndices = Set(entries.compactMap { entry in
                groups.firstIndex(where: { $0.indices.contains(entry.offset) })
            })

            if monitorIndices.count == 1 {
                score += 40
                if let groupIndex = monitorIndices.first,
                   groups[groupIndex].layoutPattern != "unknown" {
                    score += 10
                }
            } else if monitorIndices.count > 1 {
                score -= 100 * Double(monitorIndices.count - 1)
            }
        }

        return score
    }

    private func duplicateFrameScore(for groups: [WorkspaceRepairMonitorFeatures]) -> Double {
        let duplicateGroups = Dictionary(grouping: windows.enumerated(), by: { _, window in
            window.relativeFrame.map(Self.normalizedFrameKey)
        }).values.filter { $0.count > 1 }

        var score = 0.0
        for duplicateGroup in duplicateGroups {
            let pathBackedGroupIndices = Set<Int>(duplicateGroup.compactMap { entry in
                guard BundleRegistry.supportsPathMatching(entry.element.bundleIdentifier),
                      let path = entry.element.openPath,
                      !path.isEmpty else {
                    return nil
                }
                return groups.firstIndex(where: { $0.indices.contains(entry.offset) })
            })
            let nonPathGroupIndices = Set<Int>(duplicateGroup.compactMap { entry in
                guard !BundleRegistry.supportsPathMatching(entry.element.bundleIdentifier) || entry.element.openPath == nil else {
                    return nil
                }
                return groups.firstIndex(where: { $0.indices.contains(entry.offset) })
            })

            if pathBackedGroupIndices.count == 1, nonPathGroupIndices.count == 1,
               pathBackedGroupIndices != nonPathGroupIndices {
                score += 12
            }
        }

        return score
    }

    private static func buildMonitorPriors(from referenceWorkspaces: [Workspace]) -> [WorkspaceRepairMonitorPrior] {
        referenceWorkspaces
            .filter { $0.hasSavedDisplayMetadata }
            .flatMap { workspace -> [WorkspaceRepairMonitorPrior] in
                let groupedWindows: [[WorkspaceWindow]]
                if let displaySlots = workspace.displaySlots, !displaySlots.isEmpty {
                    groupedWindows = displaySlots.compactMap { slot in
                        let windows = workspace.windows.filter { $0.displaySlotID == slot.id }
                        return windows.isEmpty ? nil : windows
                    }
                } else if let screens = workspace.screens, !screens.isEmpty {
                    groupedWindows = screens.indices.compactMap { screenIndex in
                        let windows = workspace.windows.filter { $0.screenIndex == screenIndex }
                        return windows.isEmpty ? nil : windows
                    }
                } else {
                    groupedWindows = []
                }

                return groupedWindows.map { windows in
                    let frameKeys = windows
                        .compactMap(\.relativeFrame)
                        .map(Self.normalizedFrameKey)
                        .sorted()
                    let layoutPattern = Self.detectLayoutPattern(for: frameKeys)
                    let roleCounts = Self.roleCounts(for: windows)
                    let containsPathBackedWindow = windows.contains {
                        guard let path = $0.openPath?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                            return false
                        }
                        return !path.isEmpty
                    }

                    return WorkspaceRepairMonitorPrior(
                        appCount: windows.count,
                        layoutPattern: layoutPattern,
                        roleCounts: roleCounts,
                        containsPathBackedWindow: containsPathBackedWindow
                    )
                }
            }
    }

    private func priorSimilarityScore(
        for groups: [WorkspaceRepairMonitorFeatures],
        priors: [WorkspaceRepairMonitorPrior]
    ) -> Double {
        guard !priors.isEmpty else { return 0 }

        return groups.reduce(0) { partialResult, group in
            let bestPriorScore = priors.map { prior -> Double in
                var score = 0.0

                if group.layoutPattern == prior.layoutPattern, group.layoutPattern != "unknown" {
                    score += 8
                }
                if group.windows.count == prior.appCount {
                    score += 3
                }
                if group.containsPathBackedWindow == prior.containsPathBackedWindow, group.containsPathBackedWindow {
                    score += 6
                }

                let roleOverlap = WorkspaceRepairRole.allCases.reduce(0) { overlap, role in
                    overlap + min(group.roleCounts[role, default: 0], prior.roleCounts[role, default: 0])
                }
                score += Double(roleOverlap) * 3

                return score
            }.max() ?? 0

            return partialResult + bestPriorScore
        }
    }

    private func buildCandidateExplanation(
        groups: [WorkspaceRepairMonitorFeatures],
        pathScore: Double,
        duplicateScore: Double,
        priorScore: Double
    ) -> String {
        var reasons: [String] = []

        if pathScore > 0 {
            reasons.append("same-path apps stayed together")
        }
        if duplicateScore > 0 {
            reasons.append("duplicate-frame conflicts favored path-backed windows")
        }

        for group in groups {
            if let firstReason = group.reasons.first, !reasons.contains(firstReason) {
                reasons.append(firstReason)
            }
        }

        if priorScore > 0 {
            reasons.append("matched healthy saved monitor patterns")
        }

        let lead = reasons.prefix(3).joined(separator: ", ")
        return lead.isEmpty
            ? "DeskJig found a likely monitor mapping from the saved geometry."
            : "DeskJig ranked this mapping highest because \(lead)."
    }

    private static func roleCounts(for windows: [WorkspaceWindow]) -> [WorkspaceRepairRole: Int] {
        windows.reduce(into: [:]) { counts, window in
            counts[role(for: window), default: 0] += 1
        }
    }

    private static func role(for window: WorkspaceWindow) -> WorkspaceRepairRole {
        let bundleId = window.bundleIdentifier
        switch bundleId {
        case BundleRegistry.zoom:
            return .meeting
        case "com.apple.MobileSMS":
            return .messaging
        case "com.apple.Notes":
            return .document
        case "com.spotify.client":
            return .music
        default:
            break
        }

        if BundleRegistry.isTerminal(bundleId) {
            return .terminal
        }
        if BundleRegistry.isIDE(bundleId) {
            return .ide
        }
        if BundleRegistry.isBrowser(bundleId) {
            return .browser
        }
        if BundleRegistry.isMessaging(bundleId) {
            return .messaging
        }
        if BundleRegistry.isDocument(bundleId) {
            return .document
        }
        return .other
    }

    private static func detectLayoutPattern(for frameKeys: [String]) -> String {
        let key = frameKeys.joined(separator: "|")
        switch key {
        case "0.0,0.0,0.5,1.0|0.5,0.0,0.5,1.0":
            return "50/50 split"
        case "0.0,0.0,0.7,1.0|0.7,0.0,0.3,1.0":
            return "70/30 split"
        case "0.0,0.0,0.3,1.0|0.3,0.0,0.7,1.0":
            return "30/70 split"
        case "0.0,0.0,0.5,1.0|0.5,0.0,0.5,0.5|0.5,0.5,0.5,0.5":
            return "right stack"
        case "0.0,0.0,0.5,0.5|0.0,0.5,0.5,0.5|0.5,0.0,0.5,1.0":
            return "left stack"
        case "0.0,0.0,0.5,0.5|0.0,0.5,0.5,0.5|0.5,0.0,0.5,0.5|0.5,0.5,0.5,0.5":
            return "quadrant"
        case "0.0,0.0,1.0,1.0":
            return "fullscreen"
        case "0.0,0.0,0.5,1.0|0.5,0.0,0.5,0.5|0.5,0.5,0.5005,0.5":
            return "editor + right stack"
        default:
            return "unknown"
        }
    }

    private static func normalizedFrameKey(_ frame: RelativeWindowFrame) -> String {
        "\(frame.xPercent),\(frame.yPercent),\(frame.widthPercent),\(frame.heightPercent)"
    }

    private func layerIsConflictFree(_ indices: [Int], using frames: [RelativeWindowFrame]) -> Bool {
        for index in indices.indices {
            for otherIndex in indices.indices where otherIndex > index {
                let lhs = frames[indices[index]]
                let rhs = frames[indices[otherIndex]]
                if lhs == rhs ||
                    Self.contains(lhs, rhs) ||
                    Self.contains(rhs, lhs) ||
                    Self.repairOverlapArea(between: lhs, and: rhs) > 0.0001 {
                    return false
                }
            }
        }

        return true
    }

    private static func uniquePartitions(
        for conflicts: [[Bool]],
        colorCount: Int
    ) -> [[[Int]]] {
        guard !conflicts.isEmpty else { return [] }

        let vertexOrder = conflicts.indices.sorted { lhs, rhs in
            let lhsDegree = conflicts[lhs].filter { $0 }.count
            let rhsDegree = conflicts[rhs].filter { $0 }.count
            if lhsDegree == rhsDegree {
                return lhs < rhs
            }
            return lhsDegree > rhsDegree
        }

        var assignments = Array(repeating: -1, count: conflicts.count)
        var canonicalPartitions: [String: [[Int]]] = [:]

        func visit(_ orderIndex: Int, maxUsedColor: Int) {
            if canonicalPartitions.count > 8 {
                return
            }

            if orderIndex == vertexOrder.count {
                let usedColors = Set(assignments).subtracting([-1])
                guard usedColors.count == colorCount else { return }

                var layers = Array(repeating: [Int](), count: colorCount)
                for (vertex, color) in assignments.enumerated() where color >= 0 {
                    layers[color].append(vertex)
                }
                guard layers.allSatisfy({ !$0.isEmpty }) else { return }

                let canonical = layers
                    .map { $0.sorted() }
                    .sorted { lhs, rhs in
                        let lhsKey = lhs.map(String.init).joined(separator: ",")
                        let rhsKey = rhs.map(String.init).joined(separator: ",")
                        return lhsKey < rhsKey
                    }
                let key = canonical
                    .map { $0.map(String.init).joined(separator: ",") }
                    .joined(separator: "|")
                canonicalPartitions[key] = canonical
                return
            }

            let vertex = vertexOrder[orderIndex]
            let allowedMaxColor = min(colorCount - 1, maxUsedColor + 1)

            for color in 0...allowedMaxColor {
                var isValid = true
                for other in conflicts.indices where assignments[other] == color {
                    if conflicts[vertex][other] {
                        isValid = false
                        break
                    }
                }

                guard isValid else { continue }
                assignments[vertex] = color
                visit(orderIndex + 1, maxUsedColor: max(maxUsedColor, color))
                assignments[vertex] = -1
            }
        }

        visit(0, maxUsedColor: -1)
        return Array(canonicalPartitions.values)
    }

    private static func contains(_ lhs: RelativeWindowFrame, _ rhs: RelativeWindowFrame) -> Bool {
        lhs.xPercent <= rhs.xPercent &&
            lhs.yPercent <= rhs.yPercent &&
            lhs.xPercent + lhs.widthPercent >= rhs.xPercent + rhs.widthPercent &&
            lhs.yPercent + lhs.heightPercent >= rhs.yPercent + rhs.heightPercent
    }

    private static func repairOverlapArea(between lhs: RelativeWindowFrame, and rhs: RelativeWindowFrame) -> Double {
        let lhsMaxX = lhs.xPercent + lhs.widthPercent
        let lhsMaxY = lhs.yPercent + lhs.heightPercent
        let rhsMaxX = rhs.xPercent + rhs.widthPercent
        let rhsMaxY = rhs.yPercent + rhs.heightPercent

        let overlapWidth = min(lhsMaxX, rhsMaxX) - max(lhs.xPercent, rhs.xPercent)
        let overlapHeight = min(lhsMaxY, rhsMaxY) - max(lhs.yPercent, rhs.yPercent)

        return max(0, overlapWidth) * max(0, overlapHeight)
    }
}
