// swift-tools-version:5.9
import PackageDescription

// The pure decision-making core of OnlyX Login for iOS, split out from the app the way the mac
// app splits its logic out of Electron: nothing in OnlyXLoginCore imports WebKit, UIKit or
// SwiftUI, so it compiles and its tests run on Linux (and in CI) with no simulator. The iOS app
// target (Sources/OnlyXLoginApp) is the thin WebKit/SwiftUI glue and is built only by Xcode.
let package = Package(
    name: "OnlyXLogin",
    // macOS 12 is where URLSession's async API begins; without it a `swift test` on a Mac (CI's
    // second run of the core) compiles for 10.13 and fails on `data(for:)`. Linux is unaffected.
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "OnlyXLoginCore", targets: ["OnlyXLoginCore"]),
    ],
    targets: [
        .target(name: "OnlyXLoginCore"),
        .testTarget(name: "OnlyXLoginCoreTests", dependencies: ["OnlyXLoginCore"]),
    ]
)
