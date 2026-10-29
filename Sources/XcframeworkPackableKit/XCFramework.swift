import Foundation

enum XCFramework {
  struct Library: Decodable {
    let LibraryIdentifier: String
    let LibraryPath: String
    let SupportedPlatform: String
    let SupportedPlatformVariant: String?
  }

  struct InfoPlist: Decodable {
    let AvailableLibraries: [Library]
  }

  /// The `SupportedPlatform` / `SupportedPlatformVariant` pair xcodebuild records for a
  /// slice.
  static func identity(of platform: ApplePlatform)
    -> (platform: String, variant: String?) {
    switch platform {
    case .macOS: ("macos", nil)
    case .macCatalyst: ("ios", "maccatalyst")
    case .iOS: ("ios", nil)
    case .iOSSimulator: ("ios", "simulator")
    case .tvOS: ("tvos", nil)
    case .tvOSSimulator: ("tvos", "simulator")
    case .watchOS: ("watchos", nil)
    case .watchOSSimulator: ("watchos", "simulator")
    case .visionOS: ("xros", nil)
    case .visionOSSimulator: ("xros", "simulator")
    }
  }

  /// Copies the compiled `.swiftmodule` files from the source frameworks back into the
  /// XCFramework.
  static func restoreBinarySwiftModules(
    in xcframework: URL,
    module: String,
    from frameworks: [ApplePlatform: URL]
  ) throws {
    let fileManager = FileManager.default
    let data = try Data(contentsOf: xcframework.appendingPathComponent("Info.plist"))
    let info = try PropertyListDecoder().decode(InfoPlist.self, from: data)
    let relativeModule = "Modules/\(module).swiftmodule"

    for (platform, framework) in frameworks {
      let wanted = identity(of: platform)
      guard let library = info.AvailableLibraries.first(where: {
        $0.SupportedPlatform == wanted.platform && $0.SupportedPlatformVariant == wanted
          .variant
      }) else {
        continue
      }

      let source = framework.appendingPathComponent(relativeModule)
      let destination = xcframework.appendingPathComponent(library.LibraryIdentifier)
        .appendingPathComponent(library.LibraryPath)
        .appendingPathComponent(relativeModule)
      guard fileManager.fileExists(atPath: source.path),
            fileManager.fileExists(atPath: destination.path) else {
        continue
      }
      for file in try fileManager.contentsOfDirectory(atPath: source.path)
        where file.hasSuffix(".swiftmodule") {
        let target = destination.appendingPathComponent(file)
        if !fileManager.fileExists(atPath: target.path) {
          try fileManager.copyItem(at: source.appendingPathComponent(file), to: target)
        }
      }
    }
  }
}
