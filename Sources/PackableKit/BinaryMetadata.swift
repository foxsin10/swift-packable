import Foundation

/// `packable-metadata.json`, written next to a generated binary package's
/// `Package.swift`. `generate` reads it to spot duplicate modules, version drift and
/// stale binaries.
public struct BinaryMetadata: Codable, Sendable, Equatable {
  public static let fileName = "packable-metadata.json"

  /// Name of the source package.
  public var package: String
  /// Git tag at the source's HEAD, when there is exactly one.
  public var version: String?
  /// Git commit of the source, with `-dirty` when it had local changes.
  public var revision: String?
  /// SHA-256 of everything the build depended on (see `BuildChecksum`). A build whose
  /// inputs give the same checksum reuses this output.
  public var buildChecksum: String?
  /// How the frameworks link; `nil` in metadata written before dynamic frameworks, which
  /// were all static.
  public var linkage: Linkage?
  /// Every module packaged as an XCFramework.
  public var modules: [String]
  /// Product name → modules it links.
  public var products: [String: [String]]
  /// Where the static frameworks' debug objects were put (`--debug-objects`); `nil` when
  /// they weren't.
  public var debugObjects: DebugObjects?

  /// The folder whose `<Module>/<platform>/<arch>/` objects hold the DWARF debug info that
  /// the frameworks' debug maps point at.
  public struct DebugObjects: Codable, Sendable, Equatable {
    public var path: String
    /// Modules with a folder there.
    public var modules: [String]
  }

  public static func read(from packageDirectory: URL) -> BinaryMetadata? {
    let url = packageDirectory.appendingPathComponent(fileName)
    guard let data = try? Data(contentsOf: url) else {
      return nil
    }
    return try? JSONDecoder().decode(BinaryMetadata.self, from: data)
  }

  func write(to packageDirectory: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(self)
      .write(to: packageDirectory.appendingPathComponent(Self.fileName))
  }
}

/// Git facts about a source checkout; all `nil` when it isn't a git repository.
struct GitInfo {
  init(directory: URL, shell: Shell) {
    func git(_ arguments: [String]) -> String? {
      let output = try? shell.run(
        ["git", "-C", directory.path] + arguments,
        stream: false
      )
      let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed?.isEmpty == false ? trimmed : nil
    }
    let head = git(["rev-parse", "HEAD"])
    let dirty = git(["status", "--porcelain", "--untracked-files=no"]) != nil
    revision = head.map { dirty ? "\($0)-dirty" : $0 }
    version = dirty ? nil : git(["describe", "--tags", "--exact-match"])
  }

  let revision: String?
  let version: String?
}
