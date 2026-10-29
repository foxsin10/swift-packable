import Foundation

public struct MakerOptions: Sendable {
  public init(packageDirectory: URL, outputDirectory: URL) {
    self.packageDirectory = packageDirectory
    self.outputDirectory = outputDirectory
  }

  public var packageDirectory: URL
  public var outputDirectory: URL
  /// Defaults to `<package>/.build/xcframework-packable`.
  public var scratchDirectory: URL?
  /// Library products to package. Empty means every library product of the root package.
  public var products: [String] = []
  /// Platforms to build. Empty means the platforms declared in the manifest.
  public var platforms: [ApplePlatform] = []
  public var architectures: [ApplePlatform: [String]] = [:]
  /// Deployment target overrides keyed by manifest platform name (`ios`, `macos`, ...).
  public var deploymentTargets: [String: String] = [:]
  public var configuration: String = "release"
  public var verifyModuleInterfaces: Bool = true
  /// `xcodebuild -create-xcframework` drops compiled `.swiftmodule` files and keeps only
  /// interfaces. When true they're put back, so clients on the same compiler can import a
  /// module even if its interface doesn't compile. Always on when verification is
  /// skipped.
  public var includeBinarySwiftModules: Bool = false
  public var extraBuildArguments: [String] = []
  public var zip: Bool = false
  /// When set together with `zip`, the generated manifest points at
  /// `<baseURL>/<Module>.xcframework.zip`.
  public var baseURL: String?
  public var bundleIdentifierPrefix: String = "xcframework-packable"
  public var version: String = "1.0.0"
  public var verbose: Bool = false
}

public struct MakerResult: Sendable {
  /// Module name → XCFramework (or zip, when zipping) on disk.
  public var artifacts: [String: URL] = [:]
  public var checksums: [String: String] = [:]
  public var products: [BinaryManifest.Product] = []
  public var manifest: URL?
  public var warnings: [String] = []
}

/// Builds a Swift package's library products with SwiftPM and packages every module as an
/// XCFramework.
public struct Maker: Sendable {
  /// `log` receives progress lines; by default they go to standard error.
  public init(
    options: MakerOptions,
    log: @escaping @Sendable (String)
      -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
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
    let assembler = FrameworkAssembler(
      shell: shell,
      bundleIdentifierPrefix: options.bundleIdentifierPrefix,
      version: options.version
    )
    let staging = scratchDirectory.appendingPathComponent("frameworks")
    try? fileManager.removeItem(at: staging)

    // module → frameworks built for each platform
    var frameworks: [String: [ApplePlatform: URL]] = [:]
    var modulesByProduct: [String: Set<String>] = [:]
    var resourceBundles: [String: String] = [:]
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

          let modules = try BuildProductsDirectory(url: binPath).modules(index: index)
          guard !modules.isEmpty else {
            throw MakerError(
              "Building \(product) for \(platform.rawValue) produced no library modules in \(binPath.path)"
            )
          }
          for module in modules {
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

      for (name, byArchitecture) in snapshots.sorted(by: { $0.key < $1.key }) {
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
        frameworks[name, default: [:]][platform] = try assembler.assemble(
          universal,
          platform: platform,
          in: platformStaging
        )
      }
    }

    for (module, bundle) in resourceBundles.sorted(by: { $0.key < $1.key }) {
      result.warnings
        .append(
          "\(module) has resources: \(bundle) is inside its framework. Apps must copy that bundle into their own bundle for Bundle.module to find it."
        )
    }

    for (module, slices) in frameworks.sorted(by: { $0.key < $1.key })
      where slices.count != platforms.count {
      let missing = platforms.filter { slices[$0] == nil }.map(\.rawValue)
      result.warnings
        .append(
          "\(module) wasn't built for \(missing.joined(separator: ", ")) (platform-conditional dependency); its XCFramework lacks those slices."
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
      var arguments = ["xcodebuild", "-create-xcframework"]
      for platform in platforms {
        if let framework = slices[platform] {
          arguments += [
            "-framework",
            framework.path
          ] }
      }
      try shell.run(arguments + ["-output", xcframework.path], stream: false)
      if options.includeBinarySwiftModules || !options.verifyModuleInterfaces {
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
      try shell.run(
        [
          "ditto",
          "-c",
          "-k",
          "--sequesterRsrc",
          "--keepParent",
          xcframework.path,
          archive.path
        ],
        stream: false
      )
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

    let manifest = options.outputDirectory.appendingPathComponent("Package.swift")
    try BinaryManifest.render(
      packageName: root.manifest.name,
      platforms: root.manifest.platforms,
      products: result.products,
      artifacts: manifestArtifacts
    ).write(to: manifest, atomically: true, encoding: .utf8)
    result.manifest = manifest
    return result
  }

  let log: @Sendable (String) -> Void

  var shell: Shell {
    Shell(streamOutput: options.verbose)
  }

  var scratchDirectory: URL {
    options.scratchDirectory ?? options.packageDirectory
      .appendingPathComponent(".build/xcframework-packable")
  }

  func swiftPM() -> SwiftPM {
    SwiftPM(
      packageDirectory: options.packageDirectory,
      scratchDirectory: scratchDirectory,
      shell: shell
    )
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

/// A path for comparing locations: symlinks resolved, and `/private/tmp` and `/tmp`
/// treated alike (Foundation strips `/private` only for paths that exist).
func canonicalPath(_ url: URL) -> String {
  let path = url.standardizedFileURL.resolvingSymlinksInPath().path
  return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
}
