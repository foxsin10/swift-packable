// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "XcframeworkPackable",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "xcframework-packable", targets: ["xcframework-packable"]),
    .library(name: "XcframeworkPackableKit", targets: ["XcframeworkPackableKit"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
  ],
  targets: [
    .target(name: "XcframeworkPackableKit"),
    .executableTarget(
      name: "xcframework-packable",
      dependencies: [
        "XcframeworkPackableKit",
        .product(name: "ArgumentParser", package: "swift-argument-parser")
      ]
    ),
    .testTarget(
      name: "XcframeworkPackableKitTests",
      dependencies: ["XcframeworkPackableKit"],
      resources: [.copy("Fixtures")]
    )
  ]
)
