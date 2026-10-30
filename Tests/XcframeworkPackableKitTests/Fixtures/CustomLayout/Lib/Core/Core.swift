import Foundation

public enum Core {
  public static func message() -> String? {
    Bundle.module.url(forResource: "core", withExtension: "txt")
      .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
