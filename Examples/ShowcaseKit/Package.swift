// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "ShowcaseKit",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    .library(name: "ShowcaseKit", targets: ["ShowcaseKit"]),
    .library(name: "ShowcaseStats", targets: ["ShowcaseStats"])
  ],
  dependencies: [
    .package(path: "../MathUtils")
  ],
  targets: [
    // A C module with public headers in include/.
    .target(name: "CChecksum"),
    // An internal Swift module that ShowcaseKit re-exports.
    .target(name: "ShowcaseCore"),
    // The main module: Swift + C dependencies, a resource bundle and an @objc API.
    .target(
      name: "ShowcaseKit",
      dependencies: ["ShowcaseCore", "CChecksum"],
      resources: [.process("Resources")]
    ),
    // A second product that depends on another package.
    .target(name: "ShowcaseStats", dependencies: ["MathUtils"])
  ]
)
