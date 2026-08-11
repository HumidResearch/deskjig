//  FluentServices.swift
//  DeskJigShared

import Foundation
import Combine

/// Service locator singleton that provides access to required services for the fluent API.
///
/// Configure this once at app initialization:
/// ```swift
/// FluentServices.configure(
///     axWindowService: AXWindowService.shared,
///     displayManager: displayManager
/// )
/// ```
public final class FluentServices {
    
    /// Shared singleton instance
    public static let shared = FluentServices()
    
    // MARK: - Service References

    /// The AX window service for window discovery and manipulation
    internal var axWindowService: AXWindowServiceProtocol?

    /// Display manager for screen information
    internal var displayManager: DisplayManager?

    /// Optional application manager for app-level operations (launching apps, etc.)
    internal var applicationManager: ApplicationManagerProtocol?

    /// Workspace manager for workspace operations (Fluent Workspace API)
    internal var workspaceManager: WorkspaceManager?

    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Configuration
    
    /// Configures the fluent services with AX-based window service.
    /// Call this once at app initialization.
    ///
    /// - Parameters:
    ///   - axWindowService: The AX window service for window operations
    ///   - displayManager: The display manager for screen information
    ///   - applicationManager: Optional application manager for app operations
    ///   - workspaceManager: Optional workspace manager for workspace operations
    public static func configure(
        axWindowService: AXWindowServiceProtocol,
        displayManager: DisplayManager,
        applicationManager: ApplicationManagerProtocol? = nil,
        workspaceManager: WorkspaceManager? = nil
    ) {
        shared.axWindowService = axWindowService
        shared.displayManager = displayManager
        shared.applicationManager = applicationManager
        shared.workspaceManager = workspaceManager
    }
    
    /// Resets all service references. Useful for testing.
    public static func reset() {
        shared.axWindowService = nil
        shared.displayManager = nil
        shared.applicationManager = nil
        shared.workspaceManager = nil
    }
    
    /// Returns true if all required services have been configured.
    public static var isConfigured: Bool {
        return shared.axWindowService != nil &&
               shared.displayManager != nil
    }

    // MARK: - Publishers

    /// Publisher for workspace change events (creation, deletion, rename, update, duplicate)
    /// Subscribe to this for reactive UI updates when workspaces change
    public var workspaceChanges: AnyPublisher<WorkspaceChangeEvent, Never>? {
        workspaceManager?.workspaceChangesPublisher.eraseToAnyPublisher()
    }
}
