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

  /// A target's entry in `dependencies:`. Platform conditions aren't kept: a dependency
  /// that doesn't apply to a platform isn't built for it.
  public enum Dependency: Decodable, Sendable, Equatable {
    /// A plain string: a target of the same package, or else a product of a dependency.
    case byName(String)
    case target(String)
    case product(name: String, package: String?)

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: Kind.self)
      guard let kind = container.allKeys.first else {
        throw DecodingError.dataCorrupted(.init(
          codingPath: decoder.codingPath,
          debugDescription: "Empty target dependency"
        ))
      }
      var values = try container.nestedUnkeyedContainer(forKey: kind)
      let name = try values.decode(String.self)
      switch kind {
      case .byName: self = .byName(name)
      case .target: self = .target(name)
      case .product: self = try .product(name: name, package: values.decode(String?.self))
      }
    }

    enum Kind: String, CodingKey {
      case byName
      case target
      case product
    }
  }

  /// A `linkerSettings:` entry that names a framework or library to link.
  public struct LinkedLibrary: Sendable, Equatable {
    public enum Kind: Sendable {
      case framework
      case library
    }

    public let kind: Kind
    public let name: String
    /// Manifest platform names (`ios`, `macos`, ...) it's limited to; `nil` means all.
    public let platformNames: [String]?

    /// The linker arguments for this entry on `platform`, if it applies there.
    public func arguments(for platform: ApplePlatform) -> [String] {
      if let platformNames, !platformNames.contains(platform.manifestPlatformName) {
        return []
      }
      return switch kind {
      case .framework: ["-framework", name]
      case .library: ["-l\(name)"]
      }
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

    /// A `.systemLibrary` target: a module map over a library the OS provides, with no
    /// code of its own.
    public var isSystemLibrary: Bool {
      type == "system"
    }

    public var targetDependencies: [Dependency] {
      dependencies ?? []
    }

    /// Frameworks and libraries from `linkerSettings:`.
    public var linkedLibraries: [LinkedLibrary] {
      (settings ?? []).compactMap(\.linkedLibrary)
    }

    let dependencies: [Dependency]?
    let settings: [Setting]?
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

  public func target(named name: String) -> Target? {
    targets.first { $0.name == name }
  }

  /// A `settings` entry of `dump-package`; only linked frameworks and libraries are read.
  struct Setting: Decodable, Sendable {
    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let tool = try container.decode(String.self, forKey: .tool)
      let kind = try container.decode([String: AnyValue].self, forKey: .kind)
      let condition = try container.decodeIfPresent(Condition.self, forKey: .condition)
      guard tool == "linker", let (key, value) = kind.first, let name = value.name else {
        linkedLibrary = nil
        return
      }
      linkedLibrary = switch key {
      case "linkedFramework":
        LinkedLibrary(
          kind: .framework,
          name: name,
          platformNames: condition?.platformNames
        )
      case "linkedLibrary":
        LinkedLibrary(kind: .library, name: name, platformNames: condition?.platformNames)
      default: nil
      }
    }

    enum CodingKeys: String, CodingKey {
      case tool
      case kind
      case condition
    }

    struct Condition: Decodable {
      let platformNames: [String]?
    }

    /// `{"_0": "UIKit"}`, or another shape whose contents aren't needed.
    struct AnyValue: Decodable {
      init(from decoder: Decoder) throws {
        let container = try? decoder.container(keyedBy: CodingKeys.self)
        name = try? container?.decodeIfPresent(String.self, forKey: ._0)
      }

      enum CodingKeys: String, CodingKey {
        case _0
      }

      let name: String?
    }

    let linkedLibrary: LinkedLibrary?
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
