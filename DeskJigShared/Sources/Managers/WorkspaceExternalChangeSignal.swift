//
//  WorkspaceExternalChangeSignal.swift
//  DeskJigShared
//
//  Cross-process change signal for the SavedWorkspaces store (#655).
//

import Foundation

/// Cross-process change signal for the SavedWorkspaces store (#655).
///
/// `deskjig` mutates the store out-of-process (`workspace create-from-spec`,
/// delete, window updates). The running DeskJig.app only re-reads the store when
/// something triggers a reload of its in-memory workspace list, so a CLI-created
/// workspace used to stay invisible to in-app restores (`deskjig app restore`)
/// and the UI until the app was relaunched. The CLI posts this distributed
/// notification after every external store write; the app observes it via
/// `WorkspaceExternalChangeObserver` and reloads `WindowManager.savedWorkspaces`.
///
/// Unlike a `bento://` refresh ping, a distributed notification needs no
/// LaunchServices routing, so the dual-bundle gotcha (#565) cannot deliver the
/// signal to the wrong DeskJig.app copy — every running instance simply reloads.
public enum WorkspaceExternalChangeSignal {
    /// Distributed notification name, namespaced under the app's bundle id so
    /// unrelated processes cannot collide with it accidentally.
    public static let notificationName = Notification.Name(BundleIdentity.workspacesChangedNotificationName)

    /// Posts the change signal. `deliverImmediately` bypasses notification
    /// coalescing and delivery suspension so the signal from a short-lived CLI
    /// process still lands before that process exits.
    public static func post(center: DistributedNotificationCenter = .default()) {
        center.postNotificationName(
            notificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}

/// Observes `WorkspaceExternalChangeSignal` and invokes `onChange` on the main
/// queue for every received signal. Hold the instance for the lifetime of the
/// subscription; releasing it removes the observer.
public final class WorkspaceExternalChangeObserver {
    private let center: DistributedNotificationCenter
    private var token: NSObjectProtocol?

    /// - Parameters:
    ///   - center: Injected with a default so production call sites stay
    ///     unchanged while tests can supply their own center (#481 pattern).
    ///   - onChange: Called on the main queue whenever the signal arrives.
    public init(
        center: DistributedNotificationCenter = .default(),
        onChange: @escaping () -> Void
    ) {
        self.center = center
        self.token = center.addObserver(
            forName: WorkspaceExternalChangeSignal.notificationName,
            object: nil,
            queue: .main
        ) { _ in
            onChange()
        }
    }

    deinit {
        if let token {
            center.removeObserver(token)
        }
    }
}
