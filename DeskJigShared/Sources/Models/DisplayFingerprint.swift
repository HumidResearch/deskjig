//  DisplayFingerprint.swift
//  DeskJigShared

import Foundation
import CoreGraphics

public struct DisplayFingerprint: Codable, Hashable, Sendable {
    public let vendorID: Int
    public let modelNumber: Int
    public let serialNumber: Int?
    public let displayUUID: String?
    public let name: String
    public let resolution: CGSize

    public init(
        vendorID: Int,
        modelNumber: Int,
        serialNumber: Int?,
        displayUUID: String?,
        name: String,
        resolution: CGSize
    ) {
        self.vendorID = vendorID
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.displayUUID = displayUUID
        self.name = name
        self.resolution = resolution
    }

    public init(screen: FullScreenInfo) {
        self.init(
            vendorID: screen.vendorID,
            modelNumber: screen.modelNumber,
            serialNumber: screen.serialNumber,
            displayUUID: screen.displayUUID,
            name: screen.name,
            resolution: screen.resolution
        )
    }

    public var hasStableSerialIdentity: Bool {
        vendorID != 0 && modelNumber != 0 && (serialNumber ?? 0) > 0
    }

    public var normalizedDisplayUUID: String? {
        guard let displayUUID else {
            return nil
        }
        let normalized = displayUUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }
        return normalized.uppercased()
    }

    public var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var persistentIdentifier: String {
        if hasStableSerialIdentity, let serialNumber {
            return "serial:\(vendorID):\(modelNumber):\(serialNumber)"
        }
        if let normalizedDisplayUUID {
            return "uuid:\(normalizedDisplayUUID)"
        }
        return "fallback:\(vendorID):\(modelNumber):\(normalizedName):\(Int(resolution.width))x\(Int(resolution.height))"
    }

    public func matches(_ other: DisplayFingerprint) -> Bool {
        if hasStableSerialIdentity, other.hasStableSerialIdentity {
            return vendorID == other.vendorID &&
                modelNumber == other.modelNumber &&
                serialNumber == other.serialNumber
        }

        if let normalizedDisplayUUID,
           let otherUUID = other.normalizedDisplayUUID {
            return normalizedDisplayUUID == otherUUID
        }

        return vendorID == other.vendorID &&
            modelNumber == other.modelNumber &&
            normalizedName == other.normalizedName &&
            Int(resolution.width) == Int(other.resolution.width) &&
            Int(resolution.height) == Int(other.resolution.height)
    }
}

public struct IgnoredDisplayPreference: Codable, Hashable, Sendable, Identifiable {
    public let fingerprint: DisplayFingerprint
    public let lastSeenName: String
    public let lastSeenDisplayID: Int?

    public init(fingerprint: DisplayFingerprint, lastSeenName: String, lastSeenDisplayID: Int?) {
        self.fingerprint = fingerprint
        self.lastSeenName = lastSeenName
        self.lastSeenDisplayID = lastSeenDisplayID
    }

    public init(screen: FullScreenInfo) {
        self.init(
            fingerprint: screen.displayFingerprint,
            lastSeenName: screen.name,
            lastSeenDisplayID: screen.displayID
        )
    }

    public var id: String {
        fingerprint.persistentIdentifier
    }

    public func matches(_ screen: FullScreenInfo) -> Bool {
        fingerprint.matches(screen.displayFingerprint)
    }
}
