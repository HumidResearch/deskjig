//
//  SkyLightService.swift
//  DeskJigShared
//
//  Created by Marco Freedom on 03.12.2025.
//
//  Service for querying macOS Spaces information via private SkyLight framework.
//
//  ⚠️ WARNING: This uses private APIs that may break in future macOS versions.
//  These APIs are not documented and are subject to change without notice.
//
//  NOTE: Only READ operations are reliable. Window manipulation (moving between
//  spaces, creating/destroying spaces) does NOT work reliably and has been removed.
//

import Foundation
import Cocoa

// MARK: - Private SkyLight API Declarations (READ-ONLY)

/// Gets the main CoreGraphics connection ID for the current session.
@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

/// Gets the currently active (visible) space ID on the main display.
@_silgen_name("CGSGetActiveSpace")
func CGSGetActiveSpace(_ cid: Int32) -> Int

/// Copies the list of spaces for a given mask.
@_silgen_name("CGSCopySpaces")
func CGSCopySpaces(_ cid: Int32, _ mask: Int32) -> CFArray?

/// Gets the type of a space.
@_silgen_name("CGSSpaceGetType")
func CGSSpaceGetType(_ cid: Int32, _ space: Int) -> Int32

/// Copies display spaces information for managed displays.
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?

/// Gets all spaces that a window belongs to.
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windowIDs: CFArray) -> CFArray?

/// Gets windows on specific spaces.
@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
func CGSCopyWindowsWithOptionsAndTags(
    _ cid: Int32,
    _ owner: pid_t,
    _ spaces: CFArray,
    _ options: Int32,
    _ setTags: UnsafeMutablePointer<UInt64>?,
    _ clearTags: UnsafeMutablePointer<UInt64>?
) -> CFArray?

// MARK: - Space Type Constants

/// Constants for space types returned by CGSSpaceGetType
public enum CGSSpaceType: Int32, Sendable {
    case user = 0           // User-created desktop spaces
    case fullscreen = 1     // Fullscreen spaces
    case system = 2         // System spaces (e.g. Dashboard)
    
    public var description: String {
        switch self {
        case .user: return "User"
        case .fullscreen: return "Fullscreen"
        case .system: return "System"
        }
    }
}

/// Constants for space mask in CGSCopySpaces and CGSCopySpacesForWindows
public struct CGSSpaceMask: OptionSet, Sendable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    
    public static let includesCurrent = CGSSpaceMask(rawValue: 1 << 0)  // 1
    public static let includesOthers = CGSSpaceMask(rawValue: 1 << 1)   // 2
    public static let includesUser = CGSSpaceMask(rawValue: 1 << 2)     // 4
    public static let visible = CGSSpaceMask(rawValue: 1 << 16)         // 65536
    
    public static let currentSpace = CGSSpaceMask(rawValue: 5)          // includesUser | includesCurrent
    public static let otherSpaces = CGSSpaceMask(rawValue: 3)           // includesOthers | includesCurrent
    public static let all = CGSSpaceMask(rawValue: 7)                   // includesUser | includesOthers | includesCurrent
    public static let allVisible = CGSSpaceMask(rawValue: 65543)        // visible | all
}

// MARK: - SpaceInfo Model

/// Represents information about a macOS Space
public struct SpaceInfo: Identifiable, Hashable, Sendable {
    public let id: Int              // Space ID
    public let type: CGSSpaceType   // Type of space
    public let displayID: Int?      // Display this space belongs to (if known)
    public let isActive: Bool       // Whether this is the currently active space
    public let index: Int?          // User-facing index (1, 2, 3, etc.) if known
    
    public init(
        id: Int,
        type: CGSSpaceType,
        displayID: Int? = nil,
        isActive: Bool = false,
        index: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.displayID = displayID
        self.isActive = isActive
        self.index = index
    }
    
    public var description: String {
        var desc = "Space \(id) (\(type.description))"
        if let idx = index {
            desc = "Desktop \(idx) - " + desc
        }
        if isActive {
            desc += " [Active]"
        }
        return desc
    }
}

// MARK: - DisplaySpaceInfo Model

/// Information about a display and its current space
public struct DisplaySpaceInfo: Sendable {
    public let displayUUID: String
    public let displayID: Int?
    public let currentSpaceID: Int
    public let allSpaceIDs: [Int]
    
    public var description: String {
        return "Display \(displayID ?? 0) (UUID: \(displayUUID.prefix(8))...): Current Space \(currentSpaceID), All: \(allSpaceIDs)"
    }
}

// MARK: - SkyLightService Protocol

/// Protocol for SkyLight operations to enable testing.
public protocol SkyLightServiceProtocol: AnyObject {
    // Connection
    func getConnectionID() -> Int32
    func isAvailable() -> Bool
    
    // Space Queries
    func getActiveSpace() -> Int
    func getActiveSpaceInfo() -> SpaceInfo?
    func getActiveSpacesPerDisplay() -> [DisplaySpaceInfo]
    func getAllVisibleSpaces() -> Set<Int>
    func getAllSpaces(mask: CGSSpaceMask) -> [SpaceInfo]
    func getUserSpaces() -> [SpaceInfo]
    func getFullscreenSpaces() -> [SpaceInfo]
    func getSpaceType(spaceID: Int) -> CGSSpaceType?
    
    // Compositor Control
    func disableCompositorUpdates()
    func reenableCompositorUpdates()

    // Window-Space Queries
    func getSpaceForWindow(windowID: CGWindowID) -> Int?
    func getSpaceForWindow(windowID: CGWindowID, processID: pid_t) -> Int?
    func getSpacesForWindow(windowID: CGWindowID) -> [Int]
    func isWindowOnCurrentSpace(windowID: CGWindowID) -> Bool
    func isWindowOnAnyVisibleSpace(windowID: CGWindowID) -> Bool

    // Validation
    func isTemporaryWindowID(_ windowID: CGWindowID) -> Bool
    func isTemporaryWindowID(_ windowID: Int) -> Bool
}

// MARK: - SkyLightService Implementation

/// Service for querying macOS Spaces information via private SkyLight framework.
///
/// ⚠️ WARNING: This uses private APIs that may break in future macOS versions.
///
/// NOTE: Only READ operations are supported. Window manipulation does not work reliably.
///
/// ## Usage Example:
/// ```swift
/// let skylight = SkyLightService.shared
///
/// // Get current space
/// let currentSpace = skylight.getActiveSpace()
///
/// // Get all user spaces
/// let spaces = skylight.getUserSpaces()
///
/// // Check which space a window is on
/// let spaceID = skylight.getSpaceForWindow(windowID: myWindowID)
///
/// // Check if window is visible (on any currently shown space)
/// let isVisible = skylight.isWindowOnAnyVisibleSpace(windowID: myWindowID)
/// ```
public class SkyLightService: SkyLightServiceProtocol {
    
    public static let shared = SkyLightService()
    
    /// Cached connection ID (doesn't change during session)
    private var cachedConnectionID: Int32?
    
    /// Threshold for temporary window IDs generated by snapshot capture.
    private static let temporaryWindowIDThreshold: Int = 1_000_000_000
    
    public init() {}
    
    // MARK: - Window ID Validation
    
    /// Checks if a window ID is a temporary ID (not a valid CGWindowID).
    public func isTemporaryWindowID(_ windowID: CGWindowID) -> Bool {
        return Int(windowID) >= Self.temporaryWindowIDThreshold
    }
    
    /// Checks if a window ID is a temporary ID (Int version).
    public func isTemporaryWindowID(_ windowID: Int) -> Bool {
        return windowID >= Self.temporaryWindowIDThreshold
    }
    
    /// Validates a window ID before using it with CGS* functions.
    private func validateWindowID(_ windowID: CGWindowID) -> Bool {
        if isTemporaryWindowID(windowID) {
            DeskJigLog.debug(.window, "🌌 SkyLight: Rejecting temporary window ID \(windowID)")
            return false
        }
        return true
    }
    
    // MARK: - Connection
    
    /// Gets the main CoreGraphics connection ID.
    public func getConnectionID() -> Int32 {
        if let cached = cachedConnectionID {
            return cached
        }
        let cid = CGSMainConnectionID()
        cachedConnectionID = cid
        DeskJigLog.info(.window, "🌌 SkyLight: Connection ID = \(cid)")
        return cid
    }
    
    /// Checks if SkyLight functionality is available.
    public func isAvailable() -> Bool {
        let cid = getConnectionID()
        return cid > 0
    }
    
    // MARK: - Compositor Control

    /// Dynamically resolved SLSDisableUpdate / SLSReenableUpdate from the SkyLight private
    /// framework. Using dlsym avoids a hard link dependency that would fail for CLI targets.
    private static let slsDisableUpdate: (@convention(c) (Int32) -> Void)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let sym = dlsym(handle, "SLSDisableUpdate") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (Int32) -> Void).self)
    }()

    private static let slsReenableUpdate: (@convention(c) (Int32) -> Void)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let sym = dlsym(handle, "SLSReenableUpdate") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (Int32) -> Void).self)
    }()

    /// Freezes the screen compositor. All subsequent window operations (move, resize, reorder)
    /// are batched and will appear atomically when `reenableCompositorUpdates()` is called.
    /// Must always be paired with `reenableCompositorUpdates()`.
    public func disableCompositorUpdates() {
        let cid = getConnectionID()
        guard cid > 0 else { return }
        Self.slsDisableUpdate?(cid)
    }

    /// Re-enables compositor updates and flushes all batched window operations at once.
    public func reenableCompositorUpdates() {
        let cid = getConnectionID()
        guard cid > 0 else { return }
        Self.slsReenableUpdate?(cid)
    }

    // MARK: - Space Queries
    
    /// Gets the currently active space ID (main display).
    public func getActiveSpace() -> Int {
        let cid = getConnectionID()
        return CGSGetActiveSpace(cid)
    }
    
    /// Gets the currently active space as a SpaceInfo object.
    public func getActiveSpaceInfo() -> SpaceInfo? {
        let activeSpaceID = getActiveSpace()
        guard activeSpaceID > 0 else { return nil }
        
        let type = getSpaceType(spaceID: activeSpaceID) ?? .user
        return SpaceInfo(id: activeSpaceID, type: type, isActive: true)
    }
    
    /// Gets the currently visible/active space for EACH display.
    /// In multi-monitor setups, each display can show a different space.
    public func getActiveSpacesPerDisplay() -> [DisplaySpaceInfo] {
        let cid = getConnectionID()
        
        guard let displaySpacesArray = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else {
            return []
        }
        
        var results: [DisplaySpaceInfo] = []
        
        for displayInfo in displaySpacesArray {
            guard let displayUUID = displayInfo["Display Identifier"] as? String else {
                continue
            }
            
            let displayID = displayInfo["Display ID"] as? Int
            
            // Get current space for this display
            var currentSpaceID: Int = 0
            if let currentSpace = displayInfo["Current Space"] as? [String: Any] {
                if let id64 = currentSpace["id64"] as? Int {
                    currentSpaceID = id64
                } else if let id = currentSpace["id"] as? Int {
                    currentSpaceID = id
                } else if let managedSpaceID = currentSpace["ManagedSpaceID"] as? Int {
                    currentSpaceID = managedSpaceID
                }
            }
            
            // Get all spaces for this display
            var allSpaceIDs: [Int] = []
            if let spacesInfo = displayInfo["Spaces"] as? [[String: Any]] {
                for spaceInfo in spacesInfo {
                    if let id64 = spaceInfo["id64"] as? Int {
                        allSpaceIDs.append(id64)
                    } else if let id = spaceInfo["id"] as? Int {
                        allSpaceIDs.append(id)
                    } else if let managedSpaceID = spaceInfo["ManagedSpaceID"] as? Int {
                        allSpaceIDs.append(managedSpaceID)
                    }
                }
            }
            
            if currentSpaceID > 0 {
                results.append(DisplaySpaceInfo(
                    displayUUID: displayUUID,
                    displayID: displayID,
                    currentSpaceID: currentSpaceID,
                    allSpaceIDs: allSpaceIDs
                ))
            }
        }
        
        DeskJigLog.debug(.window, "🌌 SkyLight: Found \(results.count) displays with active spaces")
        return results
    }
    
    /// Gets all currently visible space IDs across all displays.
    public func getAllVisibleSpaces() -> Set<Int> {
        let displays = getActiveSpacesPerDisplay()
        return Set(displays.map { $0.currentSpaceID })
    }
    
    /// Gets all spaces matching the given mask.
    public func getAllSpaces(mask: CGSSpaceMask = .all) -> [SpaceInfo] {
        let cid = getConnectionID()
        let activeSpace = getActiveSpace()
        
        // Use CGSCopyManagedDisplaySpaces (more reliable)
        if let displaySpacesArray = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] {
            var spaces: [SpaceInfo] = []
            var userSpaceIndex = 1

            for displayInfo in displaySpacesArray {
                guard let spacesInfo = displayInfo["Spaces"] as? [[String: Any]] else {
                    continue
                }

                for spaceInfo in spacesInfo {
                    let spaceID: Int
                    if let id64 = spaceInfo["id64"] as? Int {
                        spaceID = id64
                    } else if let id = spaceInfo["id"] as? Int {
                        spaceID = id
                    } else if let managedSpaceID = spaceInfo["ManagedSpaceID"] as? Int {
                        spaceID = managedSpaceID
                    } else {
                        continue
                    }

                    let typeRaw = spaceInfo["type"] as? Int32 ?? 0
                    let type = CGSSpaceType(rawValue: typeRaw) ?? .user
                    let isActive = spaceID == activeSpace
                    
                    // Filter by mask if needed
                    if mask == .includesUser && type != .user { continue }

                    let index = type == .user ? userSpaceIndex : nil
                    if type == .user {
                        userSpaceIndex += 1
                    }

                    spaces.append(SpaceInfo(
                        id: spaceID,
                        type: type,
                        isActive: isActive,
                        index: index
                    ))
                }
            }
            
            if !spaces.isEmpty {
                DeskJigLog.debug(.window, "🌌 SkyLight: Found \(spaces.count) spaces")
                return spaces
            }
        }
        
        return []
    }
    
    /// Gets all user-created desktop spaces.
    public func getUserSpaces() -> [SpaceInfo] {
        return getAllSpaces().filter { $0.type == .user }
    }
    
    /// Gets all fullscreen app spaces.
    public func getFullscreenSpaces() -> [SpaceInfo] {
        return getAllSpaces().filter { $0.type == .fullscreen }
    }
    
    /// Gets the type of a specific space.
    public func getSpaceType(spaceID: Int) -> CGSSpaceType? {
        let cid = getConnectionID()
        let typeRaw = CGSSpaceGetType(cid, spaceID)
        return CGSSpaceType(rawValue: typeRaw)
    }
    
    // MARK: - Window-Space Queries
    
    /// Gets the primary space that a window belongs to.
    public func getSpaceForWindow(windowID: CGWindowID) -> Int? {
        guard validateWindowID(windowID) else { return nil }
        let spaces = getSpacesForWindow(windowID: windowID)
        return spaces.first
    }
    
    /// Gets all spaces that a window exists on.
    public func getSpacesForWindow(windowID: CGWindowID) -> [Int] {
        guard validateWindowID(windowID) else { return [] }
        
        let cid = getConnectionID()
        let windowArray = [windowID] as CFArray
        
        // Use CGSCopySpacesForWindows - this only works for windows on visible spaces
        // For windows on hidden spaces, this returns empty
        if let spacesArray = CGSCopySpacesForWindows(cid, CGSSpaceMask.all.rawValue, windowArray) as? [Int], !spacesArray.isEmpty {
            return spacesArray
        }
        
        DeskJigLog.debug(.window, "🌌 SkyLight: CGSCopySpacesForWindows returned empty for window \(windowID)")
        return []
    }

    /// Gets the primary space for a window, with fallback enumeration for hidden windows.
    /// - Parameters:
    ///   - windowID: The window ID to query
    ///   - processID: The process ID (unused - enumeration fallback disabled due to crashes)
    /// - Returns: The space ID, or nil if not found
    public func getSpaceForWindow(windowID: CGWindowID, processID: pid_t) -> Int? {
        guard validateWindowID(windowID) else { return nil }

        // Use CGSCopySpacesForWindows - only works for windows on visible spaces
        // For windows on hidden spaces, this returns empty and we return nil
        // NOTE: We tried enumeration via CGSCopyWindowsWithOptionsAndTags but it crashes
        let spaces = getSpacesForWindow(windowID: windowID)
        return spaces.first
    }

    /// Checks if a window is on the currently active space (main display).
    public func isWindowOnCurrentSpace(windowID: CGWindowID) -> Bool {
        guard validateWindowID(windowID) else { return true } // Assume temp windows are on current
        let currentSpace = getActiveSpace()
        let windowSpaces = getSpacesForWindow(windowID: windowID)
        return windowSpaces.contains(currentSpace)
    }
    
    /// Checks if a window is on ANY currently visible space (multi-monitor aware).
    public func isWindowOnAnyVisibleSpace(windowID: CGWindowID) -> Bool {
        guard validateWindowID(windowID) else { return true } // Assume temp windows are visible
        let windowSpaces = getSpacesForWindow(windowID: windowID)
        let visibleSpaces = getAllVisibleSpaces()
        return !windowSpaces.isEmpty && !visibleSpaces.intersection(windowSpaces).isEmpty
    }
    
    // NOTE: getWindowsOnSpace removed - CGSCopyWindowsWithOptionsAndTags crashes even with valid processID
    
    // MARK: - WindowInfo Integration
    
    /// Gets the space that a WindowInfo window belongs to.
    public func getSpaceForWindow(window: WindowInfo) -> Int? {
        if isTemporaryWindowID(window.id) { return nil }
        return getSpaceForWindow(windowID: CGWindowID(window.id))
    }
    
    /// Checks if a WindowInfo window is on the currently active space.
    public func isWindowOnCurrentSpace(window: WindowInfo) -> Bool {
        if isTemporaryWindowID(window.id) { return true }
        return isWindowOnCurrentSpace(windowID: CGWindowID(window.id))
    }
    
    /// Checks if a WindowInfo window is on ANY currently visible space.
    public func isWindowOnAnyVisibleSpace(window: WindowInfo) -> Bool {
        if isTemporaryWindowID(window.id) { return true }
        return isWindowOnAnyVisibleSpace(windowID: CGWindowID(window.id))
    }
    
    // MARK: - Debug
    
    /// Debug method: Prints information about all spaces.
    public func debugPrintAllSpaces() {
        DeskJigLog.info(.window, "🌌 === SkyLight Spaces Debug ===")
        DeskJigLog.info(.window, "🌌 Active Space: \(getActiveSpace())")
        
        let displays = getActiveSpacesPerDisplay()
        DeskJigLog.info(.window, "🌌 Displays: \(displays.count)")
        for display in displays {
            DeskJigLog.info(.window, "🌌   \(display.description)")
        }
        
        DeskJigLog.info(.window, "🌌 Visible Spaces: \(getAllVisibleSpaces().sorted())")
        
        let allSpaces = getAllSpaces()
        DeskJigLog.info(.window, "🌌 All Spaces: \(allSpaces.count)")
        for space in allSpaces {
            DeskJigLog.info(.window, "🌌   \(space.description)")
        }
        DeskJigLog.info(.window, "🌌 ==============================")
    }
}
