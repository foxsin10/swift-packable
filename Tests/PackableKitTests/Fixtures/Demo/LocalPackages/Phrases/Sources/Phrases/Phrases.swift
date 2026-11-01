import Foundation

public enum Phrases {
  /// Read from this module's resource bundle.
  public static func farewell() -> String? {
    Bundle.module.url(forResource: "farewell", withExtension: "txt")
      .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
