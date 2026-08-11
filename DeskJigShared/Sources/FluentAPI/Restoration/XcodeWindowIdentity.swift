//  XcodeWindowIdentity.swift
//  DeskJigShared

import Foundation
import CoreGraphics

enum XcodeIdentityTraceReason: String, Sendable {
    case pathConfirmedSelection
    case pathConfirmedSelectionAmbiguous
    case pathConfirmedButActivatedDifferentWindow
    case xcodeWindowLevelDemotion
}

struct XcodeWindowIdentity: Sendable, Hashable {
    let normalizedDirectory: String?
    let axElementHash: Int?
    let axWindowNumber: Int?
    let cgWindowId: CGWindowID?
    let title: String?
    let frame: CGRect?
    let pid: pid_t?

    var identityKey: String {
        let path = normalizedDirectory ?? "nil"
        let axNum = axWindowNumber.map(String.init) ?? "nil"
        let hash = axElementHash.map(String.init) ?? "nil"
        let cg = cgWindowId.map(String.init) ?? "nil"
        return "path=\(path)|cg=\(cg)|axWindow=\(axNum)|axHash=\(hash)"
    }
}

struct XcodeWindowCoverageTopology: Sendable {
    let expectedPathSlots: [String]
    let observedPathSlots: [String]
    let missingPathSlots: [String]
    let duplicatePathSlots: [String]
    let expectedCountsByPath: [String: Int]
    let observedCountsByPath: [String: Int]

    var isComplete: Bool { missingPathSlots.isEmpty }

    init(expectedPathSlots: [String], observedPathSlots: [String]) {
        self.expectedPathSlots = expectedPathSlots
        self.observedPathSlots = observedPathSlots
        self.expectedCountsByPath = Dictionary(expectedPathSlots.map { ($0, 1) }, uniquingKeysWith: +)
        self.observedCountsByPath = Dictionary(observedPathSlots.map { ($0, 1) }, uniquingKeysWith: +)

        var observedUsage: [String: Int] = [:]
        var missing: [String] = []
        for expectedPath in expectedPathSlots {
            let used = observedUsage[expectedPath, default: 0]
            let observedCount = observedCountsByPath[expectedPath, default: 0]
            if used < observedCount {
                observedUsage[expectedPath] = used + 1
            } else {
                missing.append(expectedPath)
            }
        }
        self.missingPathSlots = missing

        var expectedUsage: [String: Int] = [:]
        var duplicates: [String] = []
        for observedPath in observedPathSlots {
            let used = expectedUsage[observedPath, default: 0]
            let expectedCount = expectedCountsByPath[observedPath, default: 0]
            if used < expectedCount {
                expectedUsage[observedPath] = used + 1
            } else {
                duplicates.append(observedPath)
            }
        }
        self.duplicatePathSlots = duplicates
    }
}

