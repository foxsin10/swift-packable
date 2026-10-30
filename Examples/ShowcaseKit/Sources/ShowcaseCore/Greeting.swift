import Foundation

public enum Language: String, CaseIterable, Sendable {
  case english = "en"
  case chinese = "zh"
  case french = "fr"
}

public struct Greeting: Sendable, Equatable {
  public init(template: String) {
    self.template = template
  }

  public let template: String

  public func render(name: String) -> String {
    template.replacingOccurrences(of: "{name}", with: name)
  }
}
