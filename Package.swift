// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Babylon",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .watchOS(.v10)
    ],
    products: [
        .library(name: "Babylon", targets: ["Babylon"])
    ],
    targets: [
        .target(
            name: "Babylon",
            path: "Babylon",
            resources: [.process("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "BabylonTests",
            dependencies: ["Babylon"],
            path: "BabylonTests",
            resources: [.copy("Fixtures/RockxyProtocol")]
        )
    ]
)
