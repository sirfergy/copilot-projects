// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "copilot-projects",
    platforms: [
        .macOS("26.0"),
        .iOS("17.0"),
    ],
    products: [
        .library(
            name: "CopilotProjectsProtocol",
            targets: ["CopilotProjectsProtocol"]
        ),
        .library(
            name: "CopilotProjectsProtocolFixtures",
            targets: ["CopilotProjectsProtocolFixtures"]
        ),
    ],
    dependencies: [
        // Based on upstream v1.20.0. The fork retains Copilot Projects' empty-ink
        // cache, blank-surface recovery, and renderer-recreation fixes.
        .package(
            url: "https://github.com/sirfergy/SwiftTerm",
            revision: "cd053dc4709ddea6e5ad80d8d9df20cd81a9da2c"
        ),
        .package(
            url: "https://github.com/apple/swift-nio",
            revision: "cd3e1152083706d77b223fb29110e590efcc70c0"
        ),
        .package(
            url: "https://github.com/mochidev/swift-webpush.git",
            exact: "0.4.1"
        ),
    ],
    targets: [
        .target(
            name: "SessionDomain",
            path: "Packages/SessionDomain/Sources/SessionDomain"
        ),
        .target(
            name: "CopilotProjectsProtocol",
            path: "Sources/CopilotProjectsProtocol"
        ),
        .target(
            name: "CopilotProjectsProtocolFixtures",
            path: "ContractFixtures",
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "CopilotProjectsCore",
            dependencies: [
                "CopilotProjectsProtocol",
                "SessionDomain",
            ],
            path: "Sources/CopilotProjectsCore",
            resources: [.copy("Resources/tracker")]
        ),
        .executableTarget(
            name: "copilot-projects",
            dependencies: [
                "CopilotProjectsCore",
                "CopilotProjectsProtocol",
                "SessionDomain",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "WebPush", package: "swift-webpush")
            ],
            path: "Sources/copilot-projects",
            resources: [.copy("Resources/web")]
        ),
        .executableTarget(
            name: "copilot-projects-link",
            dependencies: ["CopilotProjectsCore"],
            path: "Sources/copilot-projects-link"
        ),
        .testTarget(
            name: "CopilotProjectsTests",
            dependencies: [
                "CopilotProjectsCore",
                "CopilotProjectsProtocol",
                "CopilotProjectsProtocolFixtures",
                "copilot-projects",
                .product(name: "WebPush", package: "swift-webpush"),
            ],
            path: "Tests"
        )
    ]
)
