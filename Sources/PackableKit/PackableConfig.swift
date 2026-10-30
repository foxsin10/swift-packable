import Foundation
import Yams

/// `packable.yml`: declares which dependencies a package builds from source and which it
/// links as prebuilt XCFrameworks.
///
/// ```yaml
/// dependencies:
///   ShowcaseKit:
///     mode: binary                      # source (default) | binary
///     source: { path: ../ShowcaseKit }  # or { url: …, from: 1.2.0 }
///     binary: { path: ../ShowcaseKit-binary }  # optional; built on demand when missing
///     linkage: dynamic                  # static (default) | dynamic, for on-demand
/// builds
/// ```
public struct PackableConfig: Decodable, Sendable {
  public enum Mode: String, Decodable, Sendable, CaseIterable {
    case source
    case binary
  }

  /// A package location: a local path, or a URL with exactly one version requirement.
  public struct Location: Decodable, Sendable, Equatable {
    public init(
      path: String? = nil,
      url: String? = nil,
      from: String? = nil,
      exact: String? = nil,
      branch: String? = nil,
      revision: String? = nil,
      upToNextMinor: String? = nil
    ) {
      self.path = path
      self.url = url
      self.from = from
      self.exact = exact
      self.branch = branch
      self.revision = revision
      self.upToNextMinor = upToNextMinor
    }

    public var path: String?
    public var url: String?
    public var from: String?
    public var exact: String?
    public var branch: String?
    public var revision: String?
    public var upToNextMinor: String?

    /// The name `.product(name:package:)` uses for this location: the last path
    /// component, without `.git`.
    public var packageName: String {
      let last = URL(fileURLWithPath: path ?? url ?? "").lastPathComponent
      return last.hasSuffix(".git") ? String(last.dropLast(4)) : last
    }

    enum CodingKeys: String, CodingKey {
      case path
      case url
      case from
      case exact
      case branch
      case revision
      case upToNextMinor = "up-to-next-minor"
    }

    /// The version requirement as a `Package.Dependency` argument list suffix.
    var requirementArguments: String? {
      if let from {
        return "from: \(swiftLiteral(from))"
      }
      if let exact {
        return "exact: \(swiftLiteral(exact))"
      }
      if let branch {
        return "branch: \(swiftLiteral(branch))"
      }
      if let revision {
        return "revision: \(swiftLiteral(revision))"
      }
      if let upToNextMinor {
        return ".upToNextMinor(from: \(swiftLiteral(upToNextMinor)))"
      }
      return nil
    }

    func validate(_ context: String) throws {
      let requirements = [from, exact, branch, revision, upToNextMinor].compactMap(\.self)
      switch (path, url) {
      case (.some, nil):
        guard requirements.isEmpty else {
          throw MakerError("\(context): a path location takes no version requirement.")
        }
      case (nil, .some):
        guard requirements.count == 1 else {
          let keys = "from, exact, branch, revision or up-to-next-minor"
          throw MakerError("\(context): a url location needs exactly one of \(keys).")
        }
      default:
        throw MakerError("\(context): give either `path` or `url`.")
      }
    }
  }

  public struct Dependency: Decodable, Sendable {
    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .source
      source = try container.decode(Location.self, forKey: .source)
      binary = try container.decodeIfPresent(Location.self, forKey: .binary)
      products = try container.decodeIfPresent([String].self, forKey: .products)
      platforms = try container.decodeIfPresent([String].self, forKey: .platforms)
      linkage = try container.decodeIfPresent(Linkage.self, forKey: .linkage) ?? .static
      skipInterfaceVerification = try container.decodeIfPresent(
        Bool.self,
        forKey: .skipInterfaceVerification
      ) ?? false
    }

    public var mode: Mode
    public var source: Location
    /// A prebuilt binary package. When missing, binary mode builds one from `source`.
    public var binary: Location?
    /// Products to package when building on demand. Default: all library products.
    public var products: [String]?
    /// Platform slices to build on demand. Default: the source manifest's platforms.
    public var platforms: [String]?
    /// Framework linkage when building on demand.
    public var linkage: Linkage
    public var skipInterfaceVerification: Bool

    enum CodingKeys: String, CodingKey {
      case mode
      case source
      case binary
      case products
      case platforms
      case linkage
      case skipInterfaceVerification = "skip-interface-verification"
    }
  }

  public var dependencies: [String: Dependency]
  /// Where binaries built on demand are kept. Default: `.build/packable-cache` in the
  /// package.
  public var cache: String?

  /// Dependency names in a stable order.
  public var names: [String] {
    dependencies.keys.sorted()
  }

  public static func load(from url: URL) throws -> PackableConfig {
    let text = try String(contentsOf: url, encoding: .utf8)
    return try parse(text, origin: url.lastPathComponent)
  }

  public static func parse(_ yaml: String, origin: String = "packable.yml") throws
    -> PackableConfig {
    let config: PackableConfig
    do {
      config = try YAMLDecoder().decode(PackableConfig.self, from: yaml)
    } catch {
      throw MakerError("\(origin) is not valid: \(error)")
    }
    for name in config.names {
      let dependency = config.dependencies[name]!
      try dependency.source.validate("\(origin): \(name).source")
      try dependency.binary?.validate("\(origin): \(name).binary")
    }
    return config
  }
}

func swiftLiteral(_ string: String) -> String {
  let escaped = string
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
  return "\"\(escaped)\""
}

/// `target` expressed relative to `base` when they share a root, e.g. `../Other`.
func relativePath(to target: URL, from base: URL) -> String {
  let targetParts = target.standardizedFileURL.pathComponents
  let baseParts = base.standardizedFileURL.pathComponents
  var common = 0
  while common < min(targetParts.count, baseParts.count),
        targetParts[common] == baseParts[common] {
    common += 1
  }
  guard common > 1 else {
    return target.standardizedFileURL.path
  }
  let ups = Array(repeating: "..", count: baseParts.count - common)
  let rest = Array(targetParts[common...])
  let parts = ups + rest
  return parts.isEmpty ? "." : parts.joined(separator: "/")
}
