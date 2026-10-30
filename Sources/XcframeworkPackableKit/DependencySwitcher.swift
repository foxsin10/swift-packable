import Foundation

/// Reads `packable.yml`, resolves every dependency for its mode (building binaries on
/// demand), and writes the generated block into the package's `Package.swift`.
public struct DependencySwitcher: Sendable {
  public init(
    options: Options,
    log: @escaping @Sendable (String) -> Void = standardErrorLog
  ) {
    self.options = options
    self.log = log
  }

  public struct Options: Sendable {
    public init(packageDirectory: URL, configURL: URL? = nil) {
      self.packageDirectory = packageDirectory
      self.configURL = configURL ?? packageDirectory
        .appendingPathComponent("packable.yml")
    }

    public var packageDirectory: URL
    public var configURL: URL
    /// Rebuild binaries built on demand even when the cached ones are current, and update
    /// remote sources to the newest version their requirement allows.
    public var rebuild = false
    public var verbose = false
  }

  public struct Result: Sendable {
    public var dependencies: [SwitchedDependency] = []
    public var warnings: [String] = []
    public var manifestChanged = false
  }

  public let options: Options

  public func generate() throws -> Result {
    let config = try PackableConfig.load(from: options.configURL)
    let cache = cacheLocation(for: config)
    var result = Result()
    var modulesByDependency: [String: [String]] = [:]

    for name in config.names {
      let dependency = config.dependencies[name]!
      switch dependency.mode {
      case .source:
        result.dependencies.append(SwitchedDependency(
          name: name,
          mode: .source,
          packageExpression: expression(for: dependency.source),
          packageName: dependency.source.packageName
        ))
        modulesByDependency[name] = sourceModules(
          of: dependency.source,
          name: name,
          cache: cache
        )

      case .binary:
        if let binary = dependency.binary {
          result.dependencies.append(SwitchedDependency(
            name: name,
            mode: .binary,
            packageExpression: expression(for: binary),
            packageName: binary.packageName
          ))
          if let path = binary.path {
            let metadata = BinaryMetadata.read(from: absoluteURL(path))
            modulesByDependency[name] = metadata?.modules
            result.warnings += driftWarnings(
              name: name,
              source: dependency.source,
              binary: metadata
            )
          }
        } else {
          let built = try buildOnDemand(name: name, dependency: dependency, cache: cache)
          let path = cache.isShared
            ? nil
            : relativePath(to: built, from: options.packageDirectory)
          let expression = path.map { ".package(path: \(swiftLiteral($0)))" }
            ?? ".package(path: packableCache + \(swiftLiteral("/" + relativePath(to: built, from: cache.url))))"
          result.dependencies.append(SwitchedDependency(
            name: name,
            mode: .binary,
            packageExpression: expression,
            packageName: built.lastPathComponent
          ))
          modulesByDependency[name] = BinaryMetadata.read(from: built)?.modules
        }
      }
    }

    let binaries = Set(result.dependencies.filter { $0.mode == .binary }.map(\.name))
    try checkDuplicateModules(modulesByDependency, binaries: binaries)

    let usesSharedCache = cache.isShared && result.dependencies
      .contains { $0.packageExpression.contains("packableCache") }
    let block = ManifestBlock.render(
      result.dependencies,
      usesSharedCache: usesSharedCache
    )
    let manifestURL = options.packageDirectory.appendingPathComponent("Package.swift")
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    let updated = try ManifestBlock.splice(block, into: manifest)
    if updated != manifest {
      try updated.write(to: manifestURL, atomically: true, encoding: .utf8)
      result.manifestChanged = true
    }
    return result
  }

  /// Sets the mode of `names` (all dependencies when empty) in `packable.yml`.
  /// Returns the names whose mode changed.
  @discardableResult
  public func setMode(
    _ mode: PackableConfig.Mode,
    for names: [String]
  ) throws -> [String] {
    let text = try String(contentsOf: options.configURL, encoding: .utf8)
    let config = try PackableConfig.parse(
      text,
      origin: options.configURL.lastPathComponent
    )
    let targets = names.isEmpty ? config.names : names
    for name in targets where config.dependencies[name] == nil {
      let known = config.names.joined(separator: ", ")
      throw MakerError("'\(name)' isn't declared in packable.yml. Declared: \(known)")
    }

    let changed = targets.filter { config.dependencies[$0]?.mode != mode }
    var edited = text
    for name in changed {
      edited = try ConfigEditor.setMode(mode, for: name, in: edited)
    }
    let check = try PackableConfig.parse(
      edited,
      origin: options.configURL.lastPathComponent
    )
    guard targets.allSatisfy({ check.dependencies[$0]?.mode == mode }) else {
      throw MakerError(
        "Couldn't update packable.yml; set `mode: \(mode.rawValue)` by hand."
      )
    }
    if edited != text {
      try edited.write(to: options.configURL, atomically: true, encoding: .utf8)
    }
    return changed
  }

  /// Switches `names` (all when empty) to `mode` and regenerates. If generating fails,
  /// packable.yml is restored so it keeps matching Package.swift.
  public func use(
    _ mode: PackableConfig.Mode,
    for names: [String]
  ) throws -> (changed: [String], result: Result) {
    let original = try String(contentsOf: options.configURL, encoding: .utf8)
    let changed = try setMode(mode, for: names)
    do {
      return try (changed, generate())
    } catch {
      try original.write(to: options.configURL, atomically: true, encoding: .utf8)
      throw error
    }
  }

  /// Removes the package's build products so the next build doesn't link objects left
  /// over from the other mode. Dependency checkouts and downloads are kept, and so is
  /// `index-build`, which sourcekit-lsp uses for background indexing.
  ///
  /// Throws without removing anything while another SwiftPM process holds `.build/.lock`.
  @discardableResult
  public func cleanBuildProducts() throws -> [String] {
    let build = options.packageDirectory.appendingPathComponent(".build")
    let lockURL = build.appendingPathComponent(".lock")
    let lock = (try? String(contentsOf: lockURL, encoding: .utf8)) ?? ""
    if let pid = Int32(lock.trimmingCharacters(in: .whitespacesAndNewlines)),
       kill(pid, 0) == 0 {
      throw MakerError("""
        SwiftPM (process \(pid)) is using .build, so it wasn't cleared. Once it finishes, \
        clear it with `swift package clean` before building in the new mode.
        """)
    }
    let kept: Set = [
      ".lock",
      "artifacts",
      "checkouts",
      "index-build",
      "repositories",
      "workspace-state.json"
    ]
    let entries = (try? FileManager.default.contentsOfDirectory(atPath: build.path)) ?? []
    let removed = entries.filter { !kept.contains($0) }.sorted()
    for entry in removed {
      try FileManager.default.removeItem(at: build.appendingPathComponent(entry))
    }
    return removed
  }

  let log: @Sendable (String) -> Void

  var shell: Shell {
    Shell(streamOutput: options.verbose)
  }

  private struct CacheLocation {
    let url: URL
    /// The shared per-user cache, which the manifest locates through `packableCache`.
    let isShared: Bool
  }

  private var configDirectory: URL {
    options.configURL.deletingLastPathComponent()
  }

  private func absoluteURL(_ path: String) -> URL {
    URL(fileURLWithPath: path, relativeTo: configDirectory).standardizedFileURL
  }

  /// A `Package.Dependency` expression; paths become relative to the package directory.
  private func expression(for location: PackableConfig.Location) -> String {
    if let path = location.path {
      let relative = relativePath(to: absoluteURL(path), from: options.packageDirectory)
      return ".package(path: \(swiftLiteral(relative)))"
    }
    return ".package(url: \(swiftLiteral(location.url!)), \(location.requirementArguments!))"
  }

  private func cacheLocation(for config: PackableConfig) -> CacheLocation {
    if let cache = config.cache {
      return CacheLocation(url: absoluteURL(cache), isShared: false)
    }
    let environment = ProcessInfo.processInfo.environment
    let path = environment["XCFRAMEWORK_PACKABLE_CACHE"]
      ?? NSHomeDirectory() + "/Library/Caches/xcframework-packable"
    return CacheLocation(
      url: URL(fileURLWithPath: path).standardizedFileURL,
      isShared: true
    )
  }

  /// Returns the binary package directory for `dependency`, building it when the cache
  /// has no current copy. Local sources are keyed by a fingerprint of their files,
  /// remote ones by the version (or revision) SwiftPM resolves.
  private func buildOnDemand(
    name: String,
    dependency: PackableConfig.Dependency,
    cache: CacheLocation
  ) throws -> URL {
    let root = cache.url.appendingPathComponent(name)

    if let path = dependency.source.path {
      let source = absoluteURL(path)
      let fingerprint = sourceFingerprint(of: source)
      let output = root.appendingPathComponent("local/\(name)-binary")
      if !options.rebuild, BinaryMetadata.read(from: output)?.fingerprint == fingerprint {
        log("▸ \(name): binary is up to date (\(output.path))")
        return output
      }
      log("▸ \(name): building binary from \(source.path)")
      try package(
        source: source,
        into: output,
        scratch: root.appendingPathComponent("local/scratch"),
        dependency: dependency,
        fingerprint: fingerprint
      )
      return output
    }

    let (checkout, key) = try resolveRemote(
      name: name,
      location: dependency.source,
      root: root
    )
    let output = root.appendingPathComponent("\(key)/\(name)-binary")
    if !options.rebuild, BinaryMetadata.read(from: output) != nil {
      log("▸ \(name) \(key): using cached binary (\(output.path))")
      return output
    }
    log("▸ \(name) \(key): building binary")
    let scratch = root.appendingPathComponent("\(key)/scratch")
    try package(source: checkout, into: output, scratch: scratch, dependency: dependency)
    try? FileManager.default.removeItem(at: scratch)
    return output
  }

  /// Lets SwiftPM resolve a remote requirement in a throwaway package; returns the
  /// checkout and a cache key (the tag, or `rev-<commit>` for branches and revisions).
  private func resolveRemote(
    name: String,
    location: PackableConfig.Location,
    root: URL
  ) throws -> (checkout: URL, key: String) {
    let resolver = root.appendingPathComponent("resolver")
    try FileManager.default.createDirectory(
      at: resolver,
      withIntermediateDirectories: true
    )
    let manifest = """
      // swift-tools-version:5.9
      import PackageDescription

      // Used by xcframework-packable to resolve \(name)'s source.
      let package = Package(
        name: "packable-resolver",
        dependencies: [\(expression(for: location))],
        targets: []
      )

      """
    try manifest.write(
      to: resolver.appendingPathComponent("Package.swift"),
      atomically: true,
      encoding: .utf8
    )

    log("▸ \(name): resolving \(location.url!)")
    let location = ["--package-path", resolver.path]
    try shell
      .run(["swift", "package"] + location + [options.rebuild ? "update" : "resolve"])
    let json = try shell.run(
      ["swift", "package"] + location + ["show-dependencies", "--format", "json"],
      stream: false
    )
    let node = try JSONDecoder().decode(DependencyNode.self, from: Data(json.utf8))
    guard let resolved = node.dependencies.first else {
      throw MakerError("SwiftPM didn't resolve a source for \(name).")
    }
    let checkout = URL(fileURLWithPath: resolved.path)
    let git = GitInfo(directory: checkout, shell: shell)
    guard let key = git.version ?? git.revision.map({ "rev-" + $0.prefix(12) }) else {
      throw MakerError("Couldn't determine the revision of \(name) at \(checkout.path).")
    }
    return (checkout, key)
  }

  private func package(
    source: URL,
    into output: URL,
    scratch: URL,
    dependency: PackableConfig.Dependency,
    fingerprint: String? = nil
  ) throws {
    var options = MakerOptions(packageDirectory: source, outputDirectory: output)
    options.scratchDirectory = scratch
    options.products = dependency.products ?? []
    options.platforms = try (dependency.platforms ?? []).map { name in
      guard let platform = ApplePlatform(argument: name) else {
        throw MakerError("Unknown platform '\(name)' in packable.yml.")
      }
      return platform
    }
    options.verifyModuleInterfaces = !dependency.skipInterfaceVerification
    options.sourceFingerprint = fingerprint
    options.verbose = self.options.verbose
    let log = log
    let result = try Maker(options: options, log: { log("  " + $0) }).run()
    for warning in result.warnings {
      log("  warning: \(warning)")
    }
  }

  /// Library modules of a local source package; `nil` when they can't be read cheaply.
  private func sourceModules(
    of location: PackableConfig.Location,
    name: String,
    cache: CacheLocation
  ) -> [String]? {
    guard let path = location.path else {
      return nil
    }
    let swiftPM = SwiftPM(
      packageDirectory: absoluteURL(path),
      scratchDirectory: cache.url.appendingPathComponent(".manifests"),
      shell: Shell()
    )
    let manifest = try? swiftPM.dumpManifest(at: absoluteURL(path), identity: name)
    return manifest?.targets.filter(\.isLibrary).map { moduleName(forTarget: $0.name) }
  }

  /// SwiftPM rejects two targets with the same name, which happens when a binary package
  /// bundles a module that another dependency also provides.
  private func checkDuplicateModules(
    _ modulesByDependency: [String: [String]],
    binaries: Set<String>
  ) throws {
    var owners: [String: [String]] = [:]
    for (dependency, modules) in modulesByDependency {
      for module in modules {
        owners[module, default: []].append(dependency)
      }
    }
    let clashes = owners.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
    guard !clashes.isEmpty else {
      return
    }
    let details = clashes.map { module, dependencies in
      let bundling = dependencies.sorted().filter(binaries.contains)
      let providing = dependencies.sorted().filter { !binaries.contains($0) }
      var parts: [String] = []
      if !bundling.isEmpty {
        let binaries = bundling.map { "the \($0) binary" }
        parts.append("bundled in " + binaries.joined(separator: " and "))
      }
      if !providing.isEmpty {
        parts.append("provided by " + providing.joined(separator: " and "))
      }
      return "  \(module): \(parts.joined(separator: ", and also "))"
    }
    throw MakerError("""
      Some modules would be linked twice:
      \(details.joined(separator: "\n"))
      A binary package bundles the modules of its own dependencies. Remove the duplicate \
      entry from packable.yml (it comes with the binary), or use that binary's package \
      from source.
      """)
  }

  private func driftWarnings(
    name: String,
    source: PackableConfig.Location,
    binary: BinaryMetadata?
  ) -> [String] {
    guard let binary else {
      return []
    }
    if let exact = source.exact, let version = binary.version, exact != version {
      return [
        "\(name): the binary was built from \(version) but the source is pinned to \(exact)."
      ]
    }
    if let path = source.path, let built = binary.revision {
      let current = GitInfo(directory: absoluteURL(path), shell: Shell()).revision
      if let current, current != built {
        return [
          "\(name): the binary was built from \(built.prefix(12)), the source is at \(current.prefix(12))."
        ]
      }
    }
    return []
  }
}

/// Writes a progress line to standard error.
public let standardErrorLog: @Sendable (String) -> Void = {
  FileHandle.standardError.write(Data(($0 + "\n").utf8))
}
