// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NoNotch",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "NoNotch", path: "Sources/NoNotch")
    ]
)
