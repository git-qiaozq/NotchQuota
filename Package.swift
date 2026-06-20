// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchQuota",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "NotchQuota",
            path: "Sources/NotchQuota"
        )
    ]
)
