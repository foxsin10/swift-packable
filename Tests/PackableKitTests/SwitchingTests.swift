import Foundation
@testable import PackableKit
import Testing

struct PackableConfigTests {
  @Test func parsesModesLocationsAndDefaults() throws {
    let config = try PackableConfig.parse("""
      dependencies:
        Kit:
          mode: binary
          source: { path: ../Kit }
          binary: { url: https://example.com/kit-binary.git, exact: 1.0.0 }
          products: [Kit]
          platforms: [ios, ios-simulator]
          skip-interface-verification: true
          linkage: dynamic
        Remote:
          source: { url: https://github.com/org/Remote.git, up-to-next-minor: 2.1.0 }
      """)
    #expect(config.names == ["Kit", "Remote"])
    let kit = try #require(config.dependencies["Kit"])
    #expect(kit.mode == .binary)
    #expect(kit.binary?.packageName == "kit-binary")
    #expect(kit.products == ["Kit"])
    #expect(kit.skipInterfaceVerification)
    #expect(kit.linkage == .dynamic)
    let remote = try #require(config.dependencies["Remote"])
    #expect(remote.mode == .source)
    #expect(remote.linkage == .static)
    #expect(remote.source.packageName == "Remote")
    #expect(remote.source.requirementArguments == ".upToNextMinor(from: \"2.1.0\")")
  }

  @Test(arguments: [
    "source: { path: ../Kit, from: 1.0.0 }",
    "source: { url: https://example.com/kit.git }",
    "source: { url: https://example.com/kit.git, from: 1.0.0, exact: 1.0.0 }",
    "source: { }"
  ])
  func rejectsInvalidLocations(location: String) {
    #expect(throws: MakerError.self) {
      try PackableConfig.parse("dependencies:\n  Kit:\n    \(location)\n")
    }
  }

  @Test func relativePaths() {
    let base = URL(fileURLWithPath: "/work/App")
    #expect(relativePath(to: URL(fileURLWithPath: "/work/Kit"), from: base) == "../Kit")
    #expect(relativePath(to: URL(fileURLWithPath: "/work/App/Vendor/Kit"), from: base) ==
      "Vendor/Kit")
    #expect(relativePath(to: URL(fileURLWithPath: "/elsewhere/Kit"), from: base) ==
      "/elsewhere/Kit")
  }
}

struct ConfigEditorTests {
  let yaml = """
    # Comment kept
    dependencies:
      Kit:
        mode: source   # trailing comment kept
        source: { path: ../Kit }
      Other:
        source: { path: ../Other }
    """

  @Test func replacesExistingModeKeepingComments() throws {
    let edited = try ConfigEditor.setMode(.binary, for: "Kit", in: yaml)
    #expect(edited.contains("    mode: binary # trailing comment kept"))
    #expect(edited.hasPrefix("# Comment kept"))
    #expect(try PackableConfig.parse(edited).dependencies["Kit"]?.mode == .binary)
  }

  @Test func insertsMissingMode() throws {
    let edited = try ConfigEditor.setMode(.binary, for: "Other", in: yaml)
    #expect(edited.contains("  Other:\n    mode: binary\n    source: { path: ../Other }"))
    #expect(try PackableConfig.parse(edited).dependencies["Other"]?.mode == .binary)
  }

  @Test func unknownDependencyFails() {
    #expect(throws: MakerError.self) {
      try ConfigEditor.setMode(.binary, for: "Missing", in: yaml)
    }
  }
}

struct ManifestBlockTests {
  let dependencies = [
    SwitchedDependency(
      name: "Kit",
      mode: .binary,
      packageExpression: ".package(path: packableCache + \"/Kit/local/Kit-binary\")",
      packageName: "Kit-binary"
    ),
    SwitchedDependency(
      name: "Remote",
      mode: .source,
      packageExpression: ".package(url: \"https://example.com/Remote.git\", from: \"1.0.0\")",
      packageName: "Remote"
    )
  ]

  @Test func rendersDependenciesAndHelper() {
    let block = ManifestBlock.render(dependencies, usesSharedCache: true)
    #expect(block.hasPrefix(ManifestBlock.beginMarker))
    #expect(block.hasSuffix(ManifestBlock.endMarker))
    #expect(block.contains("// Kit: binary, Remote: source"))
    #expect(block
      .contains(
        "let packableCache = Context.environment[\"PACKABLE_CACHE\"]"
      ))
    #expect(block.contains("  .package(path: packableCache + \"/Kit/local/Kit-binary\")"))
    #expect(block.contains("    \"Kit\": \"Kit-binary\""))
  }

  @Test func insertsAfterImportThenReplaces() throws {
    let manifest = "// swift-tools-version:5.9\nimport PackageDescription\n\nlet package = 1\n"
    let first = try ManifestBlock.splice(
      "// packable:begin\nA\n// packable:end",
      into: manifest
    )
    #expect(first ==
      "// swift-tools-version:5.9\nimport PackageDescription\n\n// packable:begin\nA\n// packable:end\n\nlet package = 1\n")
    let second = try ManifestBlock.splice(
      "// packable:begin\nB\n// packable:end",
      into: first
    )
    #expect(second == first.replacingOccurrences(of: "\nA\n", with: "\nB\n"))
  }

  @Test func rejectsHalfAMarkerPair() {
    #expect(throws: MakerError.self) {
      try ManifestBlock.splice("x", into: "import PackageDescription\n// packable:end\n")
    }
  }

  /// The generated block is Swift that the manifest compiles; check it type-checks.
  @Test func generatedBlockCompiles() throws {
    let work = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: work) }
    let block = ManifestBlock.render(dependencies, usesSharedCache: true)
    let manifest = try ManifestBlock.splice(block, into: """
      // swift-tools-version:5.9
      import PackageDescription

      let package = Package(
        name: "App",
        dependencies: packableDependencies,
        targets: [.target(name: "App", dependencies: [packable("Kit", from: "Kit")])]
      )
      """)
    let url = work.appendingPathComponent("Package.swift")
    try manifest.write(to: url, atomically: true, encoding: .utf8)
    try Shell().run(
      ["swift", "package", "--package-path", work.path, "dump-package"],
      stream: false
    )
  }
}
