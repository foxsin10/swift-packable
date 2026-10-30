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
  /// Fingerprint of the source files, for binaries built on demand from a local path.
  public var fingerprint: String?
  /// Every module packaged as an XCFramework.
  public var modules: [String]
  /// Product name → modules it links.
  public var products: [String: [String]]

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

/// A fingerprint of the files that affect a package's build: sizes and modification
/// dates of everything outside build, VCS and editor folders.
func sourceFingerprint(of directory: URL) -> String {
  let skipped: Set = [".build", ".git", ".swiftpm", ".DS_Store"]
  guard let enumerator = FileManager.default.enumerator(
    at: directory,
    includingPropertiesForKeys: [
      .fileSizeKey,
      .contentModificationDateKey,
      .isRegularFileKey
    ]
  ) else {
    return ""
  }
  var entries: [String] = []
  for case let url as URL in enumerator {
    if skipped.contains(url.lastPathComponent) {
      enumerator.skipDescendants()
      continue
    }
    let keys: Set<URLResourceKey> = [
      .fileSizeKey,
      .contentModificationDateKey,
      .isRegularFileKey
    ]
    guard let values = try? url.resourceValues(forKeys: keys),
          values.isRegularFile == true else {
      continue
    }
    let relative = String(url.path.dropFirst(directory.path.count))
    let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
    entries.append("\(relative)|\(values.fileSize ?? 0)|\(modified)")
  }
  return stableHash(entries.sorted().joined(separator: "\n"))
}

/// FNV-1a 64-bit, as hex. Only used to detect changes, not for security.
func stableHash(_ string: String) -> String {
  var hash: UInt64 = 0xCBF2_9CE4_8422_2325
  for byte in string.utf8 {
    hash ^= UInt64(byte)
    hash = hash &* 0x0000_0100_0000_01B3
  }
  return String(hash, radix: 16)
}
