import Foundation

/// A library module that SwiftPM compiled for one platform.
public struct BuiltModule: Sendable {
  public enum Kind: Sendable {
    /// `swiftmodule` is SwiftPM's `<Name>.swiftmodule` directory; `objcHeader` the
    /// generated `<Name>-Swift.h`.
    case swift(swiftmodule: URL, objcHeader: URL?)
    /// `publicHeaders` is the target's public headers directory, when it has one.
    /// `skipping` lists folders in it that belong elsewhere: excluded or other targets.
    case clang(publicHeaders: URL?, skipping: [URL])
  }

  public let name: String
  /// The prelinked object file SwiftPM produces for the target (`<Name>.o`).
  public let object: URL
  public let kind: Kind
  public let resourceBundle: URL?
}

/// Library targets of all packages in the graph, keyed by module name.
public struct TargetIndex: Sendable {
  public init(packages: [ResolvedPackage]) {
    for package in packages {
      for target in package.manifest.targets where target.isLibrary {
        entries[moduleName(forTarget: target.name)] = Entry(
          package: package,
          target: target
        )
      }
    }
  }

  public struct Entry: Sendable {
    public let package: ResolvedPackage
    public let target: PackageManifest.Target
  }

  public private(set) var entries: [String: Entry] = [:]
}

/// Reads the products directory of a `swift build` run that used the Swift Build engine.
public struct BuildProductsDirectory: Sendable {
  public let url: URL

  /// Every library module with a prelinked object file in the directory.
  public func modules(index: TargetIndex) throws -> [BuiltModule] {
    let fileManager = FileManager.default
    let contents = try fileManager.contentsOfDirectory(atPath: url.path)
    return contents.filter { $0.hasSuffix(".o") }.sorted().compactMap { file in
      let name = String(file.dropLast(2))
      guard let entry = index.entries[name] else {
        return nil
      }

      let swiftmodule = url.appendingPathComponent("\(name).swiftmodule")
      let kind: BuiltModule.Kind
      if fileManager.fileExists(atPath: swiftmodule.path) {
        let header = generatedModuleMaps.appendingPathComponent("\(name)-Swift.h")
        kind = .swift(
          swiftmodule: swiftmodule,
          objcHeader: fileManager.fileExists(atPath: header.path) ? header : nil
        )
      } else {
        let headers = entry.package.publicHeadersDirectory(of: entry.target)
        let hasHeaders = fileManager.fileExists(atPath: headers.path)
        kind = .clang(
          publicHeaders: hasHeaders ? headers : nil,
          skipping: entry.package.foreignDirectories(within: entry.target)
        )
      }

      let bundleNames = [entry.package.manifest.name, entry.package.identity]
        .map { "\($0)_\(entry.target.name).bundle" }
      let bundle = bundleNames.map { url.appendingPathComponent($0) }
        .first { fileManager.fileExists(atPath: $0.path) }

      return BuiltModule(
        name: name,
        object: url.appendingPathComponent(file),
        kind: kind,
        resourceBundle: bundle
      )
    }
  }

  /// `out/Products/Release-iphoneos` pairs with
  /// `out/Intermediates.noindex/GeneratedModuleMaps-iphoneos`.
  var generatedModuleMaps: URL {
    let folder = url.lastPathComponent
    let suffix = folder.firstIndex(of: "-").map { String(folder[$0...]) } ?? ""
    return url.deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Intermediates.noindex")
      .appendingPathComponent("GeneratedModuleMaps" + suffix)
  }
}
