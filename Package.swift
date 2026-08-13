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
    dependencies: [
        .package(
            url: "https://github.com/microsoft/onnxruntime-swift-package-manager",
            exact: "1.24.2"
        )
    ],
    targets: [
        .target(name: "IrodoriVoiceChangerCore"),
        .target(
            name: "IrodoriVoiceChangerMacOS",
            dependencies: ["IrodoriVoiceChangerCore"]
        ),
        .target(
            name: "IrodoriVoiceChangerSmartTurn",
            dependencies: [
                "IrodoriVoiceChangerCore",
                .product(
                    name: "onnxruntime",
                    package: "onnxruntime-swift-package-manager"
                ),
            ],
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "IrodoriVoiceChangerCLI",
            dependencies: [
                "IrodoriVoiceChangerCore",
                "IrodoriVoiceChangerMacOS",
                "IrodoriVoiceChangerSmartTurn",
            ]
        ),
        .testTarget(
            name: "IrodoriVoiceChangerCoreTests",
            dependencies: ["IrodoriVoiceChangerCore", "IrodoriVoiceChangerCLI"]
        ),
        .testTarget(
            name: "IrodoriVoiceChangerMacOSTests",
            dependencies: ["IrodoriVoiceChangerCore", "IrodoriVoiceChangerMacOS"]
        ),
        .testTarget(
            name: "IrodoriVoiceChangerSmartTurnTests",
            dependencies: ["IrodoriVoiceChangerSmartTurn"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
