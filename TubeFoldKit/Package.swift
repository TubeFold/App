// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TubeFoldKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TubeFoldKit", targets: ["TubeFoldKit"]),
        .executable(name: "tubefold", targets: ["tubefold-cli"]),
        .executable(name: "tubefold-harness", targets: ["tubefold-harness"]),
    ],
    targets: [
        .target(
            name: "TubeFoldKit",
            resources: [.copy("Resources/prompts")]
        ),
        .executableTarget(name: "tubefold-cli", dependencies: ["TubeFoldKit"]),
        .executableTarget(name: "tubefold-harness", dependencies: ["TubeFoldKit"]),
        .testTarget(name: "TubeFoldKitTests", dependencies: ["TubeFoldKit"]),
    ]
)
