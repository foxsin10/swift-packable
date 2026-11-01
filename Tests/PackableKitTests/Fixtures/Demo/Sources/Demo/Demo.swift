import CDemo
import CZlib
import DemoCore
import Foundation

public enum Demo {
  public static func answer() -> Int {
    Int(cdemo_add(Int32(Core().value()), 1))
  }

  /// Uses the system library module in Demo's public interface.
  public static func checksum(_ text: String) -> UInt {
    UInt(crc32(0, text, uInt(text.utf8.count)))
  }
}

@objc(DMOGreeter)
public final class Greeter: NSObject {
  @objc public func greeting() -> String {
    "answer=\(Demo.answer())"
  }
}
