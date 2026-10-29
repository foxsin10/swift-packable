import Foundation
import Testing
@testable import XcframeworkPackableKit

/// Packages the `Fixtures/Demo` package with SwiftPM, then builds and runs a client
/// package that depends on the generated binary package.
@Suite(.serialized) struct EndToEndTests {
  @Test(.timeLimit(.minutes(10)))
  func packagesFixtureAndClientRunsAgainstBinaries() throws {
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

    let result = try Maker(options: options, log: { _ in }).run()

    #expect(result.artifacts.keys.sorted() == ["CDemo", "Demo", "DemoCore", "DemoExtras"])
    #expect(result.products == [
      .init(name: "Demo", modules: ["Demo", "CDemo", "DemoCore"]),
      .init(name: "DemoExtras", modules: ["DemoExtras", "DemoCore"])
    ])
    #expect(result.checksums.count == 4)
    #expect(result.warnings.contains { $0.contains("Demo_DemoExtras.bundle") })

    // Universal macOS slice, merged -Swift.h, framework module map for the C target.
    let shell = Shell()
    let unzipped = work.appendingPathComponent("unzipped")
    for module in ["Demo", "CDemo"] {
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
      print(Demo.answer(), Greeter().greeting(), Extras.doubled(), cdemo_add(2, 3))
      """.write(
      to: client.appendingPathComponent("Sources/Client/main.swift"),
      atomically: true,
      encoding: .utf8
    )

    let scratch = ["--scratch-path", work.appendingPathComponent("client-scratch").path]
    let output = try shell.run(["swift", "run"] + scratch + ["Client"], in: client)
    #expect(output.trimmingCharacters(in: .whitespacesAndNewlines)
      .hasSuffix("42 answer=42 82 5"))

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
