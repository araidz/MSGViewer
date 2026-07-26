// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MSGViewer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "MSGViewer"),
        .testTarget(name: "MSGViewerTests", dependencies: ["MSGViewer"])
    ]
)
