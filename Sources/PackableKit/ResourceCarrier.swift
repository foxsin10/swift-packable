import Foundation

/// A regular target in a generated binary package that carries a module's original
/// resource files. The module's code is in its XCFramework; this target exists so that
/// SwiftPM (or Xcode) processes the resources for the client's platform and installs
/// `<Package>_<Module>.bundle` where the compiled `Bundle.module` accessor looks for it.
///
/// SwiftPM names the bundle `<package name>_<target name>`, so the carrier takes the
/// original target's name and the module's binary target is renamed
/// (`binaryTargetName(for:)`). A module from a dependency keeps its bundle name by having
/// its carrier in a small local package with the dependency's name (`bundlePackage`),
/// which the binary package depends on through a link target. The carrier is a C target
/// with an empty source file and an empty module map, so it adds no second module with
/// that name.
public struct ResourceCarrier: Sendable, Equatable {
  public init(
    module: String,
    resources: [PackageManifest.Resource],
    target: String? = nil,
    bundlePackage: String? = nil
  ) {
    self.module = module
    self.resources = resources
    self.target = target ?? module
    self.bundlePackage = bundlePackage
  }

  /// Folder of the root package's carrier targets, relative to the binary package.
  public static let folder = "Resources"
  /// Folder of the local packages that carry dependencies' resources.
  public static let packagesFolder = "Packages"
  /// Folder of the link targets that pull those packages in.
  public static let linksFolder = "Links"

  public let module: String
  /// The resources, with paths relative to the carrier's folder.
  public let resources: [PackageManifest.Resource]
  /// The carrier target's name: the original target's, which the bundle is named after.
  public let target: String
  /// The package name in the bundle's name, for a module from a dependency; `nil` for the
  /// packaged package's own modules.
  public let bundlePackage: String?

  /// The carrier target's path in its package.
  public var path: String {
    bundlePackage == nil ? "\(Self.folder)/\(module)" : module
  }

  /// The carrier's folder, relative to the binary package.
  public var directory: String {
    bundlePackage.map { "\(Self.packageFolder(for: $0))/\(module)" } ?? path
  }

  /// The local package carrying `package`'s resources, relative to the binary package.
  /// The suffix keeps its identity apart from the real package's.
  public static func packageFolder(for package: String) -> String {
    "\(packagesFolder)/\(package)-resources"
  }

  /// The link target in the binary package, and the product of the local package, that
  /// install `package`'s resource bundles.
  public static func linkTargetName(for package: String) -> String {
    "\(package)Resources"
  }

  /// The link target's path in the binary package.
  public static func linkPath(for package: String) -> String {
    "\(linksFolder)/\(package)"
  }

  /// The binary target's name for a module whose carrier took the module's name.
  public static func binaryTargetName(for module: String) -> String {
    module + "Binary"
  }

  /// Resource types SwiftPM processes even when a target doesn't declare them.
  static let implicitExtensions: Set = [
    "lproj",
    "metal",
    "storyboard",
    "xcassets",
    "xcdatamodel",
    "xcdatamodeld",
    "xcmappingmodel",
    "xcstrings",
    "xib"
  ]

  /// Copies the resources of `target` (sources in `sourceDirectory`) into the carrier
  /// folder of the binary package at `packageDirectory`. Returns `nil` when the target
  /// has no resources that end up in a bundle.
  ///
  /// - Parameters:
  ///   - resolved: SwiftPM's resolved resource list (absolute paths), when known, plus
  ///     what a scan finds that it leaves out (asset catalogs); otherwise they're worked
  ///     out from the manifest and a scan of the target folder.
  ///   - foreignDirectories: Folders the scan skips: excluded paths and nested targets.
  ///   - bundlePackage: The package name in the bundle's name, for a module from a
  ///     dependency.
  static func make(
    module: String,
    target: PackageManifest.Target,
    sourceDirectory: URL,
    packageDirectory: URL,
    resolved: [PackageManifest.Resource]? = nil,
    foreignDirectories: [URL] = [],
    bundlePackage: String? = nil
  ) throws -> ResourceCarrier? {
    let resources: [PackageManifest.Resource]
    if let resolved {
      // SwiftPM's list leaves out asset catalogs, so the scan adds what it missed.
      let listed = relative(resolved, to: sourceDirectory)
      resources = listed + implicitResources(
        in: sourceDirectory,
        declared: listed,
        skipping: foreignDirectories
      )
    } else {
      // Declared paths can step out and back in (`../Sources/x`), so they're normalized
      // against the target folder.
      let declared = relative(
        (target.resources ?? []).map {
          .init(
            path: sourceDirectory.appendingPathComponent($0.path).standardizedFileURL.path,
            rule: $0.rule,
            localization: $0.localization
          )
        },
        to: sourceDirectory
      )
      let implicit = implicitResources(
        in: sourceDirectory,
        declared: declared,
        skipping: foreignDirectories
      )
      resources = declared + implicit
    }
    guard !resources.isEmpty else {
      return nil
    }

    let fileManager = FileManager.default
    let carrier = ResourceCarrier(
      module: module,
      resources: resources,
      target: target.name,
      bundlePackage: bundlePackage
    )
    let directory = packageDirectory.appendingPathComponent(carrier.directory)
    try? fileManager.removeItem(at: directory)
    try fileManager.createDirectory(
      at: directory.appendingPathComponent("include"),
      withIntermediateDirectories: true
    )
    for resource in resources {
      let destination = directory.appendingPathComponent(resource.path)
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try fileManager.copyItem(
        at: sourceDirectory.appendingPathComponent(resource.path),
        to: destination
      )
    }

    try writeEmptyCTarget(
      in: directory,
      note: "\(module)'s code is in its XCFramework; this target carries its resources."
    )
    return carrier
  }

  /// Creates the link target that pulls in `package`'s local resource package.
  static func makeLink(for package: String, packageDirectory: URL) throws {
    let directory = packageDirectory.appendingPathComponent(linkPath(for: package))
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("include"),
      withIntermediateDirectories: true
    )
    try writeEmptyCTarget(
      in: directory,
      note: "Pulls in \(package)'s resource bundles from \(packageFolder(for: package))."
    )
  }

  /// An empty source file, and an empty module map so SwiftPM doesn't generate a clang
  /// module with the target's name, which could clash with a framework's module.
  private static func writeEmptyCTarget(in directory: URL, note: String) throws {
    try "// \(note)\n".write(
      to: directory.appendingPathComponent("resources.c"),
      atomically: true,
      encoding: .utf8
    )
    try "// Intentionally empty. \(note)\n".write(
      to: directory.appendingPathComponent("include/module.modulemap"),
      atomically: true,
      encoding: .utf8
    )
  }

  /// `resources` with paths relative to `directory`; entries outside it, and resources
  /// embedded in code, are dropped.
  private static func relative(
    _ resources: [PackageManifest.Resource],
    to directory: URL
  ) -> [PackageManifest.Resource] {
    let base = canonicalPath(directory) + "/"
    return resources.compactMap { resource in
      let path = canonicalPath(URL(fileURLWithPath: resource.path))
      guard resource.rule != .embedInCode, path.hasPrefix(base) else {
        return nil
      }
      let relativePath = String(path.dropFirst(base.count))
      return .init(
        path: relativePath,
        rule: resource.rule,
        localization: resource.localization
      )
    }
  }

  /// Undeclared files of the types SwiftPM treats as resources anyway. Hidden folders and
  /// `skipped` folders (excluded paths, nested targets) aren't searched.
  private static func implicitResources(
    in directory: URL,
    declared: [PackageManifest.Resource],
    skipping skipped: [URL]
  ) -> [PackageManifest.Resource] {
    guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
      return []
    }
    let skippedPaths = Set(skipped.map(canonicalPath))
    var found: [PackageManifest.Resource] = []
    while let path = enumerator.nextObject() as? String {
      let name = URL(fileURLWithPath: path).lastPathComponent
      let absolute = canonicalPath(directory.appendingPathComponent(path))
      let isDeclared = declared
        .contains { path == $0.path || path.hasPrefix($0.path + "/") }
      if isDeclared || name.hasPrefix(".") || skippedPaths.contains(absolute) {
        enumerator.skipDescendants()
        continue
      }
      if implicitExtensions.contains(URL(fileURLWithPath: path).pathExtension) {
        // A folder holding declared files (an .lproj of listed strings) is covered.
        if !declared.contains(where: { $0.path.hasPrefix(path + "/") }) {
          found.append(PackageManifest.Resource(path: path, rule: .process))
        }
        enumerator.skipDescendants()
      }
    }
    return found.sorted { $0.path < $1.path }
  }
}
