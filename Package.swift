// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ListenAndRecord",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ListenAndRecord",
            path: "Sources/ListenAndRecord"
        )
    ]
)
