// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "Demo",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    .library(name: "Demo", targets: ["Demo"]),
    .library(name: "DemoExtras", targets: ["DemoExtras"])
  ],
  targets: [
    .target(name: "CDemo"),
    .target(name: "DemoCore"),
    .target(name: "Demo", dependencies: ["DemoCore", "CDemo"]),
    .target(
      name: "DemoExtras",
      dependencies: ["DemoCore"],
      resources: [.process("Resources")]
    )
  ]
)
