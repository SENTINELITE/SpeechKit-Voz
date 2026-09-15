// swift-tools-version: 6.2

import Foundation
import PackageDescription

// SpeechKitVoz attaches its transcriber to a SpeechKit `SpeechService` through the
// `SpeechServiceExtensionKey` seam, which shipped in SpeechKit 2.0.0. Set
// `SPEECHKIT_VOZ_USE_LOCAL_SPEECHKIT` to build against a sibling checkout while
// both packages change together.
let speechKitDependency: Package.Dependency = ProcessInfo.processInfo.environment["SPEECHKIT_VOZ_USE_LOCAL_SPEECHKIT"] != nil
    ? .package(path: "../SpeechKit")
    : .package(url: "https://github.com/SENTINELITE/SpeechKit.git", from: "2.0.0")

// `xcodebuild` applies a command-line `OTHER_SWIFT_FLAGS` to every target in the
// graph, and Xcode builds package dependencies with `-suppress-warnings`; the two
// flags conflict, so the platform builds cannot ask for warnings-as-errors that
// way. Scope it to this package's own target instead, opted into by CI so a
// consumer's build never fails on a warning a future toolchain adds.
let strictWarnings: [SwiftSetting] = ProcessInfo.processInfo.environment["SPEECHKIT_VOZ_STRICT_WARNINGS"] != nil
    ? [.treatAllWarnings(as: .error)]
    : []

let package = Package(
    name: "SpeechKitVoz",
    platforms: [
        // watchOS stays declared so a multi-platform app can depend on this package
        // from every target. All VOZ code is compiled out with `#if !os(watchOS)`.
        .iOS(.v18),
        .macOS(.v15),
        .watchOS(.v11),
        .visionOS(.v2)
    ],
    products: [
        .library(
            name: "SpeechKitVoz",
            targets: ["SpeechKitVoz"]
        ),
    ],
    dependencies: [
        speechKitDependency,
        .package(
            url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git",
            exact: "3.1.0"
        ),
    ],
    targets: [
        .target(
            name: "SpeechKitVoz",
            dependencies: [
                .product(name: "SpeechKit", package: "SpeechKit"),
                .product(
                    name: "ModelStore",
                    package: "desert-ant-core",
                    condition: .when(platforms: [.iOS, .macOS, .visionOS])
                ),
                .product(
                    name: "Voz",
                    package: "desert-ant-core",
                    condition: .when(platforms: [.iOS, .macOS, .visionOS])
                ),
            ],
            swiftSettings: strictWarnings
        ),
        .testTarget(
            name: "SpeechKitVozTests",
            dependencies: ["SpeechKitVoz"],
            swiftSettings: strictWarnings
        ),
    ]
)
