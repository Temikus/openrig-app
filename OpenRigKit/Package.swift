// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenRigKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RigModel", targets: ["RigModel"]),
        .library(name: "RigClient", targets: ["RigClient"]),
    ],
    targets: [
        .target(name: "RigModel"),
        .target(name: "RigClient", dependencies: ["RigModel"]),
        .testTarget(
            name: "RigModelTests",
            dependencies: ["RigModel"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "RigClientTests", dependencies: ["RigClient"]),
    ]
)
