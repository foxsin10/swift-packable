import ArgumentParser
import Foundation
import XcframeworkPackableKit

struct SwitchOptions: ParsableArguments {
  @Option(
    name: .long,
    help: "The client package whose Package.swift gets the generated block."
  )
  var packagePath: String = "."

  @Option(name: .long, help: "The config file. Default: <package-path>/packable.yml.")
  var config: String?

  @Flag(
    help: "Rebuild binaries built on demand, and update remote sources to their newest allowed version."
  )
  var rebuild = false

  @Flag(name: .shortAndLong, help: "Stream build output.")
  var verbose = false

  func switcher() -> DependencySwitcher {
    let package = URL(fileURLWithPath: packagePath).standardizedFileURL
    var options = DependencySwitcher.Options(
      packageDirectory: package,
      configURL: config.map { URL(fileURLWithPath: $0).standardizedFileURL }
    )
    options.rebuild = rebuild
    options.verbose = verbose
    return DependencySwitcher(options: options)
  }
}

struct Generate: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Write Package.swift's dependency block from packable.yml.",
    discussion: """
      Each dependency in packable.yml is used from source or as a prebuilt binary package. \
      Binary mode uses `binary:` when given; otherwise the source is packaged into \
      XCFrameworks and cached, and rebuilt only when it changes.

      Package.swift gets `packableDependencies` and `packable(_:from:)` between \
      `// packable:begin` and `// packable:end` (inserted after `import PackageDescription` \
      the first time). Use them in the manifest:

        dependencies: packableDependencies,
        ... .target(name: "App", dependencies: [packable("ShowcaseKit", from: "ShowcaseKit")])
      """
  )

  @OptionGroup var options: SwitchOptions

  func run() throws {
    do {
      try report(options.switcher().generate())
    } catch {
      fail(error)
    }
  }
}

struct Use: ParsableCommand {
  enum Mode: String, ExpressibleByArgument, CaseIterable {
    case source
    case binary

    var value: PackableConfig.Mode {
      self == .source ? .source : .binary
    }
  }

  static let configuration = CommandConfiguration(
    abstract: "Switch dependencies between source and binary, then regenerate.",
    discussion: """
      Examples:
        xcframework-packable use binary ShowcaseKit
        xcframework-packable use source ShowcaseKit MathUtils
        xcframework-packable use binary --all
      """
  )

  @Argument(help: "source or binary.")
  var mode: Mode

  @Argument(help: "Dependencies to switch, as named in packable.yml.")
  var names: [String] = []

  @Flag(help: "Switch every dependency.")
  var all = false

  @Flag(
    help: "Keep .build. By default it's cleared (except checkouts) so stale objects from the other mode don't break linking."
  )
  var noClean = false

  @OptionGroup var options: SwitchOptions

  func validate() throws {
    if names.isEmpty == !all {
      throw ValidationError("Name the dependencies to switch, or pass --all.")
    }
  }

  func run() throws {
    let switcher = options.switcher()
    do {
      let (changed, result) = try switcher.use(mode.value, for: all ? [] : names)
      if changed.isEmpty {
        print(
          "Already \(mode.rawValue): \(all ? "all dependencies" : names.joined(separator: ", "))"
        )
      } else {
        print("Switched to \(mode.rawValue): \(changed.joined(separator: ", "))")
      }
      report(result)
      if !changed.isEmpty, !noClean {
        do {
          let removed = try switcher.cleanBuildProducts()
          if !removed.isEmpty {
            let xcode = "In Xcode, also run Product › Clean Build Folder."
            print("Cleared .build (\(removed.joined(separator: ", "))). \(xcode)")
          }
        } catch {
          // The switch itself succeeded; only the cleanup was skipped.
          print("warning: \(error)")
        }
      }
    } catch {
      fail(error)
    }
  }
}

private func report(_ result: DependencySwitcher.Result) {
  for warning in result.warnings {
    print("warning: \(warning)")
  }
  let width = result.dependencies.map(\.name.count).max() ?? 0
  for dependency in result.dependencies {
    let name = dependency.name.padding(toLength: width, withPad: " ", startingAt: 0)
    print(
      "  \(name)  \(dependency.mode.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0))  \(dependency.packageExpression)"
    )
  }
  print(result
    .manifestChanged ? "✔ Package.swift updated" : "✔ Package.swift already up to date")
}
