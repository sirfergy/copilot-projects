// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "copilot-projects",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        // Pinned past the post-1.13 Metal fixes for stale rows/cursor, window
        // reparenting, synchronized output, and hidden-scroller layout.
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm",
            revision: "9adb62463d2264e7403feb7a1471aaf27eaab2f4"
        )
    ],
    targets: [
        .target(
            name: "CopilotProjectsCore",
            path: "Sources/CopilotProjectsCore"
        ),
        .executableTarget(
            name: "copilot-projects",
            dependencies: [
                "CopilotProjectsCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/copilot-projects"
        ),
        .executableTarget(
            name: "copilot-projects-link",
            dependencies: ["CopilotProjectsCore"],
            path: "Sources/copilot-projects-link"
        ),
        .testTarget(
            name: "CopilotProjectsTests",
            dependencies: ["CopilotProjectsCore", "copilot-projects"],
            path: "Tests"
        )
    ]
)
