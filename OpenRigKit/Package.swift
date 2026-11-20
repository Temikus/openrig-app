// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "OpenRigKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "RigModel", targets: ["RigModel"]),
        .library(name: "RigClient", targets: ["RigClient"]),
        .library(name: "RigCanvasLayout", targets: ["RigCanvasLayout"]),
        .library(name: "RigDomain", targets: ["RigDomain"]),
        .library(name: "RigTerminal", targets: ["RigTerminal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.7.5"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.2"),
    ],
    targets: [
        .target(name: "RigModel"),
        .target(name: "RigClient", dependencies: ["RigModel"]),
        .target(name: "RigDomain", dependencies: ["RigModel", "RigCanvasLayout"]),
        .target(name: "RigTerminal", dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "RigTerminalTests", dependencies: ["RigTerminal"], resources: [.copy("Fixtures")]),
        .target(name: "RigFixtures", path: "Tests/RigFixtures", resources: [.copy("Fixtures")]),
        .testTarget(name: "RigModelTests", dependencies: ["RigModel", "RigFixtures"]),
        .testTarget(name: "RigDomainTests", dependencies: ["RigDomain", "RigFixtures", "RigClient"]),
        .target(
            name: "RigCanvasLayout",
            dependencies: [.product(name: "HeapModule", package: "swift-collections")]
        ),
        .testTarget(name: "RigClientTests", dependencies: ["RigClient", "RigModel", "RigDomain", "RigTerminal"]),
        .testTarget(name: "RigCanvasLayoutTests", dependencies: ["RigCanvasLayout"]),
    ]
)
