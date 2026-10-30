# XcframeworkPackable (`xcframework-packable`)

Compiles a Swift package's source code into binary **XCFrameworks** and generates a binary `Package.swift` that clients can depend on directly.

The whole pipeline is built on Swift Package Manager's own capabilities:

| Step | SwiftPM / Xcode capability used |
| --- | --- |
| Resolve the dependency graph and read each package's manifest | `swift package show-dependencies --format json`, `swift package dump-package` |
| Cross-compile for each platform and architecture | `swift build --triple … --sdk …` (Swift Build engine, with library evolution and `.swiftinterface` emission enabled) |
| Work out which modules each product actually links | The products folder is emptied before each build; the `<Module>.o` files left afterwards are that product's module closure (remote dependencies included) |
| Merge architectures | `lipo`, a union of the `.swiftmodule` folders, and `-Swift.h` headers merged the way Xcode does it |
| Wrap each module in a static framework, then combine them into an XCFramework | `libtool -static`, `xcodebuild -create-xcframework` |
| Generate a binary package for distribution | `.binaryTarget`, with optional zipping and `swift package compute-checksum` |

## Requirements

- macOS with Xcode (and the SDKs for the platforms you build)
- A toolchain that supports `swift build --build-system swiftbuild` (verified on Swift 6.4 / Xcode 27.1)

## Installation

```bash
swift build -c release
cp .build/release/xcframework-packable /usr/local/bin/   # optional
```

## Usage

```bash
# Show the package's library products, declared platforms, and the slices built by default
xcframework-packable list path/to/MyPackage

# Build every library product; platforms come from the manifest's `platforms:` (iOS → device + simulator)
xcframework-packable path/to/MyPackage

# Choose products, platforms, and the output directory
xcframework-packable path/to/MyPackage -p MyLib --platform ios,ios-simulator,macos -o build/MyLibBinary

# Zip the XCFrameworks and generate a Package.swift with url + checksum (e.g. for GitHub Releases)
xcframework-packable path/to/MyPackage --zip --base-url https://example.com/releases/1.0.0
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
| `--zip` / `--base-url` | Zip each XCFramework, compute its checksum, and generate remote `binaryTarget`s |
| `--skip-interface-verification` | Skip `.swiftinterface` verification (see below) |
| `--include-binary-swiftmodules` | Keep the compiled `.swiftmodule` files in the XCFrameworks |
| `-Xswiftc` / `-Xcc` / `-Xlinker` | Pass flags through to `swift build` |
| `-v` | Show the full `swift build` output |

## Switching dependencies between source and binary

A client package can declare in `packable.yml` which dependencies it builds from source and which it links as XCFrameworks, and flip them with one command, like the CocoaPods binary plugins.

```yaml
# packable.yml, next to the client's Package.swift
dependencies:
  ShowcaseKit:
    mode: binary                          # source (default) | binary
    source: { path: ../ShowcaseKit }      # or { url: https://…, from: 1.2.0 }
    binary: { path: ../ShowcaseKit-binary }  # optional, see below
  Alamofire:
    source: { url: https://github.com/Alamofire/Alamofire.git, from: 5.9.0 }
```

```bash
xcframework-packable generate                  # write the dependency block into Package.swift
xcframework-packable use binary ShowcaseKit    # flip modes in packable.yml, regenerate, clear .build
xcframework-packable use source --all
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
- **Built on demand:** without `binary:`, the source is packaged with the same pipeline as `build` and cached in `~/Library/Caches/xcframework-packable` (override with `cache:` in `packable.yml` or `$XCFRAMEWORK_PACKABLE_CACHE`). Local sources are rebuilt only when their files change. Remote sources are resolved by SwiftPM and cached per version. The manifest refers to the shared cache through `$HOME`, so the same `Package.swift` works on every machine; run `generate` after cloning to fill the cache.

Per-dependency keys for on-demand builds: `products`, `platforms`, `skip-interface-verification`.

Checks:

- **Clean switch:** `use` clears `.build` (keeping checkouts, downloads, the lock file and sourcekit-lsp's `index-build`), because objects left from the other mode break linking. If another SwiftPM process holds the package's lock, the clean is skipped with a warning. In Xcode, also run Product › Clean Build Folder.
- **Duplicate modules:** a binary package bundles its dependencies' modules. If another entry provides one of them, `generate` stops and names the module (for example, MathUtils both bundled in the ShowcaseKit binary and declared on its own).
- **Version drift:** for declared binaries, `generate` warns when the binary was built from a different tag or commit than the source points at (from `packable-metadata.json`, written next to every generated binary package).
- **Rollback:** if regenerating fails, `use` restores `packable.yml`.

## Examples

[`Examples/`](Examples) has a showcase library (Swift + C modules, resources, an `@objc` API, a dependency package), a client app that uses the generated binaries, and a client that switches between source and binary with `packable.yml`. Run `Examples/run-showcase.sh` to see every use case end to end.

## Notes

- **One XCFramework per module.** Every module a product depends on (C modules and third-party dependency modules included) gets its own XCFramework, and the generated `Package.swift` groups them into a product with the same name. That keeps `import` relationships between modules working in binary form.
- **Resources work through the generated package.** For a module with resources, the generated `Package.swift` renames its binary target to `<Module>Binary` and adds a small target named `<Module>` that carries the original resource files (under `Resources/<Module>/`). SwiftPM and Xcode process them for the client's platform and install `<Package>_<Module>.bundle` where the compiled `Bundle.module` looks for it, so nothing has to be copied by hand. Declared `.process`/`.copy` resources are carried, plus the types SwiftPM picks up implicitly (asset catalogs, `.xib`, `.storyboard`, `.lproj`, `.xcstrings`, Core Data and Metal files). The bundle is also inside each static framework, for apps that use an XCFramework directly without the package; those apps must copy it into their bundle themselves.
- **Interface verification failures.** Some libraries (for example swift-collections 1.7.x) emit `.swiftinterface` files that don't verify with the current compiler. Pass `--skip-interface-verification` in that case; the tool then also keeps the compiled `.swiftmodule` files, so clients using the same compiler version can still import the modules.
- **Any target layout.** Targets with a custom `path:` (including `path: "."` narrowed with `sources:`/`exclude:`) and the `Source/`, `src/`, `srcs/` default folders work. Resources come from SwiftPM's own resolved list (`swift package describe`), so `exclude:` and implicit resource types match what SwiftPM builds, and only header files are copied into a framework's `Headers/`, even when public headers sit next to sources (`publicHeadersPath: "."`).
- **Macro and binaryTarget dependencies** aren't packaged yet.
- Apple platforms only.

## Development

```bash
swift test   # Unit tests + an end-to-end test (packages Tests/.../Fixtures/Demo, then builds and runs a client against the output)
```
