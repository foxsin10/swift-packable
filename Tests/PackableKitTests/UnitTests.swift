import Foundation
@testable import PackableKit
import Testing

private func platforms(_ json: String) throws -> [PackageManifest.Platform] {
  try JSONDecoder().decode([PackageManifest.Platform].self, from: Data(json.utf8))
}

struct ApplePlatformTests {
  @Test func triples() {
    #expect(ApplePlatform.iOSSimulator.triple(
      architecture: "x86_64",
      deploymentTarget: "15.0"
    ) == "x86_64-apple-ios15.0-simulator")
    #expect(ApplePlatform.iOS.triple(architecture: "arm64") == "arm64-apple-ios")
    #expect(ApplePlatform.macOS
      .triple(architecture: "arm64", deploymentTarget: "12.0") ==
      "arm64-apple-macosx12.0")
    #expect(ApplePlatform.macCatalyst
      .triple(architecture: "arm64") == "arm64-apple-ios-macabi")
    #expect(ApplePlatform.visionOSSimulator
      .triple(architecture: "arm64") == "arm64-apple-xros-simulator")
  }

  @Test func defaultSlicesFollowManifest() throws {
    let declared =
      try platforms(
        #"[{"platformName":"ios","version":"15.0"},{"platformName":"macos","version":"12.0"}]"#
      )
    #expect(ApplePlatform.defaultSlices(for: declared) == [.macOS, .iOS, .iOSSimulator])

    let tvOnly = try platforms(#"[{"platformName":"tvos","version":"17.0"}]"#)
    #expect(ApplePlatform.defaultSlices(for: tvOnly) == [.tvOS, .tvOSSimulator])
  }

  @Test func defaultSlicesWithoutDeclaredPlatforms() {
    #expect(ApplePlatform.defaultSlices(for: []) == [.macOS, .iOS, .iOSSimulator])
  }

  @Test func parsesArguments() {
    #expect(ApplePlatform(argument: "ios-simulator") == .iOSSimulator)
    #expect(ApplePlatform(argument: "iphonesimulator") == .iOSSimulator)
    #expect(ApplePlatform(argument: "Catalyst") == .macCatalyst)
    #expect(ApplePlatform(argument: "android") == nil)
  }
}

struct ModuleMapTests {
  @Test func customModuleMapBecomesFrameworkModule() {
    let custom = """
      module CFoo {
          header "foo.h"
          module Sub { header "sub.h" }
          export *
      }
      """
    let converted = ModuleMaps.frameworkModuleMap(fromCustom: custom)
    #expect(converted.hasPrefix("framework module CFoo {"))
    #expect(converted.contains("    module Sub { header \"sub.h\" }"))
  }

  @Test func umbrellaHeaderMatchesModuleNameIgnoringCase() throws {
    let root = try temporaryDirectory()
    let include = root.appendingPathComponent("include")
    try FileManager.default.createDirectory(
      at: include,
      withIntermediateDirectories: true
    )
    try "int f(void);".write(
      to: include.appendingPathComponent("cfoo.h"),
      atomically: true,
      encoding: .utf8
    )

    let map = try ModuleMaps.installClangHeaders(
      from: include,
      moduleName: "CFoo",
      into: root.appendingPathComponent("Headers")
    )
    #expect(map.contains("umbrella header \"cfoo.h\""))
  }

  @Test func copiesOnlyHeadersFromAMixedFolder() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Legacy")
    for path in ["legacy.h", "legacy.c", "sub/extra.hpp", "notes.txt", "Other/other.h"] {
      let url = source.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try "int x;".write(to: url, atomically: true, encoding: .utf8)
    }

    let headers = root.appendingPathComponent("Headers")
    let map = try ModuleMaps.installClangHeaders(
      from: source,
      moduleName: "Legacy",
      into: headers,
      skipping: [source.appendingPathComponent("Other")]
    )
    let copied = try #require(FileManager.default.enumerator(atPath: headers.path))
      .compactMap { $0 as? String }
      .filter { !$0.hasSuffix("sub") }
      .sorted()
    #expect(copied == ["legacy.h", "sub/extra.hpp"])
    #expect(map.contains("umbrella header \"legacy.h\""))
  }

  @Test func generatesUmbrellaHeaderForLooseHeaders() throws {
    let root = try temporaryDirectory()
    let include = root.appendingPathComponent("include/nested")
    try FileManager.default.createDirectory(
      at: include,
      withIntermediateDirectories: true
    )
    try "int a(void);".write(
      to: include.appendingPathComponent("a.h"),
      atomically: true,
      encoding: .utf8
    )
    try "int b(void);".write(
      to: include.deletingLastPathComponent().appendingPathComponent("b.h"),
      atomically: true,
      encoding: .utf8
    )

    let headers = root.appendingPathComponent("Headers")
    let map = try ModuleMaps.installClangHeaders(
      from: include.deletingLastPathComponent(),
      moduleName: "Loose",
      into: headers
    )
    #expect(map.contains("umbrella header \"Loose-umbrella.h\""))
    let umbrella = try String(
      contentsOf: headers.appendingPathComponent("Loose-umbrella.h"),
      encoding: .utf8
    )
    #expect(umbrella == "#include \"b.h\"\n#include \"nested/a.h\"\n")
  }
}

struct HeaderMergeTests {
  @Test func mergesOneBranchPerArchitecture() throws {
    func header(_ condition: String, _ body: String) -> String {
      "#if 0\n#elif \(condition)\n\(body)\n\n#else\n#error unsupported Swift architecture\n#endif\n"
    }
    let merged = try ArchitectureMerger.mergeObjCHeaders([
      header("defined(__arm64__) && __arm64__", "// arm"),
      header("defined(__x86_64__) && __x86_64__", "// intel")
    ])
    #expect(merged == """
      #if 0
      #elif defined(__arm64__) && __arm64__
      // arm

      #elif defined(__x86_64__) && __x86_64__
      // intel

      #else
      #error unsupported Swift architecture
      #endif

      """)
  }

  @Test func rejectsUnexpectedLayout() {
    #expect(throws: MakerError.self) {
      try ArchitectureMerger.mergeObjCHeaders(["// plain header"]) }
  }
}

struct BinaryManifestTests {
  @Test func rendersLocalAndRemoteTargets() throws {
    let manifest = try BinaryManifest.render(
      packageName: "Demo",
      platforms: platforms(
        #"[{"platformName":"ios","version":"15.0"},{"platformName":"linux","version":"0.0"}]"#
      ),
      products: [.init(name: "Demo", modules: ["Demo", "Core"])],
      artifacts: [
        ("Core", .path("XCFrameworks/Core.xcframework")),
        (
          "Demo",
          .remote(url: "https://example.com/Demo.xcframework.zip", checksum: "abc")
        )
      ]
    )
    #expect(manifest.contains(#"platforms: [.iOS("15.0")],"#))
    #expect(manifest.contains(#".library(name: "Demo", targets: ["Demo", "Core"]),"#))
    #expect(manifest
      .contains(#".binaryTarget(name: "Core", path: "XCFrameworks/Core.xcframework"),"#))
    #expect(manifest.contains(#"url: "https://example.com/Demo.xcframework.zip","#))
    #expect(manifest.contains(#"checksum: "abc""#))
  }
}

struct ResourceCarrierTests {
  @Test func rendersCarrierTargetAndRenamesBinaryTarget() {
    let carrier = ResourceCarrier(module: "Kit", resources: [
      .init(path: "Resources", rule: .process),
      .init(path: "Raw", rule: .copy),
      .init(path: "en.lproj", rule: .process, localization: "default")
    ])
    let manifest = BinaryManifest.render(
      packageName: "Kit",
      platforms: [],
      products: [.init(name: "Kit", modules: ["Kit", "Core"])],
      artifacts: [
        ("Core", .path("XCFrameworks/Core.xcframework")),
        ("Kit", .path("XCFrameworks/Kit.xcframework"))
      ],
      defaultLocalization: "en",
      resourceCarriers: [carrier]
    )
    #expect(manifest.contains(#"defaultLocalization: "en","#))
    #expect(manifest.contains(#"targets: ["KitBinary", "Kit", "Core"]"#))
    #expect(manifest
      .contains(
        #".binaryTarget(name: "KitBinary", path: "XCFrameworks/Kit.xcframework"),"#
      ))
    #expect(manifest
      .contains(#".binaryTarget(name: "Core", path: "XCFrameworks/Core.xcframework"),"#))
    #expect(manifest.contains(#"path: "Resources/Kit","#))
    let resources = #"resources: [.process("Resources"), .copy("Raw"), "#
      + #".process("en.lproj", localization: .default)],"#
    #expect(manifest.contains(resources))
  }

  @Test func copiesDeclaredAndImplicitResources() throws {
    let work = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("Sources/Kit")
    for path in ["Resources/a.json", "Media.xcassets/Contents.json", "Kit.swift"] {
      let url = source.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try "{}".write(to: url, atomically: true, encoding: .utf8)
    }
    let target =
      try decodeTarget(resources: #"[{"path":"Resources","rule":{"process":{}}}]"#)
    let output = work.appendingPathComponent("Binary")

    let carrier = try #require(try ResourceCarrier.make(
      module: "Kit",
      target: target,
      sourceDirectory: source,
      packageDirectory: output
    ))
    #expect(carrier.resources.map(\.path) == ["Resources", "Media.xcassets"])
    let folder = output.appendingPathComponent("Resources/Kit")
    let expected = [
      "Resources/a.json",
      "Media.xcassets/Contents.json",
      "resources.c",
      "include/module.modulemap"
    ]
    for path in expected {
      #expect(FileManager.default
        .fileExists(atPath: folder.appendingPathComponent(path).path))
    }
    let swiftFile = folder.appendingPathComponent("Kit.swift").path
    #expect(!FileManager.default.fileExists(atPath: swiftFile))
  }

  @Test func scanSkipsExcludedHiddenAndNestedFolders() throws {
    let work = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    for path in [
      "Assets.xcassets/Contents.json",
      "Ignored/Stray.xcassets/Contents.json",
      ".hidden/View.xib",
      "Nested/Other.xcassets/Contents.json"
    ] {
      try writeFile(work.appendingPathComponent(path))
    }
    let carrier = try #require(try ResourceCarrier.make(
      module: "Kit",
      target: decodeTarget(resources: "[]"),
      sourceDirectory: work,
      packageDirectory: work.appendingPathComponent("Binary"),
      foreignDirectories: [
        work.appendingPathComponent("Ignored"),
        work.appendingPathComponent("Nested")
      ]
    ))
    #expect(carrier.resources.map(\.path) == ["Assets.xcassets"])
  }

  @Test func resolvedResourcesBecomeRelativeToTheTarget() throws {
    let work = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("Lib/Kit")
    try writeFile(source.appendingPathComponent("Resources/a.json"))
    try writeFile(source.appendingPathComponent("raw.bin"))
    let resolved: [PackageManifest.Resource] = [
      .init(path: source.appendingPathComponent("Resources/a.json").path, rule: .process),
      .init(path: source.appendingPathComponent("raw.bin").path, rule: .copy),
      .init(path: source.appendingPathComponent("embedded.txt").path, rule: .embedInCode),
      .init(path: work.appendingPathComponent("outside.json").path, rule: .process)
    ]
    let carrier = try #require(try ResourceCarrier.make(
      module: "Kit",
      target: decodeTarget(resources: "[]"),
      sourceDirectory: source,
      packageDirectory: work.appendingPathComponent("Binary"),
      resolved: resolved
    ))
    #expect(carrier.resources == [
      .init(path: "Resources/a.json", rule: .process),
      .init(path: "raw.bin", rule: .copy)
    ])
  }

  @Test func noCarrierWithoutResources() throws {
    let work = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    let carrier = try ResourceCarrier.make(
      module: "Kit",
      target: decodeTarget(resources: "[]"),
      sourceDirectory: work,
      packageDirectory: work.appendingPathComponent("Binary")
    )
    #expect(carrier == nil)
  }

  private func writeFile(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "{}".write(to: url, atomically: true, encoding: .utf8)
  }

  private func decodeTarget(resources: String) throws -> PackageManifest.Target {
    let json = #"{"name":"Kit","type":"regular","path":null,"publicHeadersPath":null,"#
      + #""resources":\#(resources)}"#
    return try JSONDecoder().decode(PackageManifest.Target.self, from: Data(json.utf8))
  }
}

struct PackageMetadataTests {
  @Test func moduleNames() {
    #expect(moduleName(forTarget: "Demo") == "Demo")
    #expect(moduleName(forTarget: "my-lib") == "my_lib")
    #expect(moduleName(forTarget: "1st") == "_1st")
  }

  @Test func decodesDumpPackageOutput() throws {
    let json = #"""
      {"name":"Demo","platforms":[{"platformName":"ios","version":"15.0","options":[]}],
       "products":[{"name":"Demo","targets":["Demo"],"type":{"library":["automatic"]},"settings":[]},
                   {"name":"tool","targets":["Tool"],"type":{"executable":null},"settings":[]}],
       "targets":[{"name":"Demo","type":"regular","path":null,"publicHeadersPath":null,"dependencies":[]},
                  {"name":"Tool","type":"executable","path":"Sources/Tool","publicHeadersPath":null,"dependencies":[]}]}
      """#
    let manifest = try JSONDecoder().decode(PackageManifest.self, from: Data(json.utf8))
    #expect(manifest.libraryProducts.map(\.name) == ["Demo"])
    #expect(manifest.targets.filter(\.isLibrary).map(\.name) == ["Demo"])
  }
}

struct DynamicLinkingTests {
  @Test func resolvesTargetAndProductDependencies() throws {
    let index = try index()
    #expect(index.directDependencies(of: "Kit") == ["KitCore", "Remote"])
    #expect(index.directDependencies(of: "kit_tool") == ["KitCore"])
    #expect(index.directDependencies(of: "RemoteCore") == ["RemoteSQLite"])
  }

  @Test func findsSystemLibrariesInTheDependencyClosure() throws {
    let index = try index()
    // Kit reaches RemoteSQLite through the Remote product and RemoteCore.
    #expect(index.systemLibraries(usedBy: ["Kit"]) == ["RemoteSQLite"])
    #expect(index.systemLibraries(usedBy: ["KitCore"]) == [])
    #expect(index.entries["RemoteSQLite"]?.target.isSystemLibrary == true)
  }

  @Test func ordersDependenciesFirstWithTransitiveClosure() throws {
    let order = try index().linkOrder(of: ["Kit", "KitCore", "Remote", "RemoteCore"])
    #expect(order.map(\.module) == ["KitCore", "RemoteCore", "Remote", "Kit"])
    #expect(order.last?.dependencies == ["KitCore", "Remote", "RemoteCore"])
  }

  @Test func reachesDependenciesThroughModulesNotBuilt() throws {
    // Remote wasn't built for this platform; Kit still links RemoteCore.
    let order = try index().linkOrder(of: ["Kit", "RemoteCore"])
    #expect(order.map(\.module) == ["RemoteCore", "Kit"])
    #expect(order.last?.dependencies == ["RemoteCore"])
  }

  @Test func readsLinkedFrameworksAndLibrariesPerPlatform() throws {
    let kit = try #require(index().entries["Kit"]?.target)
    #expect(kit.linkedLibraries.count == 2)
    let ios = kit.linkedLibraries.flatMap { $0.arguments(for: .iOSSimulator) }
    #expect(ios == ["-framework", "UIKit", "-lz"])
    #expect(kit.linkedLibraries.flatMap { $0.arguments(for: .macOS) } == ["-lz"])
  }

  @Test func minimumOSVersionOnlyOutsideMacOS() throws {
    let assembler = FrameworkAssembler(
      shell: Shell(),
      bundleIdentifierPrefix: "test",
      version: "1.0.0",
      linkage: .dynamic
    )
    func plist(_ platform: ApplePlatform) throws -> [String: Any] {
      let data = try assembler.infoPlist(
        for: "Kit",
        platform: platform,
        minimumOSVersion: "15.0"
      )
      return try #require(
        PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
      )
    }
    #expect(try plist(.iOS)["MinimumOSVersion"] as? String == "15.0")
    #expect(try plist(.macOS)["MinimumOSVersion"] == nil)
  }

  @Test func passesOnlyLinkerFlagsToTheDylibLink() {
    let maker = Maker(options: MakerOptions(
      packageDirectory: URL(fileURLWithPath: "/p"),
      outputDirectory: URL(fileURLWithPath: "/o")
    ))
    let arguments = ["-Xswiftc", "-Xlinker", "-Xlinker", "-x", "-Xcc", "-DX"]
    #expect(maker.linkerFlags(in: arguments) == ["-Xlinker", "-x"])
  }

  @Test(arguments: [true, false])
  func libraryEvolutionIsOptional(libraryEvolution: Bool) throws {
    let swiftPM = SwiftPM(
      packageDirectory: URL(fileURLWithPath: "/p"),
      scratchDirectory: URL(fileURLWithPath: "/s"),
      shell: Shell()
    )
    let request = SwiftPM.BuildRequest(
      platform: .macOS,
      architecture: "arm64",
      deploymentTarget: nil,
      configuration: "release",
      verifyModuleInterfaces: false,
      libraryEvolution: libraryEvolution,
      extraArguments: []
    )
    let arguments = try swiftPM.buildArguments(for: request)
    #expect(arguments.contains("-enable-library-evolution") == libraryEvolution)
    // Interfaces need library evolution; without it the compiler only warns about them.
    #expect(arguments.contains("--enable-parseable-module-interfaces") == libraryEvolution)
    #expect(arguments.contains("-no-verify-emitted-module-interface") == libraryEvolution)
  }

  /// Kit depends on KitCore and on Remote's `RemoteLib` product, which pulls in
  /// RemoteCore; KitTool is a plain dependency of nothing.
  private func index() throws -> TargetIndex {
    let kit = #"""
      {"name":"Kit","platforms":[],
       "products":[{"name":"Kit","targets":["Kit"],"type":{"library":["automatic"]}}],
       "targets":[
         {"name":"Kit","type":"regular","dependencies":[
           {"byName":["KitCore",null]},{"product":["RemoteLib","remote",null,null]}],
          "settings":[
           {"tool":"linker","kind":{"linkedFramework":{"_0":"UIKit"}},
            "condition":{"platformNames":["ios"]}},
           {"tool":"linker","kind":{"linkedLibrary":{"_0":"z"}}},
           {"tool":"linker","kind":{"unsafeFlags":{"_0":["-Wl,-x"]}}},
           {"tool":"swift","kind":{"define":{"_0":"KIT"}}}]},
         {"name":"KitCore","type":"regular","dependencies":[]},
         {"name":"kit-tool","type":"regular","dependencies":[{"target":["KitCore",null]}]}]}
      """#
    let remote = #"""
      {"name":"Remote","platforms":[],
       "products":[{"name":"RemoteLib","targets":["Remote"],"type":{"library":["automatic"]}}],
       "targets":[
         {"name":"Remote","type":"regular","dependencies":[{"byName":["RemoteCore",null]}]},
         {"name":"RemoteCore","type":"regular","dependencies":[{"target":["RemoteSQLite",null]}]},
         {"name":"RemoteSQLite","type":"system"}]}
      """#
    func package(_ identity: String, _ json: String) throws -> ResolvedPackage {
      try ResolvedPackage(
        identity: identity,
        directory: URL(fileURLWithPath: "/\(identity)"),
        manifest: JSONDecoder().decode(PackageManifest.self, from: Data(json.utf8))
      )
    }
    return try TargetIndex(packages: [package("kit", kit), package("remote", remote)])
  }
}

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("packable-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

struct ShellErrorTests {
  @Test func showsOnlyErrorLinesClipped() {
    let noise = String(repeating: "x", count: 1000)
    let output = """
      Building for production...
      Foo.swift:1:1: error: cannot find 'bar' in scope
      \(noise) error: frontend failed
      Foo.swift:1:1: error: cannot find 'bar' in scope
      """
    let error = ShellError(command: ["swift", "build"], status: 1, output: output)
    let lines = error.description.split(separator: "\n").map(String.init)
    #expect(lines.count == 3)
    #expect(lines[0] == "Command failed (exit 1): swift build")
    #expect(lines[1] == "Foo.swift:1:1: error: cannot find 'bar' in scope")
    #expect(lines[2].count == 401)
  }

  @Test func fallsBackToTailWithoutErrorLines() {
    let output = (1 ... 50).map { "line \($0)" }.joined(separator: "\n")
    let error = ShellError(command: ["tool"], status: 2, output: output)
    let lines = error.description.split(separator: "\n")
    #expect(lines.count == 41)
    #expect(lines.last == "line 50")
  }
}

struct BuildChecksumTests {
  func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  func checksum(_ package: URL, settings: [String] = [], excluding: [URL] = []) -> String {
    BuildChecksum.compute(
      packages: [("kit", package)],
      settings: settings,
      excluding: excluding
    )
  }

  @Test func followsContentsNotModificationDates() throws {
    let work = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    let source = work.appendingPathComponent("Sources/Kit/Kit.swift")
    try write("let a = 1", to: source)
    let original = checksum(work)

    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 0)],
      ofItemAtPath: source.path
    )
    #expect(checksum(work) == original)

    try write("let a = 2", to: source)
    #expect(checksum(work) != original)
  }

  @Test func ignoresBuildFoldersAndExcludedDirectories() throws {
    let work = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    try write("let a = 1", to: work.appendingPathComponent("Sources/Kit/Kit.swift"))
    let output = work.appendingPathComponent("Output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let original = checksum(work, excluding: [output])

    try write("x", to: work.appendingPathComponent(".build/debug/x.o"))
    try write("x", to: work.appendingPathComponent(".git/HEAD"))
    try write("x", to: output.appendingPathComponent("Package.swift"))
    #expect(checksum(work, excluding: [output]) == original)

    try write("x", to: work.appendingPathComponent("Sources/Kit/New.swift"))
    #expect(checksum(work, excluding: [output]) != original)
  }

  @Test func includesSettingsAndEveryPackage() throws {
    let work = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    let kit = work.appendingPathComponent("Kit")
    let dependency = work.appendingPathComponent("Dependency")
    try write("let a = 1", to: kit.appendingPathComponent("Kit.swift"))
    try write("let b = 1", to: dependency.appendingPathComponent("Dependency.swift"))
    func both(_ settings: [String] = []) -> String {
      BuildChecksum.compute(
        packages: [("kit", kit), ("dependency", dependency)],
        settings: settings
      )
    }
    let original = both()
    #expect(both(["linkage:dynamic"]) != original)

    try write("let b = 2", to: dependency.appendingPathComponent("Dependency.swift"))
    #expect(both() != original)
  }
}

struct CanonicalPathTests {
  /// File paths on macOS ignore case, and a folder that doesn't exist yet must compare
  /// the same way as its existing parent.
  @Test func matchesMissingPathsUnderAnExistingFolderTypedInAnotherCase() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Scratch")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let typed = root.appendingPathComponent("scratch")
    let missing = typed.appendingPathComponent("out/Products")
    #expect(canonicalPath(missing).hasPrefix(canonicalPath(folder) + "/"))
    #expect(canonicalPath(missing).hasSuffix("/Scratch/out/Products"))
  }
}

struct ScratchSeedTests {
  /// A package's `.build` after `swift package resolve`: checkouts, the bare repositories
  /// they came from, a downloaded artifact, and SwiftPM's state pointing at it.
  private func resolvedPackage(in root: URL) throws -> URL {
    let build = root.appendingPathComponent("Pkg/.build")
    for file in ["checkouts/dep/Package.swift", "repositories/dep-1234/HEAD",
                 "artifacts/dep/tool/tool.artifactbundle/info.json"] {
      let url = build.appendingPathComponent(file)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try file.write(to: url, atomically: true, encoding: .utf8)
    }
    let state = """
      {"object":{"artifacts":[{"path":"\(build.path)/artifacts/dep/tool/tool.artifactbundle",\
      "targetName":"tool"}],"dependencies":[{"subpath":"dep"}],"prebuilts":[]},"version":7}
      """
    try state.write(
      to: build.appendingPathComponent("workspace-state.json"),
      atomically: true,
      encoding: .utf8
    )
    return build.deletingLastPathComponent()
  }

  @Test func clonesResolvedDependenciesIntoAnEmptyScratchFolder() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let package = try resolvedPackage(in: root)
    let scratch = package.appendingPathComponent(".build/packable")

    let seed = ScratchSeed(packageDirectory: package, scratchDirectory: scratch, shell: Shell())
    #expect(seed.plant())

    for file in ["checkouts/dep/Package.swift", "repositories/dep-1234/HEAD",
                 "artifacts/dep/tool/tool.artifactbundle/info.json"] {
      #expect(FileManager.default.fileExists(atPath: scratch.appendingPathComponent(file).path))
    }
    let state = try String(
      contentsOf: scratch.appendingPathComponent("workspace-state.json"),
      encoding: .utf8
    )
    // Artifacts point into the scratch folder, not the package's own .build.
    #expect(state.contains("\"\(scratch.path)/artifacts/dep/tool/tool.artifactbundle\""))
    #expect(state.contains(#""subpath" : "dep""#))
  }

  @Test func leavesAnAlreadyResolvedScratchFolderAlone() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let package = try resolvedPackage(in: root)
    let scratch = root.appendingPathComponent("scratch")
    try FileManager.default.createDirectory(
      at: scratch.appendingPathComponent("checkouts"),
      withIntermediateDirectories: true
    )

    let seed = ScratchSeed(packageDirectory: package, scratchDirectory: scratch, shell: Shell())
    #expect(!seed.plant())
    #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent("repositories").path))
  }

  @Test func doesNothingWithoutResolvedDependenciesOrWhenScratchIsBuild() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let empty = root.appendingPathComponent("Empty")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let scratch = empty.appendingPathComponent(".build/packable")
    #expect(!ScratchSeed(packageDirectory: empty, scratchDirectory: scratch, shell: Shell()).plant())

    let package = try resolvedPackage(in: root)
    let build = package.appendingPathComponent(".build")
    #expect(!ScratchSeed(packageDirectory: package, scratchDirectory: build, shell: Shell()).plant())
  }

  @Test func removesWhatItPlanted() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let package = try resolvedPackage(in: root)
    let scratch = root.appendingPathComponent("scratch")
    let seed = ScratchSeed(packageDirectory: package, scratchDirectory: scratch, shell: Shell())
    #expect(seed.plant())
    seed.remove()
    for item in ScratchSeed.items + ["workspace-state.json"] {
      #expect(!FileManager.default.fileExists(atPath: scratch.appendingPathComponent(item).path))
    }
    // The package's own .build is untouched.
    #expect(FileManager.default.fileExists(
      atPath: package.appendingPathComponent(".build/checkouts/dep/Package.swift").path
    ))
  }
}

struct UnusedModuleTests {
  /// Swift Build's layout for one build: objects in `Products`, dependency scans in
  /// `Intermediates.noindex`. App imports Used; Marker and Code aren't imported.
  private func build(in root: URL, scanApp: Bool = true) throws
    -> (BuildProductsDirectory, [BuiltModule], TargetIndex) {
    let products = root.appendingPathComponent("out/Products/Release")
    try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
    let shell = Shell()
    func object(_ name: String, source: String) throws -> URL {
      let c = root.appendingPathComponent("\(name).c")
      try source.write(to: c, atomically: true, encoding: .utf8)
      let o = products.appendingPathComponent("\(name).o")
      try shell.run(["xcrun", "clang", "-c", c.path, "-o", o.path], stream: false)
      return o
    }
    let modules = try [
      ("App", "int app(void) { return 1; }"),
      ("Used", ""),
      ("Marker", ""),
      ("Code", "int code(void) { return 2; }")
    ].map { name, source in
      try BuiltModule(
        name: name,
        object: object(name, source: source),
        kind: .swift(swiftmodule: products.appendingPathComponent("\(name).swiftmodule"), objcHeader: nil),
        resourceBundle: nil
      )
    }
    for (module, imports) in [("App", ["Used", "Swift"]), ("Used", ["Swift"]),
                              ("Marker", ["Swift"]), ("Code", ["Swift"])]
      where scanApp || module != "App" {
      let objects = root.appendingPathComponent(
        "out/Intermediates.noindex/pkg.build/Release/\(module)-t.build/Objects-normal/arm64"
      )
      try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
      let json = "[" + imports.map { #"{"moduleName":"\#($0)","isFramework":false}"# }
        .joined(separator: ",") + "]"
      try json.write(
        to: objects.appendingPathComponent("\(module)-dependencies-1.json"),
        atomically: true,
        encoding: .utf8
      )
    }
    let manifest = #"""
      {"name":"Pkg","platforms":[],"products":[],
       "targets":[{"name":"App","type":"regular"},{"name":"Used","type":"regular"},
                  {"name":"Marker","type":"regular"},{"name":"Code","type":"regular"}]}
      """#
    let index = try TargetIndex(packages: [ResolvedPackage(
      identity: "pkg",
      directory: root,
      manifest: JSONDecoder().decode(PackageManifest.self, from: Data(manifest.utf8))
    )])
    return (BuildProductsDirectory(url: products), modules, index)
  }

  @Test func dropsOnlyEmptyModulesNothingImports() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (directory, modules, index) = try build(in: root)
    let unused = try directory.unusedEmptyModules(
      modules,
      keeping: ["App"],
      index: index,
      architecture: "arm64",
      shell: Shell()
    )
    #expect(unused == ["Marker"])
  }

  @Test func keepsEverythingWhenAScanIsMissing() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (directory, modules, index) = try build(in: root, scanApp: false)
    let unused = try directory.unusedEmptyModules(
      modules,
      keeping: ["App"],
      index: index,
      architecture: "arm64",
      shell: Shell()
    )
    #expect(unused.isEmpty)
  }
}
