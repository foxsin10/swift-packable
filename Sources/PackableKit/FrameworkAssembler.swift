import Foundation

/// How a module's code is packaged in its framework.
public enum Linkage: String, CaseIterable, Codable, Sendable {
  /// A static archive, linked into whatever links the framework.
  case `static`
  /// A dynamic library, embedded in the app and loaded at launch.
  case dynamic
}

/// Packs one `BuiltModule` into a `.framework` bundle for one platform.
public struct FrameworkAssembler: Sendable {
  public init(
    shell: Shell,
    bundleIdentifierPrefix: String,
    version: String,
    linkage: Linkage = .static,
    extraLinkerArguments: [String] = []
  ) {
    self.shell = shell
    self.bundleIdentifierPrefix = bundleIdentifierPrefix
    self.version = version
    self.linkage = linkage
    self.extraLinkerArguments = extraLinkerArguments
  }

  public let shell: Shell
  public let bundleIdentifierPrefix: String
  public let version: String
  public let linkage: Linkage
  /// Passed to the linker when linking a dynamic framework, e.g. `-Xlinker -x`.
  public let extraLinkerArguments: [String]

  /// Where `assemble` puts a dynamic framework's dSYM.
  public static func debugSymbols(of framework: URL) -> URL {
    framework.deletingLastPathComponent()
      .appendingPathComponent(framework.lastPathComponent + ".dSYM")
  }

  /// Creates `<directory>/<Name>.framework`, replacing any previous one.
  ///
  /// A dynamic framework is linked against `dependencies`, frameworks already assembled
  /// in `directory`, and against `linkerArguments` (`-framework X`, `-lY`).
  @discardableResult
  public func assemble(
    _ module: BuiltModule,
    platform: ApplePlatform,
    in directory: URL,
    dependencies: [String] = [],
    linkerArguments: [String] = []
  ) throws -> URL {
    let fileManager = FileManager.default
    let framework = directory.appendingPathComponent("\(module.name).framework")
    try? fileManager.removeItem(at: framework)
    try? fileManager.removeItem(at: Self.debugSymbols(of: framework))

    // Versioned layout puts everything in Versions/A and links it from the bundle root.
    let content = platform.usesVersionedBundleLayout
      ? framework.appendingPathComponent("Versions/A")
      : framework
    let resources = platform.usesVersionedBundleLayout
      ? content.appendingPathComponent("Resources")
      : content
    try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

    let binary = content.appendingPathComponent(module.name)
    var minimumOSVersion: String?
    switch linkage {
    case .static:
      if let archive = module.archive {
        try fileManager.copyItem(at: archive, to: binary)
      } else {
        let libtool = ["libtool", "-static", "-D", "-no_warning_for_no_symbols"]
        try shell.run(libtool + ["-o", binary.path, module.object.path], stream: false)
      }
    case .dynamic:
      minimumOSVersion = try linkDynamicLibrary(
        module,
        platform: platform,
        to: binary,
        frameworksDirectory: directory,
        dependencies: dependencies,
        linkerArguments: linkerArguments
      )
      // The object's debug map points at SwiftPM's intermediate objects, which hold the
      // DWARF; the dSYM keeps it once the build folder is gone.
      let dSYM = Self.debugSymbols(of: framework).path
      try shell.run(["xcrun", "dsymutil", binary.path, "-o", dSYM], stream: false)
    }

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
    case let .clang(publicHeaders, skipped):
      if let publicHeaders {
        let moduleMap = try ModuleMaps.installClangHeaders(
          from: publicHeaders,
          moduleName: module.name,
          into: headers,
          skipping: skipped
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

    try infoPlist(
      for: module.name,
      platform: platform,
      minimumOSVersion: minimumOSVersion
    )
    .write(to: resources.appendingPathComponent("Info.plist"))

    if platform.usesVersionedBundleLayout {
      try linkVersionedLayout(framework: framework, executable: module.name)
    }
    return framework
  }

  func infoPlist(
    for name: String,
    platform: ApplePlatform,
    minimumOSVersion: String? = nil
  ) throws -> Data {
    let identifierSuffix = String(name.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    var plist: [String: Any] = [
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
    // App Store validation requires it in embedded frameworks; macOS doesn't use it.
    if let minimumOSVersion, !platform.usesVersionedBundleLayout {
      plist["MinimumOSVersion"] = minimumOSVersion
    }
    return try PropertyListSerialization.data(
      fromPropertyList: plist,
      format: .xml,
      options: 0
    )
  }

  /// Links the module's object into a dylib, one architecture at a time (each needs its
  /// own target triple), and merges the slices. Returns the deployment target the object
  /// was compiled for.
  private func linkDynamicLibrary(
    _ module: BuiltModule,
    platform: ApplePlatform,
    to binary: URL,
    frameworksDirectory: URL,
    dependencies: [String],
    linkerArguments: [String]
  ) throws -> String {
    let name = module.name
    let installName = platform.usesVersionedBundleLayout
      ? "@rpath/\(name).framework/Versions/A/\(name)"
      : "@rpath/\(name).framework/\(name)"
    // swiftc adds the Swift runtime and its back-deployment libraries; a C module has
    // neither, so it links with clang.
    let driver = switch module.kind {
    case .swift: ["swiftc", "-emit-library"]
    case .clang: ["clang", "-dynamiclib"]
    }
    let architectures = try shell.run(
      ["lipo", "-archs", module.object.path],
      stream: false
    )
    .split(whereSeparator: \.isWhitespace).map(String.init)
    let slicesDirectory = frameworksDirectory
      .appendingPathComponent("dylibs/\(name)")
    try? FileManager.default.removeItem(at: slicesDirectory)
    try FileManager.default.createDirectory(
      at: slicesDirectory,
      withIntermediateDirectories: true
    )

    var minimumOSVersion = ""
    var slices: [String] = []
    for architecture in architectures {
      minimumOSVersion = try deploymentTarget(
        of: module.object,
        architecture: architecture
      )
      let slice = slicesDirectory.appendingPathComponent(architecture).path
      let command = ["xcrun", "--sdk", platform.sdkName] + driver + [
        "-target", platform.triple(
          architecture: architecture,
          deploymentTarget: minimumOSVersion
        ),
        module.object.path,
        "-o", slice,
        "-F", frameworksDirectory.path,
        "-Xlinker", "-install_name", "-Xlinker", installName,
        // Libraries the object doesn't use are dropped, so listing extra ones is safe.
        "-Xlinker", "-dead_strip_dylibs",
        "-lc++"
      ] + dependencies.flatMap { ["-framework", $0] } + linkerArguments
        + extraLinkerArguments
      do {
        try shell.run(command, stream: false)
      } catch let error as ShellError where error.output.contains("Undefined symbols") {
        throw MakerError(
          "\(error)\n\nLinking \(name) as a dynamic framework failed. If it uses a system framework or library through a dependency the manifest doesn't declare, pass it with -Xlinker (e.g. -Xlinker -framework -Xlinker UIKit)."
        )
      }
      slices.append(slice)
    }
    try shell.run(["lipo", "-create"] + slices + ["-output", binary.path], stream: false)
    return minimumOSVersion
  }

  /// The `minos` of an object's `LC_BUILD_VERSION`, e.g. `15.0`.
  func deploymentTarget(of object: URL, architecture: String) throws -> String {
    let output = try shell.run(
      ["xcrun", "vtool", "-arch", architecture, "-show-build", object.path],
      stream: false
    )
    let words = output.split(whereSeparator: \.isWhitespace)
    guard let index = words.firstIndex(of: "minos"), index + 1 < words.count else {
      throw MakerError("No deployment target recorded in \(object.path)")
    }
    return String(words[index + 1])
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
  ///
  /// Only header files (and a custom module map) are copied, since the public headers
  /// folder can hold sources too (`publicHeadersPath: "."`). Hidden folders and `skipped`
  /// folders (excluded paths, nested targets) are left out.
  public static func installClangHeaders(
    from publicHeaders: URL,
    moduleName: String,
    into headersDirectory: URL,
    skipping skipped: [URL] = []
  ) throws -> String {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: headersDirectory)
    try fileManager.createDirectory(
      at: headersDirectory,
      withIntermediateDirectories: true
    )
    try copyHeaders(from: publicHeaders, to: headersDirectory, skipping: skipped)

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

  static let headerExtensions: Set = ["h", "hh", "hpp", "hxx", "inc"]

  /// Header paths relative to `directory`, sorted.
  static func headerFiles(in directory: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
      return []
    }
    return enumerator.compactMap { $0 as? String }.filter { $0.hasSuffix(".h") }.sorted()
  }

  private static func copyHeaders(
    from source: URL,
    to destination: URL,
    skipping skipped: [URL]
  ) throws {
    let fileManager = FileManager.default
    guard let enumerator = fileManager.enumerator(atPath: source.path) else {
      return
    }
    let skippedPaths = Set(skipped.map(canonicalPath))
    while let path = enumerator.nextObject() as? String {
      let item = source.appendingPathComponent(path)
      if item.lastPathComponent.hasPrefix(".") || skippedPaths
        .contains(canonicalPath(item)) {
        enumerator.skipDescendants()
        continue
      }
      let isHeader = headerExtensions.contains(item.pathExtension)
      guard isHeader || path == "module.modulemap",
            enumerator.fileAttributes?[.type] as? FileAttributeType == .typeRegular else {
        continue
      }
      let target = destination.appendingPathComponent(path)
      try fileManager.createDirectory(
        at: target.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try fileManager.copyItem(at: item, to: target)
    }
  }
}
