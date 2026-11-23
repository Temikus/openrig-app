// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "OpenRigKit",
    // iOS: the phone remote links RigModel, RigClient, RigDomain and RigCanvasLayout. RigTerminal is Mac only.
    platforms: [.macOS(.v27), .iOS(.v26)],
    products: [
        .library(name: "RigModel", targets: ["RigModel"]),
        .library(name: "RigClient", targets: ["RigClient"]),
        .library(name: "RigCanvasLayout", targets: ["RigCanvasLayout"]),
        .library(name: "RigDomain", targets: ["RigDomain"]),
        .library(name: "RigTerminal", targets: ["RigTerminal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.7.6"),
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
        .testTarget(
            name: "RigClientTests", dependencies: ["RigClient", "RigModel", "RigDomain", "RigTerminal", "RigFixtures"]),
        .testTarget(name: "RigCanvasLayoutTests", dependencies: ["RigCanvasLayout"]),
    ]
)
