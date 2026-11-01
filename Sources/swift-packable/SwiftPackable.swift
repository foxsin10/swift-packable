import ArgumentParser
import Foundation
import PackableKit

@main
struct SwiftPackable: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "swift-packable",
    abstract: "Build a Swift package's library products into XCFrameworks with SwiftPM.",
    discussion: """
      swift-packable compiles every module of the selected products with `swift build` \
      (one run per platform, with library evolution and module interfaces enabled \
      unless --disable-library-evolution), \
      wraps each module in a static (or, with --linkage dynamic, dynamic) framework, \
      merges the platforms with \
      `xcodebuild -create-xcframework`, and writes a Package.swift that exposes the \
      results as binary targets.
      """,
    version: "0.2.0",
    subcommands: [Build.self, List.self, Generate.self, Use.self],
    defaultSubcommand: Build.self
  )

  static func main() {
    // Keep stdout lines in order with the progress lines on stderr when piped.
    setvbuf(stdout, nil, _IOLBF, 0)
    main(nil)
  }
}

struct PackageLocation: ParsableArguments {
  @Argument(help: "Path to the Swift package.", completion: .directory)
  var packagePath: String = "."

  var url: URL {
    URL(fileURLWithPath: packagePath).standardizedFileURL
  }
}

struct Build: ParsableCommand {
  static let configuration =
    CommandConfiguration(abstract: "Build XCFrameworks (default command).")

  @OptionGroup var location: PackageLocation

  @Option(
    name: .shortAndLong,
    help: "Library product to package. Repeat for several. Default: all library products."
  )
  var product: [String] = []

  @Option(name: .long, help: ArgumentHelp(
    "Platform slice to build. Repeat or comma-separate. Default: the manifest's platforms.",
    discussion: "Values: \(ApplePlatform.allCases.map(\.rawValue).joined(separator: ", "))"
  ))
  var platform: [String] = []

  @Option(
    name: .long,
    help: "Architectures for a slice, e.g. ios-simulator=arm64 or macos=arm64,x86_64."
  )
  var arch: [String] = []

  @Option(
    name: .long,
    help: "Deployment target override, e.g. ios=15.0 (applies to device and simulator)."
  )
  var deploymentTarget: [String] = []

  @Option(
    name: .shortAndLong,
    help: "Output directory for XCFrameworks and the generated Package.swift. Default: <package>-binary next to the package."
  )
  var output: String?

  @Option(name: .shortAndLong, help: "Build configuration: release or debug.")
  var configuration: String = "release"

  @Option(help: ArgumentHelp(
    "Framework linkage: static or dynamic.",
    discussion: "Dynamic frameworks are embedded in the app and keep their resource bundles inside."
  ))
  var linkage: Linkage = .static

  @Flag(
    help: "Don't verify emitted module interfaces (needed for some dependencies whose interfaces don't compile)."
  )
  var skipInterfaceVerification = false

  @Flag(
    help: "Keep compiled .swiftmodule files next to the interfaces (implied by --skip-interface-verification)."
  )
  var includeBinarySwiftmodules = false

  @Flag(help: ArgumentHelp(
    "Build without -enable-library-evolution, for packages that don't compile with it.",
    discussion: "The modules aren't resilient, so no .swiftinterface files are emitted: the frameworks carry only compiled .swiftmodule files, and clients must use the same Swift compiler."
  ))
  var disableLibraryEvolution = false

  @Flag(help: "Zip each XCFramework and record its SwiftPM checksum.")
  var zip = false

  @Option(
    help: "Base URL where the zips will be hosted; the generated Package.swift then uses url: + checksum:. Requires --zip."
  )
  var baseURL: String?

  @Option(help: "Prefix for the frameworks' CFBundleIdentifier.")
  var bundleIdPrefix: String = "packable"

  @Option(
    name: .customLong("framework-version"),
    help: "CFBundleShortVersionString / CFBundleVersion of the frameworks."
  )
  var frameworkVersion: String = "1.0.0"

  @Option(help: "SwiftPM scratch path. Default: <package>/.build/packable.")
  var scratchPath: String?

  @Option(
    name: .customLong("Xswiftc", withSingleDash: true),
    parsing: .unconditionalSingleValue,
    help: "Pass a flag through to the Swift compiler."
  )
  var swiftcFlags: [String] = []

  @Option(
    name: .customLong("Xcc", withSingleDash: true),
    parsing: .unconditionalSingleValue,
    help: "Pass a flag through to the C compiler."
  )
  var ccFlags: [String] = []

  @Option(
    name: .customLong("Xlinker", withSingleDash: true),
    parsing: .unconditionalSingleValue,
    help: "Pass a flag through to the linker."
  )
  var linkerFlags: [String] = []

  @Flag(
    help: "Build even when the output's build checksum (sources, dependencies, options, toolchain) is unchanged."
  )
  var rebuild = false

  @Flag(name: .shortAndLong, help: "Stream swift build output.")
  var verbose = false

  func validate() throws {
    if baseURL != nil, !zip {
      throw ValidationError("--base-url requires --zip.")
    }
    guard ["release", "debug"].contains(configuration) else {
      throw ValidationError("--configuration must be release or debug.")
    }
    _ = try parsedPlatforms()
    _ = try parsedArchitectures()
    _ = try keyValues(deploymentTarget, option: "--deployment-target")
  }

  func run() throws {
    let packageURL = location.url
    let outputURL = output.map { URL(fileURLWithPath: $0).standardizedFileURL }
      ?? packageURL.deletingLastPathComponent()
      .appendingPathComponent("\(packageURL.lastPathComponent)-binary")

    var options = MakerOptions(packageDirectory: packageURL, outputDirectory: outputURL)
    options.scratchDirectory = scratchPath
      .map { URL(fileURLWithPath: $0).standardizedFileURL }
    options.products = product
    options.platforms = try parsedPlatforms()
    options.architectures = try parsedArchitectures()
    let targets = try keyValues(deploymentTarget, option: "--deployment-target")
    options.deploymentTargets = targets
      .reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
    options.configuration = configuration
    options.linkage = linkage
    options.verifyModuleInterfaces = !skipInterfaceVerification
    options.includeBinarySwiftModules = includeBinarySwiftmodules
    options.libraryEvolution = !disableLibraryEvolution
    options.extraBuildArguments = swiftcFlags.flatMap { ["-Xswiftc", $0] }
      + ccFlags.flatMap { ["-Xcc", $0] }
      + linkerFlags.flatMap { ["-Xlinker", $0] }
    options.zip = zip
    options.baseURL = baseURL
    options.bundleIdentifierPrefix = bundleIdPrefix
    options.version = frameworkVersion
    options.verbose = verbose
    options.rebuild = rebuild

    let start = Date()
    let result: MakerResult
    do {
      result = try Maker(options: options).run()
    } catch {
      fail(error)
    }

    print("")
    for warning in result.warnings {
      print("warning: \(warning)")
    }
    let elapsed = String(format: "%.1f", Date().timeIntervalSince(start))
    if result.skipped {
      print("✔ Up to date: \(result.artifacts.count) XCFramework(s), nothing rebuilt (\(elapsed)s)")
    } else {
      print("✔ Built \(result.artifacts.count) XCFramework(s) in \(elapsed)s")
    }
    if let checksum = result.buildChecksum {
      print("  build checksum: \(checksum)")
    }
    for (module, url) in result.artifacts.sorted(by: { $0.key < $1.key }) {
      let checksum = result.checksums[module].map { "  checksum: \($0)" } ?? ""
      print("  \(url.path)\(checksum)")
    }
    for product in result.products {
      print("  product \(product.name): \(product.modules.joined(separator: ", "))")
    }
    if let manifest = result.manifest {
      print("  manifest: \(manifest.path)")
    }
  }

  func parsedPlatforms() throws -> [ApplePlatform] {
    try platform.flatMap { $0.split(separator: ",") }.map { name in
      guard let platform = ApplePlatform(argument: String(name)) else {
        throw ValidationError(
          "Unknown platform '\(name)'. Use one of: \(ApplePlatform.allCases.map(\.rawValue).joined(separator: ", "))"
        )
      }
      return platform
    }
  }

  func parsedArchitectures() throws -> [ApplePlatform: [String]] {
    try keyValues(arch, option: "--arch").reduce(into: [:]) { result, pair in
      guard let platform = ApplePlatform(argument: pair.key) else {
        throw ValidationError("Unknown platform '\(pair.key)' in --arch.")
      }
      result[platform] = pair.value.split(separator: ",").map(String.init)
    }
  }

  func keyValues(_ values: [String], option: String) throws -> [(
    key: String,
    value: String
  )] {
    try values.map { value in
      let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
        throw ValidationError("\(option) expects <platform>=<value>, got '\(value)'.")
      }
      return (parts[0], parts[1])
    }
  }
}

struct List: ParsableCommand {
  static let configuration =
    CommandConfiguration(
      abstract: "Show the library products, targets and platforms swift-packable would build."
    )

  @OptionGroup var location: PackageLocation

  func run() throws {
    let options = MakerOptions(
      packageDirectory: location.url,
      outputDirectory: location.url
    )
    let maker = Maker(options: options)
    let packages: [ResolvedPackage]
    do { packages = try maker.loadPackages() } catch { fail(error) }
    let manifest = packages[0].manifest

    print("Package: \(manifest.name)")
    print("Library products:")
    for product in manifest.libraryProducts {
      print("  \(product.name)  (targets: \(product.targets.joined(separator: ", ")))")
    }
    let declared = manifest.platforms.map { "\($0.platformName) \($0.version)" }
    print(
      "Declared platforms: \(declared.isEmpty ? "none" : declared.joined(separator: ", "))"
    )
    print(
      "Default slices: \(ApplePlatform.defaultSlices(for: manifest.platforms).map(\.rawValue).joined(separator: ", "))"
    )
    if packages.count > 1 {
      print(
        "Dependencies: \(packages.dropFirst().map(\.identity).joined(separator: ", "))"
      )
    }
  }
}

extension Linkage: ExpressibleByArgument {}

/// Prints a tool error (often multi-line build output) and exits with a failure status.
func fail(_ error: Error) -> Never {
  FileHandle.standardError.write(Data("error: \(error)\n".utf8))
  SwiftPackable.exit(withError: ExitCode.failure)
}
