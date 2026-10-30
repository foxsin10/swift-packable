// swift-tools-version:5.9
import PackageDescription

/// Stands in for a third-party dependency: ShowcaseKit depends on it by path, and
/// swift-packable packages its module alongside ShowcaseKit's own modules.
let package = Package(
  name: "MathUtils",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [.library(name: "MathUtils", targets: ["MathUtils"])],
  targets: [.target(name: "MathUtils")]
)
