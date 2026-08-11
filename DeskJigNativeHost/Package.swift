// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// NOTE: the package, target and source directory are DeskJigNativeHost, but the
// executable PRODUCT name stays `BentoNativeHost`. The Chrome extension's native
// messaging manifest (`native_host_config/com.bento.native.json`) hardcodes the
// binary path `.../Contents/MacOS/BentoNativeHost`, so renaming the product would
// break the installed bridge. Keep this name frozen until the manifest ships a
// matching update.
let package = Package(
    name: "DeskJigNativeHost",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "BentoNativeHost",
            targets: ["DeskJigNativeHost"]
        )
    ],
    targets: [
        .executableTarget(
            name: "DeskJigNativeHost"
        )
    ]
)
