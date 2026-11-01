import Foundation

/// Starts an empty scratch folder from the dependencies already resolved in the package's
/// own `.build`, so they aren't stored twice.
///
/// The checkouts, bare repositories and downloaded artifacts are copied as APFS clones,
/// which share disk blocks with the originals until either side changes. SwiftPM's
/// `workspace-state.json` comes along, with artifact paths moved to the scratch folder.
/// From then on the two folders are independent: SwiftPM fetches only what differs.
public struct ScratchSeed: Sendable {
  public init(packageDirectory: URL, scratchDirectory: URL, shell: Shell) {
    source = packageDirectory.appendingPathComponent(".build")
    scratch = scratchDirectory
    self.shell = shell
  }

  /// Folders copied from `.build`, as SwiftPM lays them out.
  static let items = ["repositories", "checkouts", "artifacts"]
  static let state = "workspace-state.json"

  let source: URL
  let scratch: URL
  let shell: Shell

  /// Seeds the scratch folder when it hasn't been resolved yet and `.build` has been.
  /// Returns false, leaving nothing behind, when there's nothing to seed or the files
  /// can't be cloned (for example, on a file system other than APFS).
  @discardableResult
  public func plant() -> Bool {
    let fileManager = FileManager.default
    func exists(_ base: URL, _ item: String) -> Bool {
      fileManager.fileExists(atPath: base.appendingPathComponent(item).path)
    }
    guard canonicalPath(source) != canonicalPath(scratch),
          exists(source, Self.state), exists(source, "checkouts"),
          !exists(scratch, Self.state), !exists(scratch, "checkouts")
    else {
      return false
    }
    do {
      try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
      for item in Self.items where exists(source, item) {
        // `-c` clones with clonefile(2) and fails rather than falling back to a full copy.
        try shell.run(
          [
            "cp", "-c", "-R",
            source.appendingPathComponent(item).path,
            scratch.appendingPathComponent(item).path
          ],
          stream: false
        )
      }
      try movedState().write(to: scratch.appendingPathComponent(Self.state))
      return true
    } catch {
      remove()
      return false
    }
  }

  /// Removes everything `plant` may have put in the scratch folder.
  public func remove() {
    for item in Self.items + [Self.state] {
      try? FileManager.default.removeItem(at: scratch.appendingPathComponent(item))
    }
  }

  /// `.build/workspace-state.json` with artifact paths under `.build` moved to the
  /// scratch folder. Paths elsewhere (local packages and artifacts) stay as they are.
  func movedState() throws -> Data {
    let data = try Data(contentsOf: source.appendingPathComponent(Self.state))
    guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          var object = root["object"] as? [String: Any],
          let artifacts = object["artifacts"] as? [[String: Any]]
    else {
      throw MakerError("Unexpected layout of \(Self.state)")
    }
    let prefix = canonicalPath(source) + "/"
    object["artifacts"] = artifacts.map { artifact in
      var artifact = artifact
      if let path = artifact["path"] as? String {
        let canonical = canonicalPath(URL(fileURLWithPath: path))
        // Paths compare case-insensitively, like the default macOS file system.
        if canonical.lowercased().hasPrefix(prefix.lowercased()) {
          let relative = String(canonical.dropFirst(prefix.count))
          artifact["path"] = scratch.appendingPathComponent(relative).path
        }
      }
      return artifact
    }
    root["object"] = object
    return try JSONSerialization.data(
      withJSONObject: root,
      options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
  }
}
