import Foundation

public struct MakerOptions: Sendable {
  public init(packageDirectory: URL, outputDirectory: URL) {
    self.packageDirectory = packageDirectory
    self.outputDirectory = outputDirectory
  }

  public var packageDirectory: URL
  public var outputDirectory: URL
  /// Defaults to `<package>/.build/packable`.
  public var scratchDirectory: URL?
  /// Library products to package. Empty means every library product of the root package.
  public var products: [String] = []
  /// Platforms to build. Empty means the platforms declared in the manifest.
  public var platforms: [ApplePlatform] = []
  public var architectures: [ApplePlatform: [String]] = [:]
  /// Deployment target overrides keyed by manifest platform name (`ios`, `macos`, ...).
  public var deploymentTargets: [String: String] = [:]
  public var configuration: String = "release"
  /// Whether modules are packaged as static or dynamic frameworks.
  public var linkage: Linkage = .static
  public var verifyModuleInterfaces: Bool = true
  /// `xcodebuild -create-xcframework` drops compiled `.swiftmodule` files and keeps only
  /// interfaces. When true they're put back, so clients on the same compiler can import a
  /// module even if its interface doesn't compile. Always on when verification is
  /// skipped.
  public var includeBinarySwiftModules: Bool = false
  /// Builds with `-enable-library-evolution`. When false, the modules aren't resilient, so
  /// the compiled `.swiftmodule` files are kept too and clients should use the same
  /// compiler that built them.
  public var libraryEvolution: Bool = true
  public var extraBuildArguments: [String] = []
  public var zip: Bool = false
  /// When set together with `zip`, the generated manifest points at
  /// `<baseURL>/<Module>.xcframework.zip`.
  public var baseURL: String?
  public var bundleIdentifierPrefix: String = "packable"
  public var version: String = "1.0.0"
  public var verbose: Bool = false
  /// Build even when the output's build checksum shows it's up to date.
  public var rebuild: Bool = false
}

public struct MakerResult: Sendable {
  /// Module name → XCFramework (or zip, when zipping) on disk.
  public var artifacts: [String: URL] = [:]
  public var checksums: [String: String] = [:]
  public var products: [BinaryManifest.Product] = []
  public var manifest: URL?
  public var warnings: [String] = []
  /// SHA-256 of the build's inputs, recorded in `packable-metadata.json`.
  public var buildChecksum: String?
  /// True when the output was already up to date and nothing was built.
  public var skipped = false
}

/// Builds a Swift package's library products with SwiftPM and packages every module as an
/// XCFramework.
public struct Maker: Sendable {
  /// `log` receives progress lines; by default they go to standard error.
  public init(
    options: MakerOptions,
    log: @escaping @Sendable (String) -> Void = standardErrorLog
  ) {
    self.options = options
    self.log = log
  }

  public let options: MakerOptions

  public func loadPackages() throws -> [ResolvedPackage] {
    let manifestPath = options.packageDirectory.appendingPathComponent("Package.swift")
      .path
    guard FileManager.default.fileExists(atPath: manifestPath) else {
      throw MakerError("No Package.swift found in \(options.packageDirectory.path)")
    }
    return try swiftPM().loadPackages()
  }

  public func run() throws -> MakerResult {
    let fileManager = FileManager.default
    var result = MakerResult()

    log("▸ Resolving package graph")
    let packages = try loadPackages()
    let root = packages[0]
    let index = TargetIndex(packages: packages)
    let products = try selectedProducts(of: root.manifest)
    let platforms = selectedPlatforms(of: root.manifest)
    log("  products: \(products.joined(separator: ", "))")
    log("  platforms: \(platforms.map(\.rawValue).joined(separator: ", "))")

    let swiftPM = swiftPM()
    let checksum = buildChecksum(packages: packages, products: products, platforms: platforms)
    if !options.rebuild,
       let current = try upToDateResult(checksum: checksum, products: products) {
      log("▸ Up to date (build checksum \(checksum.prefix(12))), nothing rebuilt")
      return current
    }
    result.buildChecksum = checksum
    let assembler = FrameworkAssembler(
      shell: shell,
      bundleIdentifierPrefix: options.bundleIdentifierPrefix,
      version: options.version,
      linkage: options.linkage,
      extraLinkerArguments: linkerFlags(in: options.extraBuildArguments)
    )
    let staging = scratchDirectory.appendingPathComponent("frameworks")
    try? fileManager.removeItem(at: staging)

    // module → frameworks built for each platform
    var frameworks: [String: [ApplePlatform: URL]] = [:]
    var modulesByProduct: [String: Set<String>] = [:]
    var resourceBundles: [String: String] = [:]
    // Empty modules nothing imports, logged once.
    var skippedModules = Set<String>()
    let merger = ArchitectureMerger(shell: shell)
    let scratchRoot = canonicalPath(scratchDirectory) + "/"

    for platform in platforms {
      let architectures = options.architectures[platform] ?? platform.defaultArchitectures
      let platformStaging = staging.appendingPathComponent(platform.rawValue)
      // module → arch → snapshot of the module built for that arch
      var snapshots: [String: [String: BuiltModule]] = [:]

      for product in products {
        for architecture in architectures {
          let request = SwiftPM.BuildRequest(
            platform: platform,
            architecture: architecture,
            deploymentTarget: options.deploymentTargets[platform.manifestPlatformName],
            configuration: options.configuration,
            verifyModuleInterfaces: options.verifyModuleInterfaces,
            libraryEvolution: options.libraryEvolution,
            extraArguments: options.extraBuildArguments
          )
          let binPath = try swiftPM.binPath(for: request)
          guard canonicalPath(binPath).hasPrefix(scratchRoot) else {
            throw MakerError(
              "SwiftPM reported a products directory outside the scratch path: \(binPath.path)"
            )
          }

          log("▸ Building \(product) for \(platform.rawValue) (\(architecture))")
          // Start from an empty products folder so the objects left afterwards are
          // exactly the modules this product links.
          try? fileManager.removeItem(at: binPath)
          do {
            try swiftPM.build(product: product, request: request)
          } catch let error as ShellError
            where error.output.contains(".swiftinterface:") {
            throw MakerError(
              "\(error)\n\nA module interface failed to verify (often a dependency's). Re-run with --skip-interface-verification to ship it anyway; consumers on the same compiler still load the binary .swiftmodule."
            )
          }

          let productsDirectory = BuildProductsDirectory(url: binPath)
          let found = try productsDirectory.modules(index: index)
          guard !found.isEmpty else {
            throw MakerError(
              "Building \(product) for \(platform.rawValue) produced no library modules in \(binPath.path)"
            )
          }
          let unused = try productsDirectory.unusedEmptyModules(
            found,
            keeping: Set(root.manifest.product(named: product)?.targets
              .map(moduleName(forTarget:)) ?? []),
            index: index,
            architecture: architecture,
            shell: shell
          )
          for name in unused.sorted() where skippedModules.insert(name).inserted {
            log("  skipping \(name): it's empty and no module imports it")
          }
          let built = found.filter { !unused.contains($0.name) }
          let systemLibraries = try index.systemLibraries(usedBy: built.map(\.name))
            .map { name in
              try systemLibraryModule(
                name,
                index: index,
                usedBy: built,
                assembler: assembler,
                request: request,
                in: platformStaging.appendingPathComponent("system/\(architecture)")
              )
            }
          for module in built + systemLibraries {
            modulesByProduct[product, default: []].insert(module.name)
            if let bundle = module
              .resourceBundle {
              resourceBundles[module.name] = bundle.lastPathComponent
            }
            guard snapshots[module.name]?[architecture] == nil else {
              continue
            }
            let directory = platformStaging
              .appendingPathComponent("arch/\(architecture)/\(module.name)")
            snapshots[module.name, default: [:]][architecture] = try merger.snapshot(
              module,
              into: directory
            )
          }
        }
      }

      // Dependencies first: a dynamic framework links against the ones it uses.
      for (name, dependencies) in index.linkOrder(of: snapshots.keys) {
        let byArchitecture = snapshots[name] ?? [:]
        let slices = architectures.compactMap { byArchitecture[$0] }
        if slices.count != architectures.count {
          result.warnings
            .append(
              "\(name) was only built for \(byArchitecture.keys.sorted().joined(separator: ", ")) on \(platform.rawValue)."
            )
        }
        let universal = try merger.merge(
          slices,
          into: platformStaging.appendingPathComponent("universal/\(name)")
        )
        let linkedLibraries = index.entries[name]?.target.linkedLibraries ?? []
        frameworks[name, default: [:]][platform] = try assembler.assemble(
          universal,
          platform: platform,
          in: platformStaging,
          dependencies: dependencies,
          linkerArguments: linkedLibraries.flatMap { $0.arguments(for: platform) }
        )
      }
    }

    for (module, slices) in frameworks.sorted(by: { $0.key < $1.key })
      where slices.count != platforms.count {
      let missing = platforms.filter { slices[$0] == nil }.map(\.rawValue)
        .joined(separator: ", ")
      let reason = "(platform-conditional dependency); its XCFramework lacks those slices."
      result.warnings.append("\(module) wasn't built for \(missing) \(reason)")
    }
    if !options.libraryEvolution {
      result.warnings.append(
        "Built without library evolution: clients must use the same Swift compiler as this build."
      )
    }

    let artifactsDirectory = options.outputDirectory
      .appendingPathComponent("XCFrameworks")
    try? fileManager.removeItem(at: artifactsDirectory)
    try fileManager.createDirectory(
      at: artifactsDirectory,
      withIntermediateDirectories: true
    )

    var manifestArtifacts: [(module: String, location: BinaryManifest.Location)] = []
    for (module, slices) in frameworks.sorted(by: { $0.key < $1.key }) {
      log("▸ Creating \(module).xcframework")
      let xcframework = artifactsDirectory.appendingPathComponent("\(module).xcframework")
      let inputs = platforms.compactMap { slices[$0] }.flatMap { framework in
        let dSYM = FrameworkAssembler.debugSymbols(of: framework)
        let hasDSYM = fileManager.fileExists(atPath: dSYM.path)
        return ["-framework", framework.path] +
          (hasDSYM ? ["-debug-symbols", dSYM.path] : [])
      }
      // Without library evolution there are no interfaces, which xcodebuild only accepts
      // for frameworks marked as not for public distribution.
      let internalOnly = options.libraryEvolution ? [] : ["-allow-internal-distribution"]
      let create = ["xcodebuild", "-create-xcframework"] + inputs + internalOnly
      try shell.run(create + ["-output", xcframework.path], stream: false)
      if options.includeBinarySwiftModules || !options.verifyModuleInterfaces ||
        !options.libraryEvolution {
        try XCFramework.restoreBinarySwiftModules(
          in: xcframework,
          module: module,
          from: slices
        )
      }

      guard options.zip else {
        result.artifacts[module] = xcframework
        manifestArtifacts.append((
          module,
          .path("XCFrameworks/\(xcframework.lastPathComponent)")
        ))
        continue
      }
      let archive = artifactsDirectory.appendingPathComponent("\(module).xcframework.zip")
      let ditto = ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent"]
      try shell.run(ditto + [xcframework.path, archive.path], stream: false)
      try fileManager.removeItem(at: xcframework)
      let checksum = try swiftPM.computeChecksum(of: archive)
      result.artifacts[module] = archive
      result.checksums[module] = checksum
      if let baseURL = options.baseURL {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        manifestArtifacts.append((
          module,
          .remote(url: "\(trimmed)/\(archive.lastPathComponent)", checksum: checksum)
        ))
      } else {
        manifestArtifacts.append((
          module,
          .path("XCFrameworks/\(archive.lastPathComponent)")
        ))
      }
    }

    // The product's own targets first, then the modules they depend on.
    result.products = products.map { product in
      let primary = root.manifest.product(named: product)?.targets
        .map(moduleName(forTarget:)) ?? []
      let rest = (modulesByProduct[product] ?? []).subtracting(primary).sorted()
      return BinaryManifest.Product(
        name: product,
        modules: primary.filter { modulesByProduct[product]?.contains($0) == true } + rest
      )
    }

    // Static modules with resources get a carrier target, so SwiftPM installs their
    // bundles. A dynamic framework is embedded with its bundle, where `Bundle.module`
    // finds it.
    for folder in [
      ResourceCarrier.folder,
      ResourceCarrier.packagesFolder,
      ResourceCarrier.linksFolder
    ] {
      try? fileManager.removeItem(at: options.outputDirectory.appendingPathComponent(folder))
    }
    var carriers: [ResourceCarrier] = []
    // Dependency package name → its default localization, for its resource package.
    var resourcePackages: [String: String?] = [:]
    // SwiftPM's resolved resources for the root package; dependencies use a scan.
    let carried = options.linkage == .static ? resourceBundles : [:]
    let described = carried.isEmpty ? [:] : (try? swiftPM.describeResources()) ?? [:]
    for (module, bundle) in carried.sorted(by: { $0.key < $1.key }) {
      guard let entry = index.entries[module] else {
        continue
      }
      let isRoot = entry.package.identity == root.identity
      // The bundle SwiftPM built is named `<package name>_<target name>`; a carrier in
      // another package must produce the same name.
      let suffix = "_\(entry.target.name).bundle"
      let bundlePackage = bundle.hasSuffix(suffix)
        ? String(bundle.dropLast(suffix.count))
        : entry.package.manifest.name
      let carrier = try ResourceCarrier.make(
        module: module,
        target: entry.target,
        sourceDirectory: entry.package.sourceDirectory(of: entry.target),
        packageDirectory: options.outputDirectory,
        resolved: isRoot ? described[entry.target.name] : nil,
        foreignDirectories: entry.package.foreignDirectories(within: entry.target),
        bundlePackage: bundlePackage == root.manifest.name ? nil : bundlePackage
      )
      guard let carrier else {
        let advice = "apps must copy \(bundle) from its framework into their bundle."
        result.warnings
          .append("\(module)'s resources aren't declared in its manifest; \(advice)")
        continue
      }
      carriers.append(carrier)
      if let package = carrier.bundlePackage {
        resourcePackages[package] = entry.package.manifest.defaultLocalization
      }
    }
    for (package, defaultLocalization) in resourcePackages {
      let folder = options.outputDirectory
        .appendingPathComponent(ResourceCarrier.packageFolder(for: package))
      try BinaryManifest.renderResourcePackage(
        name: package,
        platforms: root.manifest.platforms,
        defaultLocalization: defaultLocalization,
        carriers: carriers.filter { $0.bundlePackage == package }
      ).write(
        to: folder.appendingPathComponent("Package.swift"),
        atomically: true,
        encoding: .utf8
      )
      try ResourceCarrier.makeLink(for: package, packageDirectory: options.outputDirectory)
    }

    let manifest = options.outputDirectory.appendingPathComponent("Package.swift")
    try BinaryManifest.render(
      packageName: root.manifest.name,
      platforms: root.manifest.platforms,
      products: result.products,
      artifacts: manifestArtifacts,
      defaultLocalization: root.manifest.defaultLocalization,
      resourceCarriers: carriers
    ).write(to: manifest, atomically: true, encoding: .utf8)
    result.manifest = manifest

    let git = GitInfo(directory: options.packageDirectory, shell: shell)
    try BinaryMetadata(
      package: root.manifest.name,
      version: git.version,
      revision: git.revision,
      buildChecksum: checksum,
      linkage: options.linkage,
      modules: frameworks.keys.sorted(),
      products: result.products.reduce(into: [:]) { $0[$1.name] = $1.modules }
    ).write(to: options.outputDirectory)
    return result
  }

  let log: @Sendable (String) -> Void

  var shell: Shell {
    Shell(streamOutput: options.verbose)
  }

  var scratchDirectory: URL {
    options.scratchDirectory ?? options.packageDirectory
      .appendingPathComponent(".build/packable")
  }

  func swiftPM() -> SwiftPM {
    SwiftPM(
      packageDirectory: options.packageDirectory,
      scratchDirectory: scratchDirectory,
      shell: shell
    )
  }

  /// A system library module for one architecture. Its framework holds the target's
  /// module map and headers, plus an empty object, since an XCFramework needs a binary.
  /// The object takes the deployment target of a module that uses the library.
  func systemLibraryModule(
    _ name: String,
    index: TargetIndex,
    usedBy built: [BuiltModule],
    assembler: FrameworkAssembler,
    request: SwiftPM.BuildRequest,
    in directory: URL
  ) throws -> BuiltModule {
    guard let entry = index.entries[name],
          let user = built.first(where: {
            index.systemLibraries(usedBy: [$0.name]).contains(name)
          }) else {
      throw MakerError("\(name) isn't a system library used by this build")
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let object = directory.appendingPathComponent("\(name).o")
    let minimumOS = try assembler.deploymentTarget(
      of: user.object,
      architecture: request.architecture
    )
    let triple = request.platform.triple(
      architecture: request.architecture,
      deploymentTarget: minimumOS
    )
    try shell.run(
      ["xcrun", "--sdk", request.platform.sdkName, "clang", "-target", triple]
        + ["-x", "c", "-c", "/dev/null", "-o", object.path],
      stream: false
    )
    return BuiltModule(
      name: name,
      object: object,
      kind: .clang(
        publicHeaders: entry.package.sourceDirectory(of: entry.target),
        skipping: entry.package.foreignDirectories(within: entry.target)
      ),
      resourceBundle: nil
    )
  }

  /// The `-Xlinker` pairs of `swift build` arguments (which come in `-X<tool> value`
  /// pairs).
  func linkerFlags(in arguments: [String]) -> [String] {
    stride(from: 0, to: arguments.count - 1, by: 2)
      .filter { arguments[$0] == "-Xlinker" }
      .flatMap { [arguments[$0], arguments[$0 + 1]] }
  }

  /// The build checksum for this run: every package's files, the settings that shape the
  /// output, and the toolchain. The output and scratch folders are left out, in case they
  /// sit inside a package.
  func buildChecksum(
    packages: [ResolvedPackage],
    products: [String],
    platforms: [ApplePlatform]
  ) -> String {
    let architectures = platforms.map { platform in
      let list = options.architectures[platform] ?? platform.defaultArchitectures
      return "\(platform.rawValue)=\(list.joined(separator: ","))"
    }
    let targets = options.deploymentTargets.sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
    let settings = [
      "products:" + products.joined(separator: ","),
      "platforms:" + platforms.map(\.rawValue).joined(separator: ","),
      "architectures:" + architectures.joined(separator: ";"),
      "deployment-targets:" + targets.joined(separator: ","),
      "configuration:" + options.configuration,
      "linkage:" + options.linkage.rawValue,
      "verify-interfaces:\(options.verifyModuleInterfaces)",
      "binary-swiftmodules:\(options.includeBinarySwiftModules)",
      "library-evolution:\(options.libraryEvolution)",
      "build-arguments:" + options.extraBuildArguments.joined(separator: "\u{1F}"),
      "zip:\(options.zip)",
      "base-url:" + (options.baseURL ?? ""),
      "bundle-id-prefix:" + options.bundleIdentifierPrefix,
      "framework-version:" + options.version
    ] + BuildChecksum.toolchain(shell: Shell())
    return BuildChecksum.compute(
      packages: packages.map { ($0.identity, $0.directory) },
      settings: settings,
      excluding: [options.outputDirectory, scratchDirectory]
    )
  }

  /// The result of the previous build when the output was built from the same inputs and
  /// is still complete; `nil` when it has to be built again.
  func upToDateResult(checksum: String, products: [String]) throws -> MakerResult? {
    let output = options.outputDirectory
    let fileManager = FileManager.default
    guard let metadata = BinaryMetadata.read(from: output),
          metadata.buildChecksum == checksum,
          fileManager.fileExists(atPath: output.appendingPathComponent("Package.swift").path)
    else {
      return nil
    }
    let suffix = options.zip ? ".xcframework.zip" : ".xcframework"
    var result = MakerResult()
    for module in metadata.modules {
      let artifact = output.appendingPathComponent("XCFrameworks/\(module)\(suffix)")
      guard fileManager.fileExists(atPath: artifact.path) else {
        return nil
      }
      result.artifacts[module] = artifact
      if options.zip {
        result.checksums[module] = try swiftPM().computeChecksum(of: artifact)
      }
    }
    result.products = products.map {
      BinaryManifest.Product(name: $0, modules: metadata.products[$0] ?? [])
    }
    result.manifest = output.appendingPathComponent("Package.swift")
    result.buildChecksum = checksum
    result.skipped = true
    return result
  }

  func selectedProducts(of manifest: PackageManifest) throws -> [String] {
    let libraries = manifest.libraryProducts.map(\.name)
    guard !options.products.isEmpty else {
      guard !libraries.isEmpty else {
        throw MakerError("\(manifest.name) declares no library products.")
      }
      return libraries
    }
    for product in options.products where !libraries.contains(product) {
      throw MakerError(
        "'\(product)' is not a library product of \(manifest.name). Library products: \(libraries.joined(separator: ", "))"
      )
    }
    return options.products
  }

  func selectedPlatforms(of manifest: PackageManifest) -> [ApplePlatform] {
    options.platforms.isEmpty ? ApplePlatform
      .defaultSlices(for: manifest.platforms) : options.platforms
  }
}

/// A path for comparing locations: symlinks resolved, letter case as on disk, and
/// `/private/tmp` and `/tmp` treated alike. Foundation only resolves paths that exist, so
/// the nearest existing folder is resolved and the rest appended.
func canonicalPath(_ url: URL) -> String {
  var existing = url.standardizedFileURL
  var missing: [String] = []
  while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
    missing.insert(existing.lastPathComponent, at: 0)
    existing.deleteLastPathComponent()
  }
  let resolved = missing.reduce(existing.resolvingSymlinksInPath()) {
    $0.appendingPathComponent($1)
  }
  let path = resolved.path
  return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
}
