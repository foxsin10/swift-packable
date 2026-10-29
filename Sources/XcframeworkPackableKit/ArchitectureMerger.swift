import Foundation

/// SwiftPM can't combine `--triple` with several `--arch` values, so each architecture is
/// built separately. This type keeps a copy of every per-architecture module and merges
/// them into one universal module, the way Xcode does for multi-architecture builds.
struct ArchitectureMerger {
  let shell: Shell

  /// Merges generated `-Swift.h` headers. Each one has the shape
  /// `#if 0` / `#elif <arch check>` / body / `#else` / `#error ...` / `#endif`;
  /// the merged header keeps one `#elif` branch per architecture.
  static func mergeObjCHeaders(_ headers: [String]) throws -> String {
    var branches: [String] = []
    for header in headers {
      let lines = header.components(separatedBy: "\n")
      guard lines.first == "#if 0",
            lines.count > 1, lines[1].hasPrefix("#elif"),
            let elseIndex = lines.lastIndex(of: "#else") else {
        throw MakerError(
          "Unexpected layout of a generated -Swift.h header; can't merge architectures."
        )
      }
      let branch = lines[1 ..< elseIndex].joined(separator: "\n")
      if !branches.contains(branch) {
        branches.append(branch)
      }
    }
    return (["#if 0"] + branches + [
      "#else",
      "#error unsupported Swift architecture",
      "#endif",
      ""
    ]).joined(separator: "\n")
  }

  /// Copies the parts of `module` that the next build will overwrite into `directory`.
  func snapshot(_ module: BuiltModule, into directory: URL) throws -> BuiltModule {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: directory)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    func copy(_ url: URL) throws -> URL {
      let destination = directory.appendingPathComponent(url.lastPathComponent)
      try fileManager.copyItem(at: url, to: destination)
      return destination
    }

    let kind: BuiltModule.Kind = switch module.kind {
    case let .swift(swiftmodule, objcHeader):
      try .swift(swiftmodule: copy(swiftmodule), objcHeader: objcHeader.map(copy))
    case .clang:
      module.kind // headers come from the package sources, not the build
    }
    return try BuiltModule(
      name: module.name,
      object: copy(module.object),
      kind: kind,
      resourceBundle: module.resourceBundle.map(copy)
    )
  }

  /// Combines per-architecture snapshots of one module into a universal module in
  /// `directory`.
  func merge(_ slices: [BuiltModule], into directory: URL) throws -> BuiltModule {
    guard let first = slices.first else {
      throw MakerError("Nothing to merge")
    }
    guard slices.count > 1 else {
      return first
    }

    let fileManager = FileManager.default
    try? fileManager.removeItem(at: directory)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    let object = directory.appendingPathComponent(first.object.lastPathComponent)
    try shell.run(
      ["lipo", "-create"] + slices.map(\.object.path) + ["-output", object.path],
      stream: false
    )

    let kind: BuiltModule.Kind
    switch first.kind {
    case let .swift(firstModule, firstHeader):
      // Files in a .swiftmodule are named per target triple, so a union merges them.
      let swiftmodule = directory.appendingPathComponent(firstModule.lastPathComponent)
      try fileManager.createDirectory(at: swiftmodule, withIntermediateDirectories: true)
      var headers: [String] = []
      for slice in slices {
        guard case let .swift(module, header) = slice.kind else {
          continue
        }
        for file in try fileManager.contentsOfDirectory(atPath: module.path) {
          let destination = swiftmodule.appendingPathComponent(file)
          if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.copyItem(
              at: module.appendingPathComponent(file),
              to: destination
            )
          }
        }
        if let header {
          try headers.append(String(contentsOf: header, encoding: .utf8))
        }
      }
      var mergedHeader: URL?
      if let firstHeader, headers.count == slices.count {
        let url = directory.appendingPathComponent(firstHeader.lastPathComponent)
        try Self.mergeObjCHeaders(headers).write(
          to: url,
          atomically: true,
          encoding: .utf8
        )
        mergedHeader = url
      }
      kind = .swift(swiftmodule: swiftmodule, objcHeader: mergedHeader)
    case .clang:
      kind = first.kind
    }
    return BuiltModule(
      name: first.name,
      object: object,
      kind: kind,
      resourceBundle: first.resourceBundle
    )
  }
}
