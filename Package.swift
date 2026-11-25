// swift-tools-version:6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.
import Foundation
import PackageDescription

// A version tag resolves to the prebuilt XCFramework from that tag's GitHub release;
// `main` always builds from source. The release workflow fills this in on the tagged
// commit only (Scripts/set-binary-release.sh), so it stays `nil` on every branch.
// Set PV_BUILD_FROM_SOURCE=1 to build a tagged version from source instead.
let binaryRelease: (version: String, checksum: String)? = nil

let buildFromSource = binaryRelease == nil
    || ProcessInfo.processInfo.environment["PV_BUILD_FROM_SOURCE"] != nil

let sourceTargets: [Target] = [
    // Pure-Swift target: the NWListener-based ROMUploadServer + the
    // PVWebServer @objc facade. The vendored 2015 GCDWebServer /
    // GCDWebUploader / GCDWebDAVServer ObjC sources (and their bundle +
    // C header search paths) were removed — the server now has zero
    // third-party deps and rides on Network.framework.
    .target(
        name: "PVWebServer",
        dependencies: [],
        resources: [
            .process("Resources")
        ],
        linkerSettings: [
            .linkedFramework("Network"),
            .linkedFramework("UIKit", .when(platforms: [.iOS, .tvOS, .macCatalyst, .visionOS])),
            .linkedFramework("AppKit", .when(platforms: [.macOS]))
        ]
    ),

    // MARK: SwiftPM tests
    .testTarget(
        name: "PVWebServerTests",
        dependencies: ["PVWebServer"])
]

let binaryTargets: [Target] = binaryRelease.map { release in
    [
        .binaryTarget(
            name: "PVWebServer",
            url: "https://github.com/Provenance-Emu/PVWebServer/releases/download/\(release.version)/PVWebServer.xcframework.zip",
            checksum: release.checksum
        )
    ]
} ?? []

let package = Package(
    name: "PVWebServer",
    defaultLocalization: .init(stringLiteral: "en"),
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .watchOS(.v9),
        .macOS(.v11),
        .macCatalyst(.v17),
        .visionOS(.v1)
    ],
    // The three product names are kept in both modes so consumers never change.
    // A prebuilt framework is already dynamic, so the linkage type only applies to source builds.
    products: [
        .library(
            name: "PVWebServer",
            targets: ["PVWebServer"]
        ),
        .library(
            name: "PVWebServer-Dynamic",
            type: buildFromSource ? .dynamic : nil,
            targets: ["PVWebServer"]
        ),
        .library(
            name: "PVWebServer-Static",
            type: buildFromSource ? .static : nil,
            targets: ["PVWebServer"]
        )
    ],
    dependencies: [],
    targets: buildFromSource ? sourceTargets : binaryTargets,
    swiftLanguageModes: [.v5]
)
