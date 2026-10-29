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

## Notes

- **One XCFramework per module.** Every module a product depends on (C modules and third-party dependency modules included) gets its own XCFramework, and the generated `Package.swift` groups them into a product with the same name. That keeps `import` relationships between modules working in binary form.
- **Frameworks are static.** A target with resources gets its `<Package>_<Target>.bundle` placed inside the framework, but the client app has to copy that bundle into its own bundle for `Bundle.module` to find it (the tool prints a reminder).
- **Interface verification failures.** Some libraries (for example swift-collections 1.7.x) emit `.swiftinterface` files that don't verify with the current compiler. Pass `--skip-interface-verification` in that case; the tool then also keeps the compiled `.swiftmodule` files, so clients using the same compiler version can still import the modules.
- **Macro and binaryTarget dependencies** aren't packaged yet.
- Apple platforms only.

## Development

```bash
swift test   # Unit tests + an end-to-end test (packages Tests/.../Fixtures/Demo, then builds and runs a client against the output)
```
