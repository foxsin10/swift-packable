# swift-packable

Compiles a Swift package's source code into binary **XCFrameworks** and generates a binary `Package.swift` that clients can depend on directly.

The whole pipeline is built on Swift Package Manager's own capabilities:

| Step | SwiftPM / Xcode capability used |
| --- | --- |
| Resolve the dependency graph and read each package's manifest | `swift package show-dependencies --format json`, `swift package dump-package` |
| Cross-compile for each platform and architecture | `swift build --triple … --sdk …` (Swift Build engine, with library evolution and `.swiftinterface` emission enabled) |
| Work out which modules each product actually links | The products folder is emptied before each build; the `<Module>.o` files left afterwards are that product's module closure (remote dependencies included) |
| Merge architectures | `lipo`, a union of the `.swiftmodule` folders, and `-Swift.h` headers merged the way Xcode does it |
| Wrap each module in a static or dynamic framework, then combine them into an XCFramework | `libtool -static`, or `swiftc`/`clang` linking against the module's dependency frameworks plus `dsymutil`; then `xcodebuild -create-xcframework` |
| Generate a binary package for distribution | `.binaryTarget`, with optional zipping and `swift package compute-checksum` |

## Requirements

**To build and run the tool**

| Requirement | Details |
| --- | --- |
| macOS 13 or later | The tool's minimum deployment target |
| Xcode, not only the Command Line Tools | `xcodebuild -create-xcframework` needs full Xcode. Check with `xcode-select -p`; it should print a path inside `Xcode.app` (fix with `sudo xcode-select -s /Applications/Xcode.app`) |
| A toolchain with SwiftPM's Swift Build engine | The tool runs `swift build --build-system swiftbuild`; building the tool itself needs Swift tools 6.0. Verified on Swift 6.4 / Xcode 27.1 |
| The SDK of every platform you build | List them with `xcodebuild -showsdks`. Missing ones can be added in Xcode › Settings › Components, or with `xcodebuild -downloadPlatform iOS` (also `tvOS`, `watchOS`, `visionOS`) |

**While it runs**

- **Tools on PATH:** `swift`, `xcrun`, `xcodebuild`, `libtool`, `lipo`, `ditto` and `git`. All of them ship with macOS and Xcode.
- **Network:** only for remote dependencies, when SwiftPM resolves a package URL or `generate` builds a remote source on demand. Local packages build offline.
- **Disk:** binaries built on demand are cached in the client package's `.build/packable-cache` (or `cache:` in `packable.yml`), one copy per dependency version.

**For apps that use the output**

- **SwiftPM:** generated packages use `swift-tools-version:5.9`, so Xcode 15 / Swift 5.9 or later.
- **Compiler version:** with library evolution, apps on newer compilers can use the frameworks. Binaries made with `--skip-interface-verification` (or `--include-binary-swiftmodules`) are safest with the same compiler version that built them.

## Installation

```bash
git clone <this repository> Packable
cd Packable
swift build -c release
.build/release/swift-packable --version   # prints the tool version, e.g. 0.1.0
```

To put the command on your PATH, either install it with SwiftPM:

```bash
swift package experimental-install --product swift-packable   # into ~/.swiftpm/bin
fish_add_path ~/.swiftpm/bin                                         # fish; for zsh/bash add it to PATH in your profile
swift package experimental-uninstall swift-packable            # to remove it
```

or copy the binary:

```bash
sudo cp .build/release/swift-packable /usr/local/bin/
```

Once it's on your PATH, it also runs as a `swift` subcommand, because the `swift` driver runs any `swift-<name>` executable it finds:

```bash
swift packable path/to/MyPackage      # same as swift-packable path/to/MyPackage
swift packable use binary ShowcaseKit
```

Other ways to run it:

- **Without installing:** `swift run -c release swift-packable path/to/MyPackage`
- **Universal binary for Intel Macs:** `swift build -c release --arch arm64 --arch x86_64`; `swift build -c release --arch arm64 --arch x86_64 --show-bin-path` prints where it goes.

The executable includes its libraries (ArgumentParser, Yams), so copying it to another Mac works as long as that Mac meets the requirements above.

## Usage

```bash
# Show the package's library products, declared platforms, and the slices built by default
swift-packable list path/to/MyPackage

# Build every library product; platforms come from the manifest's `platforms:` (iOS → device + simulator)
swift-packable path/to/MyPackage

# Choose products, platforms, and the output directory
swift-packable path/to/MyPackage -p MyLib --platform ios,ios-simulator,macos -o build/MyLibBinary

# Dynamic frameworks instead of static ones
swift-packable path/to/MyPackage --linkage dynamic

# Zip the XCFrameworks and generate a Package.swift with url + checksum (e.g. for GitHub Releases)
swift-packable path/to/MyPackage --zip --base-url https://example.com/releases/1.0.0
```

Output directory (defaults to `<package>-binary` next to the package):

```
MyPackage-binary/
├── Package.swift                 # Same library products as the source package, all as binaryTargets
└── XCFrameworks/
    ├── MyLib.xcframework         # One XCFramework per module (dependency modules included)
    └── MyLibCore.xcframework
```

Clients only need to point their dependency at this directory (or at the published location) instead of the source package; their `import` statements stay the same.

### Common options

| Option | Description |
| --- | --- |
| `-p, --product` | Library product to package; repeatable. Default: all of them |
| `--platform` | `macos`, `maccatalyst`, `ios`, `ios-simulator`, `tvos`, `tvos-simulator`, `watchos`, `watchos-simulator`, `visionos`, `visionos-simulator`; repeat or comma-separate |
| `--arch ios-simulator=arm64` | Override a platform's architectures (default: arm64 + x86_64 for simulators and macOS, arm64 + arm64_32 for watchOS) |
| `--deployment-target ios=16.0` | Override the minimum OS version (default: the one in the manifest) |
| `-c debug` | Build with the debug configuration |
| `--linkage dynamic` | Package dynamic frameworks instead of static ones (see [Dynamic frameworks](#dynamic-frameworks)) |
| `--zip` / `--base-url` | Zip each XCFramework, compute its checksum, and generate remote `binaryTarget`s |
| `--skip-interface-verification` | Skip `.swiftinterface` verification (see below) |
| `--include-binary-swiftmodules` | Keep the compiled `.swiftmodule` files in the XCFrameworks |
| `-Xswiftc` / `-Xcc` / `-Xlinker` | Pass flags through to `swift build` (`-Xlinker` also reaches the dylib link with `--linkage dynamic`) |
| `-v` | Show the full `swift build` output |

## Switching dependencies between source and binary

A client package can declare in `packable.yml` which dependencies it builds from source and which it links as XCFrameworks, and flip them with one command, like the CocoaPods binary plugins.

```yaml
# packable.yml, next to the client's Package.swift
cache: .packable-cache                    # optional; default .build/packable-cache
dependencies:
  ShowcaseKit:
    mode: binary                          # source (default) | binary
    source: { path: ../ShowcaseKit }      # or { url: https://…, from: 1.2.0 }
    binary: { path: ../ShowcaseKit-binary }  # optional, see below
    linkage: dynamic                      # static (default) | dynamic, for on-demand builds
  Alamofire:
    source: { url: https://github.com/Alamofire/Alamofire.git, from: 5.9.0 }
  Logging:
    mode: binary
    source: { url: https://github.com/apple/swift-log.git, exact: 1.6.1 }
    products: [Logging]
    platforms: [ios, ios-simulator]
```

### `packable.yml` reference

Relative paths are resolved against the directory that holds `packable.yml`.

Top level:

| Key | Required | Description |
|---|---|---|
| `dependencies` | yes | Map of dependency name → dependency entry. The name is what `use` and `packable("<name>", …)` refer to. |
| `cache` | no | Directory for binaries built on demand. Default: `.build/packable-cache` in the package (`--package-path`, default the current directory). `Package.swift` refers to it by a path relative to the package. |

Dependency entry:

| Key | Required | Default | Description |
|---|---|---|---|
| `mode` | no | `source` | `source` builds from `source:`; `binary` links XCFrameworks. Flip it with `swift-packable use`. |
| `source` | yes | — | Where the source package lives (a [location](#locations)). |
| `binary` | no | built on demand | A prebuilt binary package (a [location](#locations)). Without it, binary mode packages `source` and caches the result. |
| `products` | no | all library products | Products to package when building on demand. |
| `platforms` | no | the source manifest's platforms | Slices to build on demand: `macos`, `maccatalyst`, `ios`, `ios-simulator`, `tvos`, `tvos-simulator`, `watchos`, `watchos-simulator`, `visionos`, `visionos-simulator`. SDK names (`iphoneos`, `iphonesimulator`, `appletvos`, `appletvsimulator`, `watchsimulator`, `xros`, `xrsimulator`) also work. A manifest with no `platforms:` builds macOS + iOS. |
| `linkage` | no | `static` | `static` or `dynamic` frameworks when building on demand. The two are cached separately. |
| `skip-interface-verification` | no | `false` | Skip `.swiftinterface` verification when building on demand. |

`products`, `platforms`, `linkage` and `skip-interface-verification` only apply to binaries built on demand. A declared `binary:` is used as it is.

#### Locations

A location is either a local path or a URL with exactly one version requirement:

| Key | Example | `Package.swift` equivalent |
|---|---|---|
| `path` | `{ path: ../ShowcaseKit }` | `.package(path: "../ShowcaseKit")` |
| `url` + `from` | `{ url: https://…, from: 1.2.0 }` | `.package(url: …, from: "1.2.0")` |
| `url` + `exact` | `{ url: https://…, exact: 1.2.0 }` | `.package(url: …, exact: "1.2.0")` |
| `url` + `up-to-next-minor` | `{ url: https://…, up-to-next-minor: 1.2.0 }` | `.package(url: …, .upToNextMinor(from: "1.2.0"))` |
| `url` + `branch` | `{ url: https://…, branch: main }` | `.package(url: …, branch: "main")` |
| `url` + `revision` | `{ url: https://…, revision: 4f2c1e0 }` | `.package(url: …, revision: "4f2c1e0")` |

A `path` takes no version requirement, and a `url` needs exactly one. Anything else fails validation. The package name used in `.product(name:package:)` is the last path component, without `.git`.

### Commands

```bash
swift-packable generate                  # write the dependency block into Package.swift
swift-packable use binary ShowcaseKit    # flip modes in packable.yml, regenerate, clear .build
swift-packable use source --all
```

`generate` writes a block between `// packable:begin` and `// packable:end` (inserted after `import PackageDescription` the first time). The rest of `Package.swift` stays yours and uses the block's two names, which don't change between modes:

```swift
let package = Package(
  name: "App",
  dependencies: packableDependencies,
  targets: [
    .target(name: "App", dependencies: [packable("ShowcaseKit", from: "ShowcaseKit")])
  ]
)
```

Where binaries come from:

- **Declared:** `binary:` points at a binary package, either one this tool generated or a released one at a URL.
- **Built on demand:** without `binary:`, the source is packaged with the same pipeline as `build` and cached in the package's `.build/packable-cache` (override with `cache:` in `packable.yml`). Local sources are rebuilt only when their files change. Remote sources are resolved by SwiftPM and cached per version. `.build` isn't committed, so run `generate` after cloning, and after `swift package clean` or `swift package reset` (both delete it), to fill the cache again.

Checks:

- **Clean switch:** `use` clears `.build` (keeping checkouts, downloads, the lock file, sourcekit-lsp's `index-build` and `packable-cache`), because objects left from the other mode break linking. If another SwiftPM process holds the package's lock, the clean is skipped with a warning. In Xcode, also run Product › Clean Build Folder.
- **Duplicate modules:** a binary package bundles its dependencies' modules. If another entry provides one of them, `generate` stops and names the module (for example, MathUtils both bundled in the ShowcaseKit binary and declared on its own).
- **Version drift:** for declared binaries, `generate` warns when the binary was built from a different tag or commit than the source points at (from `packable-metadata.json`, written next to every generated binary package).
- **Rollback:** if regenerating fails, `use` restores `packable.yml`.

## Dynamic frameworks

With `--linkage dynamic` (or `linkage: dynamic` on a `packable.yml` dependency), each module is still its own XCFramework, but its binary is a dylib:

- **Linked against its dependencies.** A module links the frameworks of the modules it depends on (taken from the manifests, so they are built first) and the `linkedFramework`/`linkedLibrary` entries of its `linkerSettings:`. Each loads the others through `@rpath`, so an app embeds them all side by side in `Frameworks/`. Xcode does this automatically for binary targets.
- **Resources stay inside the framework.** The resource bundle ships in the framework, where `Bundle.module` finds it, so the generated `Package.swift` has no carrier targets.
- **dSYMs included.** Every slice carries its dSYM (`dSYMs/` in the XCFramework), so crash reports symbolicate.
- **`MinimumOSVersion`** is set in each framework's `Info.plist` outside macOS, as App Store validation requires.
- **`swift run` needs an rpath.** Under SwiftPM's Swift Build engine, command-line executables get no rpath to the frameworks SwiftPM copies next to them, so `dyld` reports `Library not loaded: @rpath/…`. Run them with `swift run -Xlinker -rpath -Xlinker @executable_path`, or with `--build-system native`. Apps and `swift test` work as they are.

Static frameworks remain the default, since each dynamic framework adds a little to app launch time.

## Examples

[`Examples/`](Examples) has a showcase library (Swift + C modules, resources, an `@objc` API, a dependency package), a client app that uses the generated binaries, and a client that switches between source and binary with `packable.yml`. Run `Examples/run-showcase.sh` to see every use case end to end.

## Notes

- **One XCFramework per module.** Every module a product depends on (C modules and third-party dependency modules included) gets its own XCFramework, and the generated `Package.swift` groups them into a product with the same name. That keeps `import` relationships between modules working in binary form.
- **Resources work through the generated package.** For a static module with resources, the generated `Package.swift` renames its binary target to `<Module>Binary` and adds a small target named `<Module>` that carries the original resource files (under `Resources/<Module>/`). SwiftPM and Xcode process them for the client's platform and install `<Package>_<Module>.bundle` where the compiled `Bundle.module` looks for it, so nothing has to be copied by hand. Declared `.process`/`.copy` resources are carried, plus the types SwiftPM picks up implicitly (asset catalogs, `.xib`, `.storyboard`, `.lproj`, `.xcstrings`, Core Data and Metal files). The bundle is also inside each static framework, for apps that use an XCFramework directly without the package; those apps must copy it into their bundle themselves.
- **Interface verification failures.** Some libraries (for example swift-collections 1.7.x) emit `.swiftinterface` files that don't verify with the current compiler. Pass `--skip-interface-verification` in that case; the tool then also keeps the compiled `.swiftmodule` files, so clients using the same compiler version can still import the modules.
- **Any target layout.** Targets with a custom `path:` (including `path: "."` narrowed with `sources:`/`exclude:`) and the `Source/`, `src/`, `srcs/` default folders work. Resources come from SwiftPM's own resolved list (`swift package describe`), so `exclude:` and implicit resource types match what SwiftPM builds, and only header files are copied into a framework's `Headers/`, even when public headers sit next to sources (`publicHeadersPath: "."`).
- **Macro and binaryTarget dependencies** aren't packaged yet.
- Apple platforms only.

## Development

```bash
swift test   # Unit tests + an end-to-end test (packages Tests/.../Fixtures/Demo, then builds and runs a client against the output)
```
