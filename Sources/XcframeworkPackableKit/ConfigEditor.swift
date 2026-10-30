import Foundation

/// Edits `mode:` values in `packable.yml` as text, so comments and layout survive.
public enum ConfigEditor {
  /// Sets `dependencies.<name>.mode` to `mode`, adding the key when it's missing.
  public static func setMode(
    _ mode: PackableConfig.Mode,
    for name: String,
    in yaml: String
  ) throws -> String {
    var lines = yaml.components(separatedBy: "\n")
    guard let section = lines.firstIndex(where: { $0.hasPrefix("dependencies:") }) else {
      throw MakerError("packable.yml has no top-level `dependencies:` section.")
    }

    let keys = [name, "\"\(name)\"", "'\(name)'"]
    guard let nameLine = lines.indices.dropFirst(section + 1).first(where: { index in
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      return indentation(of: line) > 0 && keys.contains { trimmed == "\($0):" }
    }) else {
      throw MakerError("""
        Couldn't find `\(name):` (in block style) under `dependencies:` in packable.yml.
        """)
    }

    // The dependency's block: lines indented deeper than its key.
    let keyIndent = indentation(of: lines[nameLine])
    var childIndent: Int?
    var index = nameLine + 1
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") {
        index += 1
        continue
      }
      let indent = indentation(of: line)
      if indent <= keyIndent {
        break
      }
      childIndent = childIndent ?? indent
      if indent == childIndent, trimmed.hasPrefix("mode:") {
        let comment = trimmed.firstIndex(of: "#").map { " " + trimmed[$0...] } ?? ""
        let padding = String(repeating: " ", count: indent)
        lines[index] = padding + "mode: \(mode.rawValue)" + comment
        return lines.joined(separator: "\n")
      }
      index += 1
    }

    let indent = String(repeating: " ", count: childIndent ?? keyIndent + 2)
    lines.insert(indent + "mode: \(mode.rawValue)", at: nameLine + 1)
    return lines.joined(separator: "\n")
  }

  private static func indentation(of line: String) -> Int {
    line.prefix { $0 == " " }.count
  }
}
