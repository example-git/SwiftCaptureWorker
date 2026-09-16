// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftCapture",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
    ],
    targets: [
        .binaryTarget(
            name: "libsrt",
            url: "https://github.com/HaishinKit/libsrt-xcframework/releases/download/v1.5.4/libsrt.xcframework.zip",
            checksum: "76879e2802e45ce043f52871a0a6764d57f833bdb729f2ba6663f4e31d658c4a"
        ),
        .executableTarget(
            name: "SwiftCaptureWorker",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "libsrt"
            ],
            path: "Sources/SwiftCaptureWorker",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox")
            ]
        ),
        .testTarget(
            name: "SwiftCaptureTests",
            path: "Tests/SwiftCaptureTests"
        )
    ]
)
