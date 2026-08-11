//
//  TestingConfiguration.swift
//  DeskJigShared
//
//  Testing configuration flags for development and debugging
//

import Foundation

/// Testing configuration flags for DeskJigShared
public struct TestingConfiguration {

    /// When enabled, skips main screen operations for testing purposes
    public static let SKIP_MAIN_SCREEN = false
    public static let SKIP_SECOND_SCREEN = false

    /// When enabled, returns black NSImages instead of actual screenshots
    public static let USE_BLACK_SCREENSHOTS = false

    /// When enabled, uses blur effect instead of generating wallpaper backgrounds
    /// This improves performance by skipping wallpaper loading and cropping
    public static let USE_BLUR_EFFECT = true
}
