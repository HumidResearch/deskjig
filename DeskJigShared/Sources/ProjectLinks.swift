//
//  ProjectLinks.swift
//  DeskJigShared
//
//  Canonical links to DeskJig's public home on GitHub.
//

import Foundation

/// Single source of truth for the project's public URLs. Every surface that
/// points at the repository (settings, menus, docs) should use these so the
/// destination only ever needs to change in one place.
public enum ProjectLinks {

    /// The open-source repository on GitHub. Constant literal, so the force
    /// unwrap cannot fail at runtime.
    public static let repositoryURL = URL(string: "https://github.com/HumidResearch/deskjig")! // swiftlint:disable:this force_unwrapping

    /// GitHub issue tracker. "Send Feedback" hands off to this page — DeskJig
    /// has no feedback backend of its own.
    public static let issueTrackerURL = repositoryURL.appendingPathComponent("issues")
}
