import ShowcaseKit
import ShowcaseStats

print("ShowcaseKit \(Showcase.version), linked from XCFrameworks")

// Swift API, with templates read from the module's resource bundle.
for language in Language.allCases {
  print("  greet (\(language.rawValue)): \(Showcase.greet("Swift", in: language))")
}

/// Swift API backed by the C module.
let checksum = String(Showcase.checksum(of: "hello"), radix: 16, uppercase: true)
print("  crc32(\"hello\"): 0x\(checksum)")

// @objc class from the generated -Swift.h header.
print("  objc greeter: \(Greeter().greet("Objective-C"))")

/// Second product, which pulls in the MathUtils package.
let summary = Summary([2, 4, 4, 4, 5, 5, 7, 9])
print(
  "  stats: count=\(summary.count) mean=\(summary.mean) sd=\(summary.standardDeviation)"
)
