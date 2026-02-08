// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "daylight-mirror",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CLZ4",
            path: "Sources/CLZ4",
            publicHeadersPath: "include",
            cSettings: [.define("LZ4_STATIC_LINKING_ONLY")]
        ),
        .executableTarget(
            name: "daylight-mirror",
            dependencies: ["CLZ4"],
            path: "Sources/Mirror"
        )
    ]
)
