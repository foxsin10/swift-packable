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
    #expect(index.directDependencies(of: "RemoteCore") == [])
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
         {"name":"RemoteCore","type":"regular"}]}
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
