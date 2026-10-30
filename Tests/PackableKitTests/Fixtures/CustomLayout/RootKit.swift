import CLegacy
import Core
import Extra
import Foundation

public enum RootKit {
  /// Combines every module; reads resources from both RootKit's and Core's bundles.
  public static func summary() -> String {
    let root = Bundle.module.url(forResource: "root", withExtension: "txt")
      .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = [root ?? "missing", Core.message() ?? "missing", Extra.name]
    return parts.joined(separator: " | ") + " | \(legacy_triple(14))"
  }
}
