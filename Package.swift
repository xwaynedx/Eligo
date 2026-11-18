// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Eligo",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Eligo", targets: ["Eligo"])
    ],
    targets: [
        .executableTarget(
            name: "Eligo",
            path: "Sources/Eligo"
        ),
        .testTarget(
            name: "EligoTests",
            dependencies: ["Eligo"],
            path: "Tests/EligoTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
