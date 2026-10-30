import CDemo
import DemoCore
import Foundation

public enum Demo {
  public static func answer() -> Int {
    Int(cdemo_add(Int32(Core().value()), 1))
  }
}

@objc(DMOGreeter)
public final class Greeter: NSObject {
  @objc public func greeting() -> String {
    "answer=\(Demo.answer())"
  }
}
