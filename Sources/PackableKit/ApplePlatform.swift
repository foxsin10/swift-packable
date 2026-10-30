import Foundation

/// One slice of an XCFramework: an SDK plus the target triple SwiftPM compiles for.
public enum ApplePlatform: String, CaseIterable, Sendable, Hashable {
  case macOS = "macos"
  case macCatalyst = "maccatalyst"
  case iOS = "ios"
  case iOSSimulator = "ios-simulator"
  case tvOS = "tvos"
  case tvOSSimulator = "tvos-simulator"
  case watchOS = "watchos"
  case watchOSSimulator = "watchos-simulator"
  case visionOS = "visionos"
  case visionOSSimulator = "visionos-simulator"

  /// Parses a slice name such as `ios-simulator`, or an SDK name such as
  /// `iphonesimulator`.
  public init?(argument: String) {
    let key = argument.lowercased()
    let aliases: [String: ApplePlatform] = [
      "macosx": .macOS,
      "catalyst": .macCatalyst,
      "mac-catalyst": .macCatalyst,
      "iphoneos": .iOS,
      "iphonesimulator": .iOSSimulator,
      "appletvos": .tvOS,
      "appletvsimulator": .tvOSSimulator,
      "watchsimulator": .watchOSSimulator,
      "xros": .visionOS,
      "xrsimulator": .visionOSSimulator
    ]
    guard let platform = ApplePlatform(rawValue: key) ?? aliases[key] else {
      return nil
    }
    self = platform
  }

  /// Name passed to `xcrun --sdk`.
  public var sdkName: String {
    switch self {
    case .macOS,
         .macCatalyst: "macosx"
    case .iOS: "iphoneos"
    case .iOSSimulator: "iphonesimulator"
    case .tvOS: "appletvos"
    case .tvOSSimulator: "appletvsimulator"
    case .watchOS: "watchos"
    case .watchOSSimulator: "watchsimulator"
    case .visionOS: "xros"
    case .visionOSSimulator: "xrsimulator"
    }
  }

  public var defaultArchitectures: [String] {
    switch self {
    case .macOS,
         .macCatalyst,
         .iOSSimulator,
         .tvOSSimulator,
         .watchOSSimulator: [
        "arm64",
        "x86_64"
      ]
    case .iOS,
         .tvOS,
         .visionOS,
         .visionOSSimulator: ["arm64"]
    case .watchOS: ["arm64", "arm64_32"]
    }
  }

  /// The platform name used in `Package.swift` (`platforms:`) whose version applies to
  /// this slice.
  public var manifestPlatformName: String {
    switch self {
    case .macOS: "macos"
    case .macCatalyst: "maccatalyst"
    case .iOS,
         .iOSSimulator: "ios"
    case .tvOS,
         .tvOSSimulator: "tvos"
    case .watchOS,
         .watchOSSimulator: "watchos"
    case .visionOS,
         .visionOSSimulator: "visionos"
    }
  }

  /// macOS-style frameworks use the versioned bundle layout (`Versions/A/...`).
  public var usesVersionedBundleLayout: Bool {
    self == .macOS || self == .macCatalyst
  }

  /// The slices built when a package declares `platformName` in its manifest.
  public static func slices(forManifestPlatform platformName: String) -> [ApplePlatform] {
    switch platformName.lowercased() {
    case "macos": [.macOS]
    case "maccatalyst": [.macCatalyst]
    case "ios": [.iOS, .iOSSimulator]
    case "tvos": [.tvOS, .tvOSSimulator]
    case "watchos": [.watchOS, .watchOSSimulator]
    case "visionos": [.visionOS, .visionOSSimulator]
    default: []
    }
  }

  /// Slices to build for a manifest's `platforms:`: device and simulator for each
  /// declared platform, or macOS + iOS when none is declared. Ordered like `allCases`.
  public static func defaultSlices(for declared: [PackageManifest.Platform])
    -> [ApplePlatform] {
    let slices = declared.flatMap { slices(forManifestPlatform: $0.platformName) }
    let chosen = slices.isEmpty ? [.macOS, .iOS, .iOSSimulator] : slices
    return allCases.filter(chosen.contains)
  }

  /// Target triple for `swift build --triple`. Without a deployment target SwiftPM
  /// uses the version declared in the package manifest.
  public func triple(architecture: String, deploymentTarget: String? = nil) -> String {
    var triple = "\(architecture)-apple-\(tripleOS)\(deploymentTarget ?? "")"
    if let tripleEnvironment {
      triple += "-\(tripleEnvironment)"
    }
    return triple
  }

  /// The `os` component of the LLVM target triple.
  var tripleOS: String {
    switch self {
    case .macOS: "macosx"
    case .macCatalyst,
         .iOS,
         .iOSSimulator: "ios"
    case .tvOS,
         .tvOSSimulator: "tvos"
    case .watchOS,
         .watchOSSimulator: "watchos"
    case .visionOS,
         .visionOSSimulator: "xros"
    }
  }

  var tripleEnvironment: String? {
    switch self {
    case .macCatalyst: "macabi"
    case .iOSSimulator,
         .tvOSSimulator,
         .watchOSSimulator,
         .visionOSSimulator: "simulator"
    default: nil
    }
  }

  /// Suffix of the Swift Build products folder, as in `Release-iphonesimulator`.
  var productsFolderSuffix: String {
    switch self {
    case .macOS: ""
    case .macCatalyst: "-maccatalyst"
    default: "-\(sdkName)"
    }
  }

  var supportedPlatformName: String {
    switch self {
    case .macOS,
         .macCatalyst: "MacOSX"
    case .iOS: "iPhoneOS"
    case .iOSSimulator: "iPhoneSimulator"
    case .tvOS: "AppleTVOS"
    case .tvOSSimulator: "AppleTVSimulator"
    case .watchOS: "WatchOS"
    case .watchOSSimulator: "WatchSimulator"
    case .visionOS: "XROS"
    case .visionOSSimulator: "XRSimulator"
    }
  }
}
