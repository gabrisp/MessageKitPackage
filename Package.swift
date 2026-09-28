// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MessagesKit",
    defaultLocalization: "es",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "MessagesKit", targets: ["MessagesKit"]),
    ],
    targets: [
        .target(
            name: "MessagesKit",
            resources: [.copy("Resources/Examples")]
        ),
        .testTarget(
            name: "MessagesKitTests",
            dependencies: ["MessagesKit"]
        ),
    ]
)
