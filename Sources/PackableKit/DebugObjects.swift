import Foundation

/// Keeps a static module's debug info outside its framework.
///
/// SwiftPM's prelinked `<Name>.o` has no DWARF, only a debug map pointing at the
/// per-file objects in the build folder. This copies those objects to
/// `<directory>/<Module>/<platform>/<arch>/` and prelinks them again from there, so the
/// framework stays as lean as the default while its debug map points at the copies.
struct DebugObjects {
  let shell: Shell
  let directory: URL

  /// `<directory>/<Module>`, which holds every slice of the module.
  func folder(of module: String) -> URL {
    directory.appendingPathComponent(module)
  }

  /// Copies the objects listed in `linkFileList` (and the module's `.swiftmodule`, which
  /// the prelink records for lldb) into this module's slice folder, then prelinks them
  /// into `<staging>/<Name>.o`. Returns `module` with that object.
  func relocate(
    _ module: BuiltModule,
    linkFileList: URL,
    platform: ApplePlatform,
    architecture: String,
    staging: URL
  ) throws -> BuiltModule {
    let fileManager = FileManager.default
    let slice = folder(of: module.name)
      .appendingPathComponent("\(platform.rawValue)/\(architecture)")
    try? fileManager.removeItem(at: slice)
    try fileManager.createDirectory(at: slice, withIntermediateDirectories: true)

    let listed = try String(contentsOf: linkFileList, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
      .map { URL(fileURLWithPath: String($0)) }
    var names = Set<String>()
    var copies: [String] = []
    for (index, object) in listed.enumerated() {
      var name = object.lastPathComponent
      if !names.insert(name).inserted {
        name = "\(index)-\(name)"
        names.insert(name)
      }
      let copy = slice.appendingPathComponent(name)
      try fileManager.copyItem(at: object, to: copy)
      copies.append(copy.path)
    }
    let list = slice.appendingPathComponent(linkFileList.lastPathComponent)
    try (copies.joined(separator: "\n") + "\n").write(to: list, atomically: true, encoding: .utf8)

    // Swift Build's prelink adds the target's per-architecture module as an AST path.
    var astPath: [String] = []
    let swiftmodule = linkFileList.deletingLastPathComponent()
      .appendingPathComponent("\(module.name).swiftmodule")
    if fileManager.fileExists(atPath: swiftmodule.path) {
      let copy = slice.appendingPathComponent(swiftmodule.lastPathComponent)
      try fileManager.copyItem(at: swiftmodule, to: copy)
      astPath = ["-add_ast_path", copy.path]
    }

    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    let object = staging.appendingPathComponent("\(module.name).o")
    try? fileManager.removeItem(at: object)
    // `ld -r` takes the platform and deployment target from its inputs. `-reproducible`
    // records 0 as each object's date, as Swift Build does, so lldb doesn't compare
    // dates.
    try shell.run(
      ["xcrun", "ld", "-r", "-arch", architecture, "-reproducible"]
        + ["-filelist", list.path] + astPath + ["-o", object.path],
      stream: false
    )
    return BuiltModule(
      name: module.name,
      object: object,
      kind: module.kind,
      resourceBundle: module.resourceBundle
    )
  }
}
