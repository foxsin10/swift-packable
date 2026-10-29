import Foundation
import Testing
@testable import XcframeworkPackableKit

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

func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("xcframework-packable-tests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
