import Foundation
@testable import PackableKit
import Testing

/// Packages the `Fixtures/Demo` package with SwiftPM, then builds and runs a client
/// package that depends on the generated binary package.
@Suite(.serialized) struct EndToEndTests {
  @Test(.timeLimit(.minutes(10)), arguments: Linkage.allCases)
  func packagesFixtureAndClientRunsAgainstBinaries(linkage: Linkage) throws {
    let work = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: work) }

    let fixture = try #require(Bundle.module.url(
      forResource: "Fixtures/Demo",
      withExtension: nil
    ))
    let source = work.appendingPathComponent("Demo")
    try FileManager.default.copyItem(at: fixture, to: source)

    var options = MakerOptions(
      packageDirectory: source,
      outputDirectory: work.appendingPathComponent("DemoBinary")
    )
    options.scratchDirectory = work.appendingPathComponent("scratch")
    options.platforms = [.macOS, .iOSSimulator]
    options.architectures = [.macOS: ["arm64", "x86_64"], .iOSSimulator: ["arm64"]]
    options.zip = true
    options.linkage = linkage

    let result = try Maker(options: options, log: { _ in }).run()

    #expect(result.artifacts.keys.sorted() == ["CDemo", "CZlib", "Demo", "DemoCore", "DemoExtras", "Phrases"])
    #expect(result.products == [
      .init(name: "Demo", modules: ["Demo", "CDemo", "CZlib", "DemoCore"]),
      .init(name: "DemoExtras", modules: ["DemoExtras", "DemoCore", "Phrases"])
    ])
    #expect(result.checksums.count == 6)
    #expect(result.warnings.isEmpty)

    let binaryPackage = work.appendingPathComponent("DemoBinary")
    let generated = try String(
      contentsOf: binaryPackage.appendingPathComponent("Package.swift"),
      encoding: .utf8
    )
    let message = binaryPackage
      .appendingPathComponent("Resources/DemoExtras/Resources/message.txt")
    switch linkage {
    case .static:
      // DemoExtras has resources: its binary target is renamed, and a carrier target with
      // the original resource files takes the module's name.
      // Phrases comes from another package, so its carrier is in a local package with
      // that package's name, which its compiled Bundle.module expects in the bundle name.
      #expect(generated.contains(
        #"targets: ["DemoExtrasBinary", "DemoExtras", "DemoCore", "PhrasesBinary", "PhrasesResources"]"#
      ))
      #expect(generated.contains(#".package(path: "Packages/Phrases-resources")"#))
      let phrasesPackage = try String(
        contentsOf: binaryPackage.appendingPathComponent("Packages/Phrases-resources/Package.swift"),
        encoding: .utf8
      )
      #expect(phrasesPackage.contains(#"name: "Phrases","#))
      #expect(generated.contains(#"resources: [.process("Resources/message.txt")]"#))
      #expect(FileManager.default.fileExists(atPath: message.path))
    case .dynamic:
      // The bundle ships inside the embedded framework, so there's no carrier.
      #expect(generated.contains(#"targets: ["DemoExtras", "DemoCore", "Phrases"]"#))
      #expect(!FileManager.default.fileExists(atPath: message.path))
    }

    // Universal macOS slice, merged -Swift.h, framework module map for the C target.
    let shell = Shell()
    let unzipped = work.appendingPathComponent("unzipped")
    for module in ["Demo", "CDemo", "CZlib", "DemoExtras"] {
      try shell.run([
        "ditto",
        "-x",
        "-k",
        #require(result.artifacts[module]?.path),
        unzipped.path
      ])
    }
    let demo = unzipped
      .appendingPathComponent("Demo.xcframework/macos-arm64_x86_64/Demo.framework")
    let archs = try shell.run([
      "lipo",
      "-archs",
      demo.appendingPathComponent("Demo").path
    ])
    #expect(Set(archs.split(whereSeparator: \.isWhitespace)) == ["arm64", "x86_64"])
    if linkage == .dynamic {
      try expectDynamicFrameworks(in: unzipped, shell: shell)
    }
    let header = try String(
      contentsOf: demo.appendingPathComponent("Headers/Demo-Swift.h"),
      encoding: .utf8
    )
    #expect(header.contains("#elif defined(__arm64__) && __arm64__"))
    #expect(header.contains("#elif defined(__x86_64__) && __x86_64__"))
    #expect(header.contains("DMOGreeter"))
    let cModuleMap = try String(
      contentsOf: unzipped
        .appendingPathComponent(
          "CDemo.xcframework/ios-arm64-simulator/CDemo.framework/Modules/module.modulemap"
        ),
      encoding: .utf8
    )
    #expect(cModuleMap.contains("framework module CDemo"))
    // The system library keeps its module map, so `link "z"` still reaches clients.
    let systemModuleMap = try String(
      contentsOf: unzipped
        .appendingPathComponent(
          "CZlib.xcframework/ios-arm64-simulator/CZlib.framework/Modules/module.modulemap"
        ),
      encoding: .utf8
    )
    #expect(systemModuleMap.contains("framework module CZlib [system]"))
    #expect(systemModuleMap.contains(#"link "z""#))

    // A client package can depend on the generated Package.swift and run.
    let client = work.appendingPathComponent("Client")
    try FileManager.default.createDirectory(
      at: client.appendingPathComponent("Sources/Client"),
      withIntermediateDirectories: true
    )
    try """
      // swift-tools-version:5.9
      import PackageDescription
      let package = Package(
          name: "Client",
          platforms: [.macOS(.v12), .iOS(.v15)],
          dependencies: [.package(path: "../DemoBinary")],
          targets: [.executableTarget(name: "Client", dependencies: [
              .product(name: "Demo", package: "DemoBinary"),
              .product(name: "DemoExtras", package: "DemoBinary"),
          ])]
      )
      """.write(
      to: client.appendingPathComponent("Package.swift"),
      atomically: true,
      encoding: .utf8
    )
    try """
      import CDemo
      import Demo
      import DemoExtras
      import Phrases
      // Demo.checksum calls zlib through the CZlib system library module.
      print(
        Demo.answer(), Greeter().greeting(), Extras.doubled(), cdemo_add(2, 3),
        Demo.checksum("hello")
      )
      // Read from DemoExtras' resource bundle, which SwiftPM installs from the carrier target.
      print(Extras.message() ?? "missing")
      // Read from the Phrases dependency's own resource bundle.
      print(Phrases.farewell() ?? "missing")
      """.write(
      to: client.appendingPathComponent("Sources/Client/main.swift"),
      atomically: true,
      encoding: .utf8
    )

    let scratch = ["--scratch-path", work.appendingPathComponent("client-scratch").path]
    // Under Swift Build, command-line executables get no rpath to the frameworks SwiftPM
    // copies next to them.
    let rpath = linkage == .dynamic
      ? ["-Xlinker", "-rpath", "-Xlinker", "@executable_path"]
      : []
    let output = try shell.run(
      ["swift", "run"] + scratch + rpath + ["Client"],
      in: client
    )
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines)
      .hasSuffix("42 answer=42 82 5 907060870\nhello from resources\n\ngoodbye from a dependency"))

    let simulatorSDK = try shell.run([
      "xcrun",
      "--sdk",
      "iphonesimulator",
      "--show-sdk-path"
    ]).trimmingCharacters(in: .whitespacesAndNewlines)
    try shell.run(
      ["swift", "build"] + scratch + [
        "--triple",
        "arm64-apple-ios15.0-simulator",
        "--sdk",
        simulatorSDK
      ],
      in: client
    )
  }
}

/// Without library evolution there are no module interfaces: the XCFrameworks carry the
/// compiled `.swiftmodule` files, and a client built by the same compiler uses them.
@Suite(.serialized) struct NoLibraryEvolutionEndToEndTests {
  @Test(.timeLimit(.minutes(10)))
  func packagesCompiledModulesOnly() throws {
    let work = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    let fixture = try #require(Bundle.module.url(
      forResource: "Fixtures/Demo",
      withExtension: nil
    ))
    let source = work.appendingPathComponent("Demo")
    try FileManager.default.copyItem(at: fixture, to: source)

    var options = MakerOptions(
      packageDirectory: source,
      outputDirectory: work.appendingPathComponent("DemoBinary")
    )
    options.scratchDirectory = work.appendingPathComponent("scratch")
    options.products = ["Demo"]
    options.platforms = [.macOS]
    options.architectures = [.macOS: ["arm64"]]
    options.libraryEvolution = false
    let result = try Maker(options: options, log: { _ in }).run()
    #expect(result.warnings == [
      "Built without library evolution: clients must use the same Swift compiler as this build."
    ])

    // DemoMarker is empty and nothing imports it, so it isn't packaged.
    #expect(result.products == [.init(name: "Demo", modules: ["Demo", "CDemo", "CZlib", "DemoCore"])])
    #expect(result.artifacts["DemoMarker"] == nil)

    let module = try #require(result.artifacts["Demo"])
      .appendingPathComponent("macos-arm64/Demo.framework/Modules/Demo.swiftmodule")
    let files = try FileManager.default.contentsOfDirectory(atPath: module.path)
    #expect(files.contains("arm64-apple-macos.swiftmodule"))
    #expect(!files.contains { $0.hasSuffix(".swiftinterface") })

    let client = work.appendingPathComponent("Client")
    try FileManager.default.createDirectory(
      at: client.appendingPathComponent("Sources/Client"),
      withIntermediateDirectories: true
    )
    try """
      // swift-tools-version:5.9
      import PackageDescription
      let package = Package(
          name: "Client",
          platforms: [.macOS(.v12)],
          dependencies: [.package(path: "../DemoBinary")],
          targets: [.executableTarget(name: "Client", dependencies: [
              .product(name: "Demo", package: "DemoBinary"),
          ])]
      )
      """.write(
      to: client.appendingPathComponent("Package.swift"),
      atomically: true,
      encoding: .utf8
    )
    try """
      import Demo
      print(Demo.answer(), Demo.checksum("hello"))
      """.write(
      to: client.appendingPathComponent("Sources/Client/main.swift"),
      atomically: true,
      encoding: .utf8
    )
    let output = try Shell().run(
      ["swift", "run", "--scratch-path", work.appendingPathComponent("client-scratch").path,
       "Client"],
      in: client
    )
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("42 907060870"))
  }
}

/// Checks the dynamic slices: dylibs that load their dependencies through `@rpath`,
/// dSYMs, `MinimumOSVersion`, and resource bundles kept inside the framework.
private func expectDynamicFrameworks(in unzipped: URL, shell: Shell) throws {
  let slice = unzipped.appendingPathComponent("Demo.xcframework/macos-arm64_x86_64")
  let binary = slice.appendingPathComponent("Demo.framework/Demo")
  #expect(try shell.run(["file", binary.path])
    .contains("dynamically linked shared library"))
  let libraries = try shell.run(["otool", "-L", binary.path])
  #expect(libraries.contains("@rpath/Demo.framework/Versions/A/Demo"))
  #expect(libraries.contains("@rpath/DemoCore.framework/Versions/A/DemoCore"))
  #expect(libraries.contains("@rpath/CDemo.framework/Versions/A/CDemo"))
  let dSYM = slice.appendingPathComponent("dSYMs/Demo.framework.dSYM")
  #expect(FileManager.default.fileExists(atPath: dSYM.path))

  let simulator = unzipped.appendingPathComponent(
    "DemoExtras.xcframework/ios-arm64-simulator/DemoExtras.framework"
  )
  let plist = try Data(contentsOf: simulator.appendingPathComponent("Info.plist"))
  let info = try #require(
    PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
  )
  #expect(info["MinimumOSVersion"] as? String == "15.0")
  let bundle = simulator.appendingPathComponent("Demo_DemoExtras.bundle")
  #expect(FileManager.default.fileExists(atPath: bundle.path))
}

/// A client switches the `Fixtures/Demo` package between source and an on-demand binary.
@Suite(.serialized) struct SwitchingEndToEndTests {
  @Test(.timeLimit(.minutes(10)))
  func switchesBetweenSourceAndBinary() throws {
    let work = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: work) }

    let fixture = try #require(Bundle.module.url(
      forResource: "Fixtures/Demo",
      withExtension: nil
    ))
    try FileManager.default.copyItem(at: fixture, to: work.appendingPathComponent("Demo"))

    let client = work.appendingPathComponent("Client")
    try FileManager.default.createDirectory(
      at: client.appendingPathComponent("Sources/Client"),
      withIntermediateDirectories: true
    )
    try """
      # No `cache:`, so binaries go to the default .build/packable-cache.
      dependencies:
        Demo:
          source: { path: ../Demo }
          products: [Demo]
          platforms: [macos]
      """.write(
      to: client.appendingPathComponent("packable.yml"),
      atomically: true,
      encoding: .utf8
    )
    try """
      // swift-tools-version:5.9
      import PackageDescription

      let package = Package(
        name: "Client",
        platforms: [.macOS(.v12)],
        dependencies: packableDependencies,
        targets: [.executableTarget(name: "Client", dependencies: [packable("Demo", from: "Demo")])]
      )
      """.write(
      to: client.appendingPathComponent("Package.swift"),
      atomically: true,
      encoding: .utf8
    )
    try """
      import Demo
      print(Demo.answer())
      """.write(
      to: client.appendingPathComponent("Sources/Client/main.swift"),
      atomically: true,
      encoding: .utf8
    )

    let switcher = DependencySwitcher(
      options: .init(packageDirectory: client),
      log: { _ in }
    )
    let shell = Shell()
    func runClient() throws -> String {
      try shell.run(["swift", "run", "--package-path", client.path, "Client"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func manifest() throws -> String {
      try String(
        contentsOf: client.appendingPathComponent("Package.swift"),
        encoding: .utf8
      )
    }

    let source = try switcher.generate()
    #expect(source.dependencies
      .map(\.packageExpression) == [".package(path: \"../Demo\")"])
    #expect(try runClient() == "42")

    let (changed, binary) = try switcher.use(.binary, for: ["Demo"])
    #expect(changed == ["Demo"])
    #expect(binary.dependencies.first?.packageExpression
      == ".package(path: \".build/packable-cache/Demo/local/Demo-binary\")")
    let built = client
      .appendingPathComponent(".build/packable-cache/Demo/local/Demo-binary")
    #expect(BinaryMetadata.read(from: built)?.modules == ["CDemo", "CZlib", "Demo", "DemoCore"])
    // Clearing .build keeps the cache the manifest points at.
    try switcher.cleanBuildProducts()
    #expect(BinaryMetadata.read(from: built) != nil)
    #expect(try runClient() == "42")

    try switcher.use(.source, for: ["Demo"])
    try switcher.cleanBuildProducts()
    #expect(try manifest().contains(".package(path: \"../Demo\")"))
    #expect(try runClient() == "42")

    // The cached binary is reused: its build checksum still matches.
    let modified = try FileManager.default
      .attributesOfItem(atPath: built.path)[.modificationDate] as? Date
    try switcher.use(.binary, for: ["Demo"])
    let after = try FileManager.default
      .attributesOfItem(atPath: built.path)[.modificationDate] as? Date
    #expect(modified == after)
    let config = try String(
      contentsOf: client.appendingPathComponent("packable.yml"),
      encoding: .utf8
    )
    #expect(config.contains("# No `cache:`"))
    #expect(config.contains("    mode: binary"))
  }
}

/// Packages `Fixtures/CustomLayout`, whose targets live outside `Sources/<Target>`:
/// a custom `path:`, headers next to C sources, the `src/` default folder, and a target
/// at the package root narrowed with `sources:` and `exclude:`.
struct CustomLayoutEndToEndTests {
  @Test(.timeLimit(.minutes(10)))
  func packagesCustomLayoutAndClientRuns() throws {
    let work = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: work) }

    let fixture = try #require(Bundle.module.url(
      forResource: "Fixtures/CustomLayout",
      withExtension: nil
    ))
    let source = work.appendingPathComponent("CustomLayout")
    try FileManager.default.copyItem(at: fixture, to: source)

    let output = work.appendingPathComponent("CustomLayoutBinary")
    var options = MakerOptions(packageDirectory: source, outputDirectory: output)
    options.scratchDirectory = work.appendingPathComponent("scratch")
    options.platforms = [.macOS]
    options.architectures = [.macOS: ["arm64"]]
    let result = try Maker(options: options, log: { _ in }).run()

    #expect(result.artifacts.keys.sorted() == ["CLegacy", "Core", "Extra", "RootKit"])
    #expect(result.warnings.isEmpty)
    #expect(!result.skipped)
    #expect(BinaryMetadata.read(from: output)?.buildChecksum == result.buildChecksum)

    // Same inputs: nothing is rebuilt and the XCFrameworks are left as they are.
    let xcframework = output.appendingPathComponent("XCFrameworks/Core.xcframework")
    let built = try FileManager.default
      .attributesOfItem(atPath: xcframework.path)[.modificationDate] as? Date
    let again = try Maker(options: options, log: { _ in }).run()
    #expect(again.skipped)
    #expect(again.buildChecksum == result.buildChecksum)
    #expect(again.artifacts.mapValues(\.path) == result.artifacts.mapValues(\.path))
    #expect(again.products == result.products)
    let reused = try FileManager.default
      .attributesOfItem(atPath: xcframework.path)[.modificationDate] as? Date
    #expect(reused == built)

    // Only headers from `publicHeadersPath: "."`, not the C source next to them.
    let headers = output.appendingPathComponent(
      "XCFrameworks/CLegacy.xcframework/macos-arm64/CLegacy.framework/Headers"
    )
    let headerFiles = try FileManager.default.contentsOfDirectory(atPath: headers.path)
      .sorted()
    #expect(headerFiles == ["CLegacy-umbrella.h", "legacy.h"])

    // Carriers hold SwiftPM's resources; the excluded asset catalog stays out.
    let manifest = try String(
      contentsOf: output.appendingPathComponent("Package.swift"),
      encoding: .utf8
    )
    #expect(manifest.contains(#"resources: [.process("Resources/core.txt")],"#))
    #expect(manifest.contains(#"resources: [.copy("root.txt")],"#))
    #expect(!manifest.contains("Stray"))

    let client = work.appendingPathComponent("Client")
    try FileManager.default.createDirectory(
      at: client.appendingPathComponent("Sources/Client"),
      withIntermediateDirectories: true
    )
    try """
      // swift-tools-version:5.9
      import PackageDescription
      let package = Package(
        name: "Client",
        platforms: [.macOS(.v12)],
        dependencies: [.package(path: "../CustomLayoutBinary")],
        targets: [.executableTarget(name: "Client", dependencies: [
          .product(name: "RootKit", package: "CustomLayoutBinary")
        ])]
      )
      """.write(
      to: client.appendingPathComponent("Package.swift"),
      atomically: true,
      encoding: .utf8
    )
    try "import RootKit\nprint(RootKit.summary())\n".write(
      to: client.appendingPathComponent("Sources/Client/main.swift"),
      atomically: true,
      encoding: .utf8
    )
    let printed = try Shell().run([
      "swift",
      "run",
      "--package-path",
      client.path,
      "Client"
    ])
    let summary = printed.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(summary.hasSuffix("root resource | core resource | extra | 42"))
  }
}
