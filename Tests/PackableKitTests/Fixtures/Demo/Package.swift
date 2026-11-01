// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "Demo",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    .library(name: "Demo", targets: ["Demo"]),
    .library(name: "DemoExtras", targets: ["DemoExtras"])
  ],
  dependencies: [.package(path: "LocalPackages/Phrases")],
  targets: [
    .target(name: "CDemo"),
    // Like GRDB's GRDBSQLite: a module map over a system library, with no code.
    .systemLibrary(name: "CZlib"),
    .target(name: "DemoCore"),
    // Empty and never imported, so it isn't packaged.
    .target(name: "DemoMarker"),
    .target(name: "Demo", dependencies: ["DemoCore", "CDemo", "CZlib", "DemoMarker"]),
    .target(
      name: "DemoExtras",
      dependencies: ["DemoCore", .product(name: "Phrases", package: "Phrases")],
      resources: [.process("Resources")]
    )
  ]
)
