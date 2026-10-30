// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "swift-packable",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "swift-packable", targets: ["swift-packable"]),
    .library(name: "PackableKit", targets: ["PackableKit"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", exact: "1.5.0"),
    .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.0")
  ],
  targets: [
    .target(name: "PackableKit", dependencies: ["Yams"]),
    .executableTarget(
      name: "swift-packable",
      dependencies: [
        "PackableKit",
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ]
    ),
    .testTarget(
      name: "PackableKitTests",
      dependencies: ["PackableKit"],
      resources: [.copy("Fixtures")]
    )
  ]
)
