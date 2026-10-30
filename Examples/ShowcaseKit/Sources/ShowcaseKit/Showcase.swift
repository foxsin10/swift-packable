import CChecksum
import Foundation
@_exported import ShowcaseCore

public enum Showcase {
  public static let version = "1.0.0"

  /// Greets `name` with a template loaded from the module's resource bundle.
  public static func greet(_ name: String, in language: Language = .english) -> String {
    let template = templates[language.rawValue] ?? "Hello, {name}!"
    return Greeting(template: template).render(name: name)
  }

  /// CRC-32 of the UTF-8 bytes of `text`, computed by the C module.
  public static func checksum(of text: String) -> UInt32 {
    let bytes = Array(text.utf8)
    return cchecksum_crc32(bytes, bytes.count)
  }

  private static let templates: [String: String] = {
    guard let url = Bundle.module.url(forResource: "greetings", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
      return [:]
    }
    return decoded
  }()
}

/// Exposed to Objective-C through the generated ShowcaseKit-Swift.h header.
@objc(SCKGreeter)
public final class Greeter: NSObject {
  @objc public func greet(_ name: String) -> String {
    Showcase.greet(name)
  }
}
