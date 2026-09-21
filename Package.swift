// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "copilot-projects",
    platforms: [
        .macOS("26.0"),
        .iOS("17.0"),
    ],
    products: [
        .library(name: "CopilotProjectsHost", targets: ["CopilotProjectsHost"]),
        .library(name: "CopilotProjectsCore", targets: ["CopilotProjectsCore"]),
        .executable(name: "copilot-projects", targets: ["copilot-projects"]),
        .executable(name: "copilot-projects-link", targets: ["copilot-projects-link"]),
        .executable(name: "workspace-capture-host", targets: ["WorkspaceCaptureHost"]),
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
        // SwiftTerm 2.0 with embedding APIs, caret ordering, renderer diagnostics,
        // and close-on-exec protection for the private PTY write descriptor.
        .package(
            url: "https://github.com/sirfergy/SwiftTerm",
            revision: "cc0f5a65b40874ede770ba9e44ae61ce48a7de96"
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
            name: "CopilotProjectsHost",
            dependencies: [
                "CopilotProjectsUI",
                "CopilotProjectsCore",
                "CopilotProjectsProtocol",
                "SessionDomain",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/CopilotProjectsHost"
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
        .testTarget(
            name: "CopilotProjectsTests",
            dependencies: [
                "CopilotProjectsCore",
                "CopilotProjectsProtocol",
                "CopilotProjectsProtocolFixtures",
                "CopilotProjectsHost",
                "WorkspaceCaptureSupport",
            ],
            path: "Tests",
            exclude: ["WorkspaceCaptureSupport", "WorkspaceCaptureHost"]
        ),
        .target(
            name: "WorkspaceCaptureSupport",
            dependencies: [
                "CopilotProjectsHost", "CopilotProjectsCore", "CopilotProjectsProtocol",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Tests/WorkspaceCaptureSupport"
        ),
        .executableTarget(
            name: "WorkspaceCaptureHost",
            dependencies: ["WorkspaceCaptureSupport"],
            path: "Tests/WorkspaceCaptureHost"
        )
    ]
)
