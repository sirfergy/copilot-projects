// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SessionDomain",
    products: [
        .library(name: "SessionDomain", targets: ["SessionDomain"]),
    ],
    targets: [
        .target(name: "SessionDomain"),
        .testTarget(
            name: "SessionDomainTests",
            dependencies: ["SessionDomain"]
        ),
    ]
)
