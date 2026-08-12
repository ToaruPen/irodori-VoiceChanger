// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "irodori-VoiceChanger",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "IrodoriVoiceChangerCore", targets: ["IrodoriVoiceChangerCore"]),
        .library(name: "IrodoriVoiceChangerMacOS", targets: ["IrodoriVoiceChangerMacOS"]),
        .executable(name: "irodori-voicechanger", targets: ["IrodoriVoiceChangerCLI"]),
    ],
    targets: [
        .target(name: "IrodoriVoiceChangerCore"),
        .target(
            name: "IrodoriVoiceChangerMacOS",
            dependencies: ["IrodoriVoiceChangerCore"]
        ),
        .executableTarget(
            name: "IrodoriVoiceChangerCLI",
            dependencies: ["IrodoriVoiceChangerCore", "IrodoriVoiceChangerMacOS"]
        ),
        .testTarget(
            name: "IrodoriVoiceChangerCoreTests",
            dependencies: ["IrodoriVoiceChangerCore", "IrodoriVoiceChangerCLI"]
        ),
        .testTarget(
            name: "IrodoriVoiceChangerMacOSTests",
            dependencies: ["IrodoriVoiceChangerCore", "IrodoriVoiceChangerMacOS"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
