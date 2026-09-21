// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenSubtitlesUploader",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "OpenSubtitlesUploader",
            path: "Sources/OpenSubtitlesUploader",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OpenSubtitlesUploaderTests",
            dependencies: ["OpenSubtitlesUploader"],
            path: "Tests/OpenSubtitlesUploaderTests"
        )
    ]
)
