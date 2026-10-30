// swift-tools-version:5.9
import PackageDescription

/// Targets outside the conventional Sources/<Target> layout.
let package = Package(
  name: "CustomLayout",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    .library(name: "RootKit", targets: ["RootKit"])
  ],
  targets: [
    // A custom path, with declared resources.
    .target(name: "Core", path: "Lib/Core", resources: [.process("Resources")]),
    // Public headers next to the C sources.
    .target(name: "CLegacy", path: "Legacy/C", publicHeadersPath: "."),
    // SwiftPM's `src/` default folder.
    .target(name: "Extra"),
    // The package root itself, narrowed with `sources:` and `exclude:`.
    .target(
      name: "RootKit",
      dependencies: ["Core", "CLegacy", "Extra"],
      path: ".",
      exclude: ["Lib", "Legacy", "src", "Ignored"],
      sources: ["RootKit.swift"],
      resources: [.copy("root.txt")]
    )
  ]
)
