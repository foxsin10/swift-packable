# swift-packable

Compiles a Swift package's source code into binary **XCFrameworks** and generates a binary `Package.swift` that clients can depend on directly.

The whole pipeline is built on Swift Package Manager's own capabilities:

| Step | SwiftPM / Xcode capability used |
| --- | --- |
| Resolve the dependency graph and read each package's manifest | `swift package show-dependencies --format json`, `swift package dump-package` |
| Cross-compile for each platform and architecture | `swift build --triple … --sdk …` (Swift Build engine, with library evolution and `.swiftinterface` emission unless `--disable-library-evolution`) |
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
- **Compiler version:** with library evolution, apps on newer compilers can use the frameworks. Binaries made with `--skip-interface-verification`, `--include-binary-swiftmodules` or `--disable-library-evolution` are safest with the same compiler version that built them.

## Installation

```bash
git clone <this repository> Packable
cd Packable
swift build -c release
.build/release/swift-packable --version   # prints the tool version, e.g. 0.1.0
```

To put the command on your PATH, use the Makefile:

```bash
make install                      # builds in release and copies it to ~/.local/bin
make install PREFIX=/usr/local    # or into /usr/local/bin (may need sudo)
make uninstall                    # removes it (pass the same PREFIX)
```

`make install` prints a note if the folder isn't on PATH (fish: `fish_add_path ~/.local/bin`). `make test` runs the tests.

Or install it with SwiftPM:

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
├── XCFrameworks/
│   ├── MyLib.xcframework         # One XCFramework per module (dependency modules included)
│   └── MyLibCore.xcframework
├── Resources/MyLib/              # Static linkage only: resources of the package's own modules
├── Packages/Dep-resources/       # …and of a dependency's modules, in a package named after it
└── Links/Dep/                    # Pulls that package in
```

Clients only need to point their dependency at this directory (or at the published location) instead of the source package; their `import` statements stay the same.

### Skipping unchanged builds

Every build records a **build checksum** in the output's `packable-metadata.json`. It is a SHA-256 of:

- the file contents of the package and of every package in its dependency graph (local path dependencies and resolved remote checkouts), leaving out `.build`, `.git`, `.swiftpm` and the output, scratch and debug objects folders
- the options that shape the output (products, platforms, architectures, deployment targets, configuration, linkage, interface and `.swiftmodule` settings, debug info and the debug objects folder's path, pass-through flags, zip and base URL, bundle ID prefix, framework version)
- the toolchain (`swift --version`, `xcodebuild -version`) and the `swift-packable` binary itself

When the checksum matches the existing output and all of its XCFrameworks (and, with `--debug-objects`, its debug objects) are still there, nothing is built: the command prints `✔ Up to date` and leaves the output as it is. Only the package graph is resolved and the files are read. Pass `--rebuild` to build anyway. Modification dates don't count, so a fresh clone or `touch` doesn't trigger a rebuild.

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
| `--disable-library-evolution` | Build without `-enable-library-evolution`, for packages that don't compile with it (see below) |
| `--debug-info` | Keep DWARF debug info in static frameworks, so lldb and tools like xcsrclink can map their sources (see [Debug info](#debug-info-in-static-frameworks)) |
| `--debug-objects <dir>` | Keep static frameworks lean and put their debug info in `<dir>` instead; can't be combined with `--debug-info` (see [Debug info](#debug-info-in-static-frameworks)) |
| `-Xswiftc` / `-Xcc` / `-Xlinker` | Pass flags through to `swift build` (`-Xlinker` also reaches the dylib link with `--linkage dynamic`) |
| `--scratch-path` | SwiftPM's working folder (default `<package>/.build/packable`). When it's new and the package's `.build` already has resolved dependencies, their checkouts, repositories and artifacts are copied in as APFS clones, so they take no extra disk space. Elsewhere, or if SwiftPM rejects the copy, dependencies are resolved as usual. To reclaim an existing scratch folder's duplicate, delete its `checkouts`, `repositories`, `artifacts` and `workspace-state.json` |
| `--rebuild` | Build even when the build checksum shows the output is up to date (see [Skipping unchanged builds](#skipping-unchanged-builds)) |
| `-v` | Show the full `swift build` output |

### What `build` runs

The commands behind a typical run, for an iOS app package built with

```bash
swift-packable build <package> --disable-library-evolution --arch ios-simulator=arm64
```

`<package>` is the package folder, `<scratch>` the scratch folder (default `<package>/.build/packable`), `<output>` the output folder (default `<package>-binary`) and `<Product>` the library product.

1. Resolve the graph and read each manifest:

   ```bash
   swift package --package-path <package> --scratch-path <scratch> show-dependencies --format json
   swift package --package-path <dependency> --scratch-path <scratch>/manifests/<identity> dump-package
   ```

2. Compile once per product, platform slice and architecture. Before each build the same command with `--show-bin-path` finds the products folder, which is then emptied:

   ```bash
   # Device slice; the simulator uses --triple arm64-apple-ios-simulator and the iphonesimulator SDK
   swift build --package-path <package> --scratch-path <scratch> \
     --configuration release --build-system swiftbuild \
     --triple arm64-apple-ios \
     --sdk "$(xcrun --sdk iphoneos --show-sdk-path)" \
     --product <Product>
   ```

   With library evolution (the default) it also passes `--enable-parseable-module-interfaces -Xswiftc -enable-library-evolution`, plus `-Xswiftc -no-verify-emitted-module-interface` with `--skip-interface-verification`.

3. Wrap each module in a framework:

   ```bash
   nm -gU <Module>.o        # empty modules that nothing imports are left out
   # A .systemLibrary module gets an empty object, so its XCFramework has a binary
   xcrun --sdk iphoneos clang -target arm64-apple-ios<minos> -x c -c /dev/null -o <Module>.o
   libtool -static -D -no_warning_for_no_symbols -o <Module>.framework/<Module> <Module>.o
   ```

   Headers, the module map and the `.swiftmodule` are copied in. With several architectures, `lipo -create` merges them first; with `--linkage dynamic`, `swiftc`/`clang` link a dylib and `dsymutil` writes its dSYM instead of `libtool`.

   `--debug-info` archives the objects listed in the target's `LinkFileList` instead of `<Module>.o`. `--debug-objects <dir>` copies them (and the `.swiftmodule`) to `<dir>/<Module>/<platform>/<arch>/` and prelinks them again from there:

   ```bash
   libtool -static -D -no_warning_for_no_symbols -o <Module>.a -filelist <Target>.LinkFileList   # --debug-info
   xcrun ld -r -arch arm64 -reproducible -filelist <dir>/…/<Target>.LinkFileList \
     -add_ast_path <dir>/…/<Module>.swiftmodule -o <Module>.o                              # --debug-objects
   ```

4. Combine the platforms into an XCFramework:

   ```bash
   xcodebuild -create-xcframework \
     -framework <scratch>/frameworks/ios/<Module>.framework \
     -framework <scratch>/frameworks/ios-simulator/<Module>.framework \
     -allow-internal-distribution \
     -output <output>/XCFrameworks/<Module>.xcframework
   ```

   `-allow-internal-distribution` is only passed with `--disable-library-evolution`, whose frameworks have no `.swiftinterface` files.

5. Read the package's own resources, then write `Package.swift`, the resource carriers (`Resources/`, `Packages/`, `Links/`) and `packable-metadata.json`:

   ```bash
   swift package --package-path <package> --scratch-path <scratch> describe --type json
   ```

`-v` streams the `swift build` output; the command lines themselves are only printed when one fails.

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
  Alamofire:
    source: { url: https://github.com/Alamofire/Alamofire.git, from: 5.9.0 }
    binary: { url: https://github.com/example/Alamofire-binary.git, exact: 5.9.1 }  # a released binary package
  Logging:
    mode: binary
    source: { url: https://github.com/apple/swift-log.git, exact: 1.6.1 }
    # No `binary:`, so binary mode builds one; these keys shape that build:
    products: [Logging]                   # default: all library products
    platforms: [ios, ios-simulator]       # default: the source manifest's platforms
    linkage: dynamic                      # static (default) | dynamic
    skip-interface-verification: true     # default false
    disable-library-evolution: false      # default false
    debug-info: false                     # default false; static frameworks only
    debug-objects: false                  # default false; static only, not with debug-info
```

### `packable.yml` reference

Relative paths are resolved against the directory that holds `packable.yml`. Write each dependency as a block mapping (`Name:` on its own line with its keys indented below), because `use` rewrites the `mode:` line as text, keeping comments and layout; a missing `mode:` line is added. Locations can use the flow style (`{ path: … }`). A dependency name can be quoted (`"My-Kit":`).

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
| `disable-library-evolution` | no | `false` | Build without library evolution when building on demand. |
| `debug-info` | no | `false` | Keep DWARF debug info in static frameworks when building on demand, like `--debug-info`. Cached separately. |
| `debug-objects` | no | `false` | Put the static frameworks' debug info in the cache entry's `debug-objects/` folder when building on demand, like `--debug-objects`. Cached separately; can't be combined with `debug-info`. |

`products`, `platforms`, `linkage`, `skip-interface-verification`, `disable-library-evolution`, `debug-info` and `debug-objects` only apply to binaries built on demand. A declared `binary:` is used as it is.

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
swift-packable use source ShowcaseKit MathUtils
swift-packable use source --all
```

| Option | Applies to | Description |
| --- | --- | --- |
| `--package-path` | both | The client package whose `Package.swift` gets the block. Default: the current directory |
| `--config` | both | The config file. Default: `<package-path>/packable.yml` |
| `--rebuild` | both | Rebuild binaries built on demand even when the cached ones are current, and move remote sources to the newest version their requirement allows |
| `-v, --verbose` | both | Stream build output |
| `--all` | `use` | Switch every dependency, instead of naming them |
| `--no-clean` | `use` | Keep `.build` as it is (see [Checks](#checks)) |

`use` changes only `mode:` in `packable.yml`, then runs `generate`. A name that isn't in `packable.yml` fails with the list of declared names; switching to the mode a dependency already has prints `Already <mode>`, regenerates and leaves `.build` alone.

### The generated block

`generate` writes a block between `// packable:begin` and `// packable:end` (inserted after `import PackageDescription` the first time, replaced on later runs). For the `SwitchableApp` example in binary mode it is:

```swift
// packable:begin
// Generated by `swift-packable generate` from packable.yml; don't edit by hand.
// Switch modes with `swift-packable use source|binary <name>`.
// swiftformat:disable all
// ShowcaseKit: binary

let packableDependencies: [Package.Dependency] = [
  .package(path: ".build/packable-cache/ShowcaseKit/local/ShowcaseKit-binary"),
]

/// A product of a dependency declared in packable.yml, in its current mode.
func packable(_ product: String, from dependency: String) -> Target.Dependency {
  let packages: [String: String] = [
    "ShowcaseKit": "ShowcaseKit-binary",
  ]
  return .product(name: product, package: packages[dependency] ?? dependency)
}
// swiftformat:enable all
// packable:end
```

- **`packableDependencies`** has one `.package(…)` per entry, in name order: the `source:` location in source mode, the `binary:` location or the on-demand build's folder in binary mode. Paths are rewritten relative to the package.
- **`packable(_ product:, from:)`** takes a library product name and the entry's name in `packable.yml`, and returns `.product(name:package:)` with the package name for the current mode. That name changes between modes (`ShowcaseKit` from source, `ShowcaseKit-binary` from an on-demand build), which is why targets go through `packable(…)` and not `.product(…)` directly. The package name is a location's last path component without `.git`; a name missing from the table is used as the package name as is.
- In binary mode only the products that were packaged exist, so with `products:` set, `packable(…)` should name one of them.
- SwiftFormat is switched off inside the block, so formatting doesn't fight the next `generate`.

The rest of `Package.swift` stays yours and uses the block's two names, which don't change between modes:

```swift
let package = Package(
  name: "App",
  dependencies: packableDependencies,
  targets: [
    .target(name: "App", dependencies: [packable("ShowcaseKit", from: "ShowcaseKit")])
  ]
)
```

### Where binaries come from

- **Declared:** `binary:` points at a binary package, either one this tool generated or a released one at a URL.
- **Built on demand:** without `binary:`, the source is packaged with the same pipeline as `build` and cached in the package's `.build/packable-cache` (override with `cache:` in `packable.yml`). Local sources are rebuilt only when their [build checksum](#skipping-unchanged-builds) changes: their files, their dependencies' files, the build settings or the toolchain. Remote sources are resolved by SwiftPM and cached per version. `.build` isn't committed, so run `generate` after cloning, and after `swift package clean` or `swift package reset` (both delete it), to fill the cache again.

The cache holds one folder per entry. Dynamic builds get a `-dynamic` suffix, and static builds with `debug-info: true` or `debug-objects: true` a `-debug-info` or `-debug-objects` suffix, so switching those back and forth doesn't rebuild:

```
.build/packable-cache/
├── ShowcaseKit/local/ShowcaseKit-binary/            # local source
├── ShowcaseKit/local-debug-objects/debug-objects/   # debug-objects: true keeps them next to the binary
├── Logging/1.6.1-dynamic/Logging-binary/            # remote source, by resolved tag
├── Logging/resolver/                                # throwaway package that resolves the remote source
└── Kit/rev-4f2c1e0a1b2c/Kit-binary/                 # branch or revision: rev-<first 12 of the commit>
```

### Checks

- **Clean switch:** `use` clears `.build` (keeping checkouts, downloads, the lock file, sourcekit-lsp's `index-build` and `packable-cache`), because objects left from the other mode break linking. `--no-clean` skips it. If another SwiftPM process holds the package's lock, the clean is skipped with a warning. In Xcode, also run Product › Clean Build Folder.
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

- **One XCFramework per module.** Every module a product depends on (C modules and third-party dependency modules included) gets its own XCFramework, and the generated `Package.swift` groups them into a product with the same name. That keeps `import` relationships between modules working in binary form. Link all of a product's XCFrameworks into an app, not only the top-level one. Empty modules that nothing imports, such as the `Sharing1`/`Sharing2` version markers in swift-sharing, are left out: they have no code, and SwiftPM's dependency scans show no module needs them. A product's own targets are always kept, and if a scan is missing nothing is left out. Code that checks `#if canImport(Sharing2)` against the binaries sees `false`.
- **System library targets.** A `.systemLibrary` target that a packaged module depends on (for example `GRDBSQLite` in GRDB) gets an XCFramework with its module map, headers and an empty binary, because modules whose interface imports it can't compile without it. Its `link` directive still links the system library.
- **Resources work through the generated package.** For a static module with resources, the generated `Package.swift` renames its binary target to `<Module>Binary` and adds a small target named `<Module>` that carries the original resource files (under `Resources/<Module>/`). SwiftPM and Xcode process them for the client's platform and install `<Package>_<Module>.bundle` where the compiled `Bundle.module` looks for it, so nothing has to be copied by hand. The bundle name comes from the package the module was built in, so a dependency's carriers (for example RevenueCatUI's) sit in a small local package with that dependency's name, `Packages/<Package>-resources/`, which the generated package pulls in through a link target `<Package>Resources`. Declared `.process`/`.copy` resources are carried, plus the types SwiftPM picks up implicitly (asset catalogs, `.xib`, `.storyboard`, `.lproj`, `.xcstrings`, Core Data and Metal files). The bundle is also inside each static framework, for apps that use an XCFramework directly without the package; those apps must copy it into their bundle themselves.
- **Interface verification failures.** Some libraries (for example swift-collections 1.7.x) emit `.swiftinterface` files that don't verify with the current compiler. Pass `--skip-interface-verification` in that case; the tool then also keeps the compiled `.swiftmodule` files, so clients using the same compiler version can still import the modules.
- <a id="debug-info-in-static-frameworks"></a>**Debug info in static frameworks.** By default a static framework's binary is SwiftPM's prelinked `<Module>.o`. `ld -r` doesn't copy DWARF into it, only a debug map pointing at the object files in the scratch folder, so once the framework is used elsewhere (or the scratch folder is gone) lldb can't show its sources, and xcsrclink reports `no debug info with source paths`. There are two ways to keep it:

  | | `--debug-info` | `--debug-objects <dir>` |
  |---|---|---|
  | Debug info lives in | the framework: its binary is an archive of the target's object files | `<dir>/<Module>/<platform>/<arch>/`: those objects, which the framework's debug map points at |
  | Framework | about 2.5× larger | same size as the default |
  | Linking | the app loads only the members it references, as with any static library Xcode builds: a file nothing references by symbol, such as one that only adds a protocol conformance used through `as?`, is left out unless the app links with `-ObjC` or `-all_load` | same as the default |
  | Debugging works | wherever the framework goes | while `<dir>` stays at that path, on that machine |
  | xcsrclink | point it at the framework | point it at `<dir>` |

  Either way the debug info holds the build machine's absolute source paths, which xcsrclink maps to a local checkout. With `--debug-objects`, `packable-metadata.json` records the folder and its modules under `debugObjects`, and an app's dSYM includes the library's DWARF only if the folder exists when the app is built. Dynamic frameworks need neither: their dSYMs are made while the object files still exist. How the debug map reaches the app is in [docs/debug-info.md](docs/debug-info.md).
- **Packages that don't compile with library evolution.** Some code builds normally but fails with `-enable-library-evolution`. Pass `--disable-library-evolution` to build without it. The modules are then not resilient, so no `.swiftinterface` files are emitted (the compiler only supports them with library evolution): each framework carries the compiled `.swiftmodule` files, the XCFrameworks are created with `-allow-internal-distribution`, and the tool warns that clients must use the same Swift compiler as the build. On another compiler they fail to import. `--skip-interface-verification` has no effect in this mode.
- **Any target layout.** Targets with a custom `path:` (including `path: "."` narrowed with `sources:`/`exclude:`) and the `Source/`, `src/`, `srcs/` default folders work. Resources come from SwiftPM's own resolved list (`swift package describe`), so `exclude:` and implicit resource types match what SwiftPM builds; asset catalogs, which that list leaves out, are added from a scan of the target folder. Localized files keep their `.lproj` folders, where SwiftPM reads the language from; and only header files are copied into a framework's `Headers/`, even when public headers sit next to sources (`publicHeadersPath: "."`).
- **Macro and binaryTarget dependencies** aren't packaged yet.
- Apple platforms only.

## Development

```bash
swift test   # Unit tests + an end-to-end test (packages Tests/.../Fixtures/Demo, then builds and runs a client against the output)
```

## License

MIT. See [LICENSE](LICENSE).
