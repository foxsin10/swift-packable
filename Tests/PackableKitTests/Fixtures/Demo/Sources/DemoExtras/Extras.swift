import DemoCore
import Foundation

public enum Extras {
  public static func doubled() -> Int {
    Core().value() * 2
  }

  public static func message() -> String? {
    Bundle.module.url(forResource: "message", withExtension: "txt")
      .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
  }
}
