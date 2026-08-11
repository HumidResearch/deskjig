//  DirectoryWorkspace+Persistence.swift
//  DeskJigShared

import Foundation

extension DirectoryWorkspace {
    /// Save this workspace
    public func save() throws {
        DirectoryWorkspaceManager.shared.saveWorkspace(self)
        DeskJigLog.info(.workspace, "DirectoryWorkspace: Saved '\(name)'")
    }

    /// Delete this workspace
    public func delete() throws {
        DirectoryWorkspaceManager.shared.deleteWorkspace(self)
        DeskJigLog.info(.workspace, "DirectoryWorkspace: Deleted '\(name)'")
    }
}
