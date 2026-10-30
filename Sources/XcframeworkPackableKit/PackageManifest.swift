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

  /// A `resources:` entry, e.g. `.process("Resources")`.
  public struct Resource: Decodable, Sendable, Equatable {
    public init(path: String, rule: Rule, localization: String? = nil) {
      self.path = path
      self.rule = rule
      self.localization = localization
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      path = try container.decode(String.self, forKey: .path)
      let rules = try container.decode([String: RuleOptions].self, forKey: .rule)
      guard let (name, options) = rules.first, let rule = Rule(rawValue: name) else {
        throw DecodingError.dataCorruptedError(
          forKey: .rule,
          in: container,
          debugDescription: "Unknown resource rule \(rules.keys.sorted())"
        )
      }
      self.rule = rule
      localization = options.localization
    }

    public enum Rule: String, Sendable {
      case process
      case copy
      case embedInCode
    }

    public let path: String
    public let rule: Rule
    /// `default` or `base` for `.process(_:localization:)`.
    public let localization: String?

    enum CodingKeys: String, CodingKey {
      case path
      case rule
    }

    struct RuleOptions: Decodable {
      let localization: String?
    }
  }

  public struct Target: Decodable, Sendable {
    public let name: String
    public let type: String
    public let path: String?
    public let publicHeadersPath: String?
    public let resources: [Resource]?
    /// Paths relative to the target folder that SwiftPM ignores.
    public let exclude: [String]?
    /// When set, the only source paths of the target.
    public let sources: [String]?

    /// Targets that end up as linkable library modules in a build.
    public var isLibrary: Bool {
      type == "regular"
    }
  }

  public let name: String
  public let defaultLocalization: String?
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

  /// Folders inside `target`'s folder that aren't part of it: its `exclude:` paths and
  /// the folders of other targets nested inside it (as with `path: "."`).
  public func foreignDirectories(within target: PackageManifest.Target) -> [URL] {
    let own = sourceDirectory(of: target)
    let ownPath = canonicalPath(own) + "/"
    let excluded = (target.exclude ?? []).map { own.appendingPathComponent($0) }
    let nested = manifest.targets
      .filter { $0.name != target.name }
      .map(sourceDirectory(of:))
      .filter { canonicalPath($0).hasPrefix(ownPath) }
    return excluded + nested
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
