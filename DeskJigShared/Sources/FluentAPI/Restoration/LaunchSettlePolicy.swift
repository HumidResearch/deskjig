//  LaunchSettlePolicy.swift
//  DeskJigShared

public struct LaunchSettlePolicy: Sendable {
    public init() {}

    public func needsSettle(
        launchedByThisRestore: Bool,
        isFinishedLaunching: Bool?
    ) -> Bool {
        launchedByThisRestore || isFinishedLaunching == false
    }
}
