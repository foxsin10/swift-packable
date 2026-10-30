// swift-tools-version:5.9
import PackageDescription

/// Depends on the *binary* package that run-showcase.sh generates from ShowcaseKit.
/// The import statements in main.swift are the same as with the source package.
let package = Package(
  name: "ShowcaseApp",
  platforms: [.macOS(.v12), .iOS(.v15)],
  dependencies: [
    .package(path: "../build/ShowcaseKit-binary")
  ],
  targets: [
    .executableTarget(
      name: "ShowcaseApp",
      dependencies: [
        .product(name: "ShowcaseKit", package: "ShowcaseKit-binary"),
        .product(name: "ShowcaseStats", package: "ShowcaseKit-binary")
      ]
    )
  ]
)
