// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "OpenYoinkModuleCore",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "OpenYoinkModuleCore",
            targets: ["OpenYoinkModuleCore"]
        ),
    ],
    targets: [
        .target(name: "OpenYoinkModuleCore"),
        .testTarget(
            name: "OpenYoinkModuleCoreTests",
            dependencies: ["OpenYoinkModuleCore"]
        ),
    ]
)
