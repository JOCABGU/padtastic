// swift-tools-version:5.9
// UltraAudioCore: platform-independent part of the iPhone receiver (wire protocol + jitter buffer).
// `swift test` runs its tests on macOS (and on any platform with a Swift toolchain).
import PackageDescription

let package = Package(
    name: "UltraAudioCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "UltraAudioCore", targets: ["UltraAudioCore", "CUltraAtomics"]),
    ],
    targets: [
        .target(name: "CUltraAtomics"),
        .target(name: "UltraAudioCore", dependencies: ["CUltraAtomics"]),
        .testTarget(name: "UltraAudioCoreTests", dependencies: ["UltraAudioCore"]),
        .executableTarget(name: "UltraAudioCoreChecks", dependencies: ["UltraAudioCore"]),
    ]
)
