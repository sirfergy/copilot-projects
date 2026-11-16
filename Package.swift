// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "copilot-projects",
    platforms: [
        .macOS("26.0"),
        .iOS("17.0"),
        .watchOS("10.0"),
    ],
    products: [
        .library(name: "CopilotProjectsHost", targets: ["CopilotProjectsHost"]),
        .library(name: "CopilotProjectsCore", targets: ["CopilotProjectsCore"]),
        .executable(name: "copilot-projects", targets: ["copilot-projects"]),
        .executable(name: "copilot-projects-link", targets: ["copilot-projects-link"]),
        .executable(name: "copilot-pull-requests", targets: ["copilot-pull-requests"]),
        .executable(name: "copilot-notifications", targets: ["copilot-notifications"]),
        .library(name: "CopilotProjectsUI", targets: ["CopilotProjectsUI"]),
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
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm",
            revision: "1a5fa2b5a3a6d1ebd3ce94a000a8f690ef77f251"
        ),
    ],
    targets: [
        .target(
            name: "CopilotProjectsUI",
            dependencies: ["CopilotProjectsProtocol"],
            path: "Sources/CopilotProjectsUI"
        ),
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
        .target(
            name: "CopilotProjectsStyle",
            path: "Sources/CopilotProjectsStyle"
        ),
        .target(
            name: "CopilotProjectsHost",
            dependencies: [
                "CopilotProjectsUI",
                "CopilotProjectsCore",
                "CopilotProjectsProtocol",
                "CopilotProjectsStyle",
                "CopilotProjectsPullRequests",
                "SessionDomain",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/CopilotProjectsHost"
        ),
        // Shared PR and notifications engines and the helper apps' UI. The host
        // uses only the read-only PR provider.
        .target(
            name: "CopilotProjectsPullRequests",
            dependencies: [
                "CopilotProjectsCore",
                "CopilotProjectsProtocol",
                "CopilotProjectsStyle",
                "SessionDomain",
            ],
            path: "Sources/CopilotProjectsPullRequests"
        ),
        .executableTarget(
            name: "copilot-projects",
            dependencies: ["CopilotProjectsHost"],
            path: "Sources/copilot-projects"
        ),
        .executableTarget(
            name: "copilot-projects-link",
            dependencies: ["CopilotProjectsCore"],
            path: "Sources/copilot-projects-link"
        ),
        .executableTarget(
            name: "copilot-pull-requests",
            dependencies: ["CopilotProjectsPullRequests"],
            path: "Sources/copilot-pull-requests"
        ),
        .executableTarget(
            name: "copilot-notifications",
            dependencies: ["CopilotProjectsPullRequests"],
            path: "Sources/copilot-notifications"
        ),
        .testTarget(
            name: "CopilotProjectsTests",
            dependencies: [
                "CopilotProjectsCore",
                "CopilotProjectsProtocol",
                "CopilotProjectsProtocolFixtures",
                "CopilotProjectsHost",
                "CopilotProjectsUI",
                "CopilotProjectsPullRequests",
                "CopilotProjectsStyle",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Tests"
        ),
    ]
)
