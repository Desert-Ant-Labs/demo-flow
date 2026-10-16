// swift-tools-version: 6.0
// WebRTC's echo canceller for Flow: takes the people on a call, as the
// speakers play them, back out of the microphone. The library is built by
// build.sh from WebRTC's audio processing as PulseAudio packages it.
import PackageDescription

let package = Package(
    name: "EchoCancel",
    platforms: [.macOS("26.0")],
    products: [.library(name: "EchoCancel", targets: ["EchoCancel"])],
    targets: [
        .binaryTarget(name: "WebRTCEchoCancel", path: "WebRTCEchoCancel.xcframework"),
        .target(name: "EchoCancel", dependencies: ["WebRTCEchoCancel"]),
        .testTarget(name: "EchoCancelTests", dependencies: ["EchoCancel"]),
    ]
)
