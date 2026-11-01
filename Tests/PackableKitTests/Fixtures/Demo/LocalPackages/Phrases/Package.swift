// swift-tools-version:5.9
import PackageDescription

// A dependency with resources: its bundle is named Phrases_Phrases, after this package.
let package = Package(
  name: "Phrases",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [.library(name: "Phrases", targets: ["Phrases"])],
  targets: [.target(name: "Phrases", resources: [.process("Resources")])]
)
