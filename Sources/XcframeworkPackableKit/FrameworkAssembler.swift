import Foundation

/// Packs one `BuiltModule` into a static `.framework` bundle for one platform.
public struct FrameworkAssembler: Sendable {
  public init(shell: Shell, bundleIdentifierPrefix: String, version: String) {
    self.shell = shell
    self.bundleIdentifierPrefix = bundleIdentifierPrefix
    self.version = version
  }

  public let shell: Shell
  public let bundleIdentifierPrefix: String
  public let version: String

  /// Creates `<directory>/<Name>.framework`, replacing any previous one.
  @discardableResult
  public func assemble(
    _ module: BuiltModule,
    platform: ApplePlatform,
    in directory: URL
  ) throws -> URL {
    let fileManager = FileManager.default
    let framework = directory.appendingPathComponent("\(module.name).framework")
    try? fileManager.removeItem(at: framework)

    // Versioned layout puts everything in Versions/A and links it from the bundle root.
    let content = platform.usesVersionedBundleLayout
      ? framework.appendingPathComponent("Versions/A")
      : framework
    let resources = platform.usesVersionedBundleLayout
      ? content.appendingPathComponent("Resources")
      : content
    try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

    let binary = content.appendingPathComponent(module.name)
    let libtool = ["libtool", "-static", "-D", "-no_warning_for_no_symbols"]
    try shell.run(libtool + ["-o", binary.path, module.object.path], stream: false)

    let headers = content.appendingPathComponent("Headers")
    let modules = content.appendingPathComponent("Modules")
    try fileManager.createDirectory(at: modules, withIntermediateDirectories: true)

    switch module.kind {
    case let .swift(swiftmodule, objcHeader):
      try copySwiftModule(
        swiftmodule,
        to: modules.appendingPathComponent("\(module.name).swiftmodule")
      )
      if let objcHeader {
        try fileManager.createDirectory(at: headers, withIntermediateDirectories: true)
        try fileManager.copyItem(
          at: objcHeader,
          to: headers.appendingPathComponent(objcHeader.lastPathComponent)
        )
        try ModuleMaps.swiftModuleMap(
          name: module.name,
          objcHeader: objcHeader.lastPathComponent
        )
        .write(
          to: modules.appendingPathComponent("module.modulemap"),
          atomically: true,
          encoding: .utf8
        )
      }
    case let .clang(publicHeaders):
      if let publicHeaders {
        let moduleMap = try ModuleMaps.installClangHeaders(
          from: publicHeaders,
          moduleName: module.name,
          into: headers
        )
        try moduleMap.write(
          to: modules.appendingPathComponent("module.modulemap"),
          atomically: true,
          encoding: .utf8
        )
      }
    }

    if let bundle = module.resourceBundle {
      try fileManager.copyItem(
        at: bundle,
        to: resources.appendingPathComponent(bundle.lastPathComponent)
      )
    }

    try infoPlist(for: module.name, platform: platform)
      .write(to: resources.appendingPathComponent("Info.plist"))

    if platform.usesVersionedBundleLayout {
      try linkVersionedLayout(framework: framework, executable: module.name)
    }
    return framework
  }

  func infoPlist(for name: String, platform: ApplePlatform) throws -> Data {
    let identifierSuffix = String(name.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    let plist: [String: Any] = [
      "CFBundleDevelopmentRegion": "en",
      "CFBundleExecutable": name,
      "CFBundleIdentifier": "\(bundleIdentifierPrefix).\(identifierSuffix)",
      "CFBundleInfoDictionaryVersion": "6.0",
      "CFBundleName": name,
      "CFBundlePackageType": "FMWK",
      "CFBundleShortVersionString": version,
      "CFBundleVersion": version,
      "CFBundleSupportedPlatforms": [platform.supportedPlatformName]
    ]
    return try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
  }

  /// Copies the module's interfaces, docs and binary module, leaving out what
  /// shouldn't ship: `package` interfaces and the `Project` source-info folder.
  private func copySwiftModule(_ source: URL, to destination: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
    for file in try fileManager.contentsOfDirectory(atPath: source.path) {
      guard file != "Project",
            !file.hasSuffix(".package.swiftinterface") else {
        continue
      }
      try fileManager.copyItem(
        at: source.appendingPathComponent(file),
        to: destination.appendingPathComponent(file)
      )
    }
  }

  private func linkVersionedLayout(framework: URL, executable: String) throws {
    let fileManager = FileManager.default
    try fileManager.createSymbolicLink(
      atPath: framework.appendingPathComponent("Versions/Current").path,
      withDestinationPath: "A"
    )
    let current = framework.appendingPathComponent("Versions/A")
    for entry in [executable, "Headers", "Modules", "Resources"]
      where fileManager.fileExists(atPath: current.appendingPathComponent(entry).path) {
      try fileManager.createSymbolicLink(
        atPath: framework.appendingPathComponent(entry).path,
        withDestinationPath: "Versions/Current/\(entry)"
      )
    }
  }
}

/// Clang module maps for framework bundles.
public enum ModuleMaps {
  public static func swiftModuleMap(name: String, objcHeader: String) -> String {
    """
    framework module \(name) {
        header "\(objcHeader)"
        requires objc
    }

    """
  }

  /// Copies a C target's public headers into `headersDirectory` and returns the framework
  /// module map.
  ///
  /// Mirrors SwiftPM's rules: a custom `module.modulemap` is kept as a framework module,
  /// `include/<Name>.h` or `include/<Name>/<Name>.h` becomes the umbrella header, and
  /// otherwise an umbrella header that includes every public header is generated.
  public static func installClangHeaders(
    from publicHeaders: URL,
    moduleName: String,
    into headersDirectory: URL
  ) throws -> String {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: headersDirectory.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? fileManager.removeItem(at: headersDirectory)
    try fileManager.copyItem(at: publicHeaders, to: headersDirectory)

    let customMap = headersDirectory.appendingPathComponent("module.modulemap")
    if fileManager.fileExists(atPath: customMap.path) {
      let contents = try String(contentsOf: customMap, encoding: .utf8)
      try fileManager.removeItem(at: customMap)
      return frameworkModuleMap(fromCustom: contents)
    }

    let headers = headerFiles(in: headersDirectory)
    let umbrella: String
    // SwiftPM matches the umbrella header case-insensitively (default macOS file system).
    let candidates = ["\(moduleName).h", "\(moduleName)/\(moduleName).h"]
      .map { $0.lowercased() }
    if let existing = headers.first(where: { candidates.contains($0.lowercased()) }) {
      umbrella = existing
    } else {
      umbrella = "\(moduleName)-umbrella.h"
      let includes = headers.map { "#include \"\($0)\"" }.joined(separator: "\n")
      try (includes + "\n").write(
        to: headersDirectory.appendingPathComponent(umbrella),
        atomically: true,
        encoding: .utf8
      )
    }
    return """
      framework module \(moduleName) {
          umbrella header "\(umbrella)"
          export *
          module * { export * }
      }

      """
  }

  /// Turns top-level `module X` declarations into `framework module X`.
  public static func frameworkModuleMap(fromCustom contents: String) -> String {
    contents.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      line.hasPrefix("module ") ? "framework " + line : String(line)
    }.joined(separator: "\n")
  }

  /// Header paths relative to `directory`, sorted.
  static func headerFiles(in directory: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
      return []
    }
    return enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".h") }.sorted()
  }
}
