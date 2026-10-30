import CryptoKit
import Foundation

/// A SHA-256 of everything a build depends on: the file contents of every package in the
/// graph, the build settings, the toolchain, and swift-packable itself. When it matches
/// the one in an output's `packable-metadata.json`, the build can be skipped.
enum BuildChecksum {
  /// Folders and files that never affect a build.
  static let skippedNames: Set = [".build", ".git", ".swiftpm", ".DS_Store"]

  /// - Parameters:
  ///   - packages: Package identity and directory; the order doesn't matter.
  ///   - settings: Everything else that affects the output, one line each.
  ///   - excluding: Directories left out, such as an output folder inside a package.
  static func compute(
    packages: [(identity: String, directory: URL)],
    settings: [String],
    excluding: [URL] = []
  ) -> String {
    var hasher = SHA256()
    func add(_ string: String) {
      hasher.update(data: Data((string + "\0").utf8))
    }
    for line in settings {
      add(line)
    }
    let excluded = Set(excluding.map(canonicalPath))
    for package in packages.sorted(by: { $0.identity < $1.identity }) {
      add("package:\(package.identity)")
      for file in files(in: package.directory, excluding: excluded) {
        add("file:\(file.relativePath)")
        if let destination = file.symlinkDestination {
          add("link:\(destination)")
        } else if let data = try? Data(contentsOf: file.url, options: .mappedIfSafe) {
          add("size:\(data.count)")
          hasher.update(data: data)
        }
      }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Settings lines describing the tools that produce the output: the Swift compiler,
  /// the selected Xcode (which fixes the SDKs), and the running swift-packable binary.
  static func toolchain(shell: Shell) -> [String] {
    let swift = (try? shell.run(["swift", "--version"], stream: false)) ?? ""
    let xcode = (try? shell.run(["xcodebuild", "-version"], stream: false)) ?? ""
    let executable = Bundle.main.executableURL
      .flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
      .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? ""
    return [
      "swift:" + swift.trimmingCharacters(in: .whitespacesAndNewlines),
      "xcode:" + xcode.trimmingCharacters(in: .whitespacesAndNewlines),
      "tool:" + executable
    ]
  }

  private struct File {
    let url: URL
    let relativePath: String
    let symlinkDestination: String?
  }

  /// Regular files and symlinks under `directory`, sorted by relative path.
  private static func files(in directory: URL, excluding excluded: Set<String>) -> [File] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
    guard let enumerator = FileManager.default.enumerator(
      at: directory,
      includingPropertiesForKeys: keys
    ) else {
      return []
    }
    let root = directory.standardizedFileURL.path
    var files: [File] = []
    for case let url as URL in enumerator {
      guard !skippedNames.contains(url.lastPathComponent) else {
        enumerator.skipDescendants()
        continue
      }
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
        continue
      }
      if values.isDirectory == true, !excluded.isEmpty,
         excluded.contains(canonicalPath(url)) {
        enumerator.skipDescendants()
        continue
      }
      let relative = String(url.standardizedFileURL.path.dropFirst(root.count))
      if values.isSymbolicLink == true {
        let destination = try? FileManager.default
          .destinationOfSymbolicLink(atPath: url.path)
        files.append(File(
          url: url,
          relativePath: relative,
          symlinkDestination: destination ?? ""
        ))
      } else if values.isRegularFile == true {
        files.append(File(url: url, relativePath: relative, symlinkDestination: nil))
      }
    }
    return files.sorted { $0.relativePath < $1.relativePath }
  }
}
