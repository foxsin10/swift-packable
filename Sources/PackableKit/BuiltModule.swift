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
    self.packages = packages
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

  /// Library modules that `module` lists in `dependencies:`, with products expanded to
  /// their targets.
  public func directDependencies(of module: String) -> [String] {
    guard let entry = entries[module] else {
      return []
    }
    let manifest = entry.package.manifest
    let targets: [String] = entry.target.targetDependencies.flatMap { dependency in
      switch dependency {
      case let .target(name):
        return [name]
      case let .byName(name):
        if manifest.target(named: name) != nil {
          return [name]
        }
        return packages.lazy.compactMap { $0.manifest.product(named: name)?.targets }
          .first ?? []
      case let .product(name, packageName):
        let package = packages.first { package in
          packageName.map {
            package.identity == $0.lowercased() || package.manifest.name == $0
          } ?? (package.manifest.product(named: name) != nil)
        }
        return package?.manifest.product(named: name)?.targets ?? []
      }
    }
    var seen = Set<String>()
    return targets.map(moduleName(forTarget:))
      .filter { entries[$0] != nil && seen.insert($0).inserted }
  }

  /// `modules` ordered so that each comes after the modules it depends on (directly or
  /// through modules outside the list), each paired with those dependencies.
  public func linkOrder(of modules: some Collection<String>)
    -> [(module: String, dependencies: [String])] {
    let wanted = Set(modules)
    var closures: [String: Set<String>] = [:]
    var ordered: [(module: String, dependencies: [String])] = []

    // Depth-first; SwiftPM rejects dependency cycles, so none are expected here.
    func visit(_ module: String) -> Set<String> {
      if let closure = closures[module] {
        return closure
      }
      closures[module] = [] // guards against a cycle in a malformed graph
      var closure = Set<String>()
      for dependency in directDependencies(of: module) {
        closure.insert(dependency)
        closure.formUnion(visit(dependency))
      }
      closures[module] = closure
      if wanted.contains(module) {
        ordered.append((module, closure.intersection(wanted).sorted()))
      }
      return closure
    }
    for module in wanted.sorted() {
      _ = visit(module)
    }
    return ordered
  }

  let packages: [ResolvedPackage]
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
