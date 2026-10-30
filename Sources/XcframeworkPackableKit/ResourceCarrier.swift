import Foundation

/// A regular target in a generated binary package that carries a module's original
/// resource files. The module's code is in its XCFramework; this target exists so that
/// SwiftPM (or Xcode) processes the resources for the client's platform and installs
/// `<Package>_<Module>.bundle` where the compiled `Bundle.module` accessor looks for it.
///
/// SwiftPM names the bundle after the target, so the carrier takes the module's name and
/// the module's binary target is renamed (`binaryTargetName(for:)`). The carrier is a C
/// target with an empty source file and an empty module map, so it adds no second module
/// with that name.
public struct ResourceCarrier: Sendable, Equatable {
  public init(module: String, resources: [PackageManifest.Resource]) {
    self.module = module
    self.resources = resources
  }

  /// Folder of the carrier targets, relative to the binary package.
  public static let folder = "Resources"

  public let module: String
  /// The resources, with paths relative to the carrier's folder.
  public let resources: [PackageManifest.Resource]

  public var path: String {
    "\(Self.folder)/\(module)"
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
  ///   - resolved: SwiftPM's resolved resource list (absolute paths), when known;
  ///     otherwise they're worked out from the manifest and a scan of the target folder.
  ///   - foreignDirectories: Folders the scan skips: excluded paths and nested targets.
  static func make(
    module: String,
    target: PackageManifest.Target,
    sourceDirectory: URL,
    packageDirectory: URL,
    resolved: [PackageManifest.Resource]? = nil,
    foreignDirectories: [URL] = []
  ) throws -> ResourceCarrier? {
    let resources: [PackageManifest.Resource]
    if let resolved {
      resources = relative(resolved, to: sourceDirectory)
    } else {
      let declared = (target.resources ?? []).filter { $0.rule != .embedInCode }
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
    let carrier = ResourceCarrier(module: module, resources: resources)
    let directory = packageDirectory.appendingPathComponent(carrier.path)
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

    let note = "\(module)'s code is in its XCFramework; this target carries its resources."
    try "// \(note)\n".write(
      to: directory.appendingPathComponent("resources.c"),
      atomically: true,
      encoding: .utf8
    )
    // A custom (empty) module map stops SwiftPM from generating a clang module with the
    // module's name, which would clash with the framework's module.
    try "// Intentionally empty. \(note)\n".write(
      to: directory.appendingPathComponent("include/module.modulemap"),
      atomically: true,
      encoding: .utf8
    )
    return carrier
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
        found.append(PackageManifest.Resource(path: path, rule: .process))
        enumerator.skipDescendants()
      }
    }
    return found.sorted { $0.path < $1.path }
  }
}
