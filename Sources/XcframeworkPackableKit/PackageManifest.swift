import Foundation

/// The subset of `swift package dump-package` output this tool needs.
public struct PackageManifest: Decodable, Sendable {
  public struct Platform: Decodable, Sendable, Equatable {
    public let platformName: String
    public let version: String
  }

  public struct Product: Decodable, Sendable {
    public let name: String
    public let targets: [String]

    public var isLibrary: Bool {
      type["library"] != nil
    }

    let type: [String: AnyDecodable]
  }

  public struct Target: Decodable, Sendable {
    public let name: String
    public let type: String
    public let path: String?
    public let publicHeadersPath: String?

    /// Targets that end up as linkable library modules in a build.
    public var isLibrary: Bool {
      type == "regular"
    }
  }

  public let name: String
  public let platforms: [Platform]
  public let products: [Product]
  public let targets: [Target]

  public var libraryProducts: [Product] {
    products.filter(\.isLibrary)
  }

  public func product(named name: String) -> Product? {
    products.first { $0.name == name }
  }
}

/// The node shape of `swift package show-dependencies --format json`.
struct DependencyNode: Decodable {
  let identity: String
  let name: String
  let path: String
  let dependencies: [DependencyNode]

  /// This node and all transitive dependencies, without duplicates, root first.
  func flattened() -> [DependencyNode] {
    var seen = Set<String>()
    var result: [DependencyNode] = []
    func visit(_ node: DependencyNode) {
      guard seen.insert(node.identity).inserted else {
        return
      }
      result.append(node)
      node.dependencies.forEach(visit)
    }
    visit(self)
    return result
  }
}

/// Lets us skip over JSON values whose shape we don't care about.
struct AnyDecodable: Decodable, Sendable {
  init(from _: Decoder) throws {}
}

/// A package checked out on disk together with its manifest.
public struct ResolvedPackage: Sendable {
  public let identity: String
  public let directory: URL
  public let manifest: PackageManifest

  /// Directory of a target's sources, following SwiftPM's default layout rules.
  public func sourceDirectory(of target: PackageManifest.Target) -> URL {
    if let path = target.path {
      return directory.appendingPathComponent(path)
    }
    let candidates = ["Sources", "Source", "src", "srcs"].map {
      directory.appendingPathComponent($0).appendingPathComponent(target.name)
    }
    return candidates
      .first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
  }

  /// The public headers directory of a C-family target.
  public func publicHeadersDirectory(of target: PackageManifest.Target) -> URL {
    sourceDirectory(of: target)
      .appendingPathComponent(target.publicHeadersPath ?? "include")
  }
}

/// Converts a target name to the module name SwiftPM derives from it (its "c99name").
public func moduleName(forTarget name: String) -> String {
  var result = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
  if let first = result.first, first.isNumber {
    result = "_" + result
  }
  return result
}
