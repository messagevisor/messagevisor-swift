// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "messagevisor-swift",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "Messagevisor", targets: ["Messagevisor"]),
        .library(name: "MessagevisorInterpolation", targets: ["MessagevisorInterpolation"]),
        .library(name: "MessagevisorICU", targets: ["MessagevisorICU"]),
        .library(name: "MessagevisorMissingTranslations", targets: ["MessagevisorMissingTranslations"]),
        .executable(name: "messagevisor-swift", targets: ["MessagevisorCLI"]),
    ],
    targets: [
        .target(name: "Messagevisor"),
        .target(name: "MessagevisorInterpolation", dependencies: ["Messagevisor"]),
        .target(name: "MessagevisorICU", dependencies: ["Messagevisor"]),
        .target(name: "MessagevisorMissingTranslations", dependencies: ["Messagevisor"]),
        .executableTarget(
            name: "MessagevisorCLI",
            dependencies: ["Messagevisor", "MessagevisorInterpolation", "MessagevisorICU"]
        ),
        .testTarget(
            name: "MessagevisorTests",
            dependencies: ["Messagevisor"],
            resources: [.copy("Resources/conformance/sdk-v1.json")]
        ),
        .testTarget(name: "MessagevisorInterpolationTests", dependencies: ["Messagevisor", "MessagevisorInterpolation"]),
        .testTarget(name: "MessagevisorICUTests", dependencies: ["Messagevisor", "MessagevisorICU"]),
        .testTarget(name: "MessagevisorMissingTranslationsTests", dependencies: ["Messagevisor", "MessagevisorMissingTranslations"]),
        .testTarget(name: "MessagevisorCLITests", dependencies: ["MessagevisorCLI"]),
    ]
)
