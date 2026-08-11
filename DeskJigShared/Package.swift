// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DeskJigShared",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "DeskJigShared",
            targets: ["DeskJigShared"]
        ),
    ],
    dependencies: [
        // DeskJig is fully local: no Firebase, no GoogleSignIn, no Sentry.
        .package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack.git", from: "3.8.5")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "DeskJigShared",
            dependencies: [
                .product(name: "CocoaLumberjackSwift", package: "CocoaLumberjack")
            ],
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-strict-concurrency=targeted"])]
        ),
    ]
)
