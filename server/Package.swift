// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "daylight-mirror",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CLZ4",
            path: "Sources/CLZ4",
            publicHeadersPath: "include",
            cSettings: [.define("LZ4_STATIC_LINKING_ONLY")]
        ),
        .target(
            name: "CVirtualDisplay",
            path: "Sources/CVirtualDisplay",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MirrorEngine",
            dependencies: ["CLZ4", "CVirtualDisplay"],
            path: "Sources/MirrorEngine"
        ),
        .executableTarget(
            name: "daylight-mirror",
            dependencies: ["MirrorEngine"],
            path: "Sources/Mirror"
        ),
        .executableTarget(
            name: "DaylightMirror",
            dependencies: ["MirrorEngine"],
            path: "Sources/App"
        )
    ]
)
