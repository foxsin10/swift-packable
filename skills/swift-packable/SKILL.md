---
name: swift-packable
description: Use when packaging a Swift package's library products into XCFrameworks or a binary Package.swift, when switching SwiftPM dependencies between source and prebuilt binary, when writing or editing a packable.yml, or when a swift-packable / `swift packable` command, flag, output folder or error message comes up.
---

# swift-packable

`swift-packable` turns a Swift package's library products into XCFrameworks plus a binary `Package.swift`, and lets a client package flip each dependency between source and binary from a `packable.yml`. It runs on SwiftPM's Swift Build engine, Apple platforms only.

Check it is installed with `swift-packable --version` (prints the tool version, e.g. `0.1.0`). If it isn't, run `make install` in the swift-packable repo (release build copied to `~/.local/bin`; `PREFIX=/usr/local` to change), or build it with `swift build -c release` and run `.build/release/swift-packable`. It needs full Xcode (not only Command Line Tools) and the SDK of every platform you build. For every `packable.yml` key, read [packable-yml.md](references/packable-yml.md). For any flag, `swift-packable help <subcommand>` is authoritative.

## Commands

| Command | What it does |
|---|---|
| `swift-packable list [<pkg>]` | Show library products, targets, declared platforms and the slices built by default. Run it first on an unfamiliar package. |
| `swift-packable [build] [<pkg>] [options]` | Build XCFrameworks. `build` is the default subcommand. |
| `swift-packable generate` | Write the dependency block into the client's `Package.swift` from `packable.yml`. |
| `swift-packable use source\|binary <names…>` / `--all` | Change `mode:` in `packable.yml`, regenerate, clear `.build`. |

`swift packable …` works too once the binary is on PATH (the `swift` driver runs any `swift-<name>` executable).

## Building XCFrameworks

```bash
swift-packable path/to/MyPackage                                  # every library product, manifest platforms
swift-packable path/to/MyPackage -p MyLib --platform ios,ios-simulator,macos -o build/MyLibBinary
swift-packable path/to/MyPackage --linkage dynamic
swift-packable path/to/MyPackage --zip --base-url https://example.com/releases/1.0.0
```

| Option | Use |
|---|---|
| `-p, --product` | Product to package; repeat for several. Default: all library products. |
| `--platform` | `macos`, `maccatalyst`, `ios`, `ios-simulator`, `tvos`, `tvos-simulator`, `watchos`, `watchos-simulator`, `visionos`, `visionos-simulator`; repeat or comma-separate. Default: the manifest's `platforms:` (device + simulator each), or macOS + iOS when none is declared. |
| `--arch` | Per-slice architectures: `ios-simulator=arm64`, `macos=arm64,x86_64`. |
| `--deployment-target` | Override, e.g. `ios=15.0` (device and simulator). |
| `-o, --output` | Default: `<package>-binary` next to the package. |
| `-c, --configuration` | `release` (default) or `debug`. |
| `--linkage` | `static` (default) or `dynamic`. |
| `--zip` / `--base-url` | Zip each XCFramework with its checksum; `--base-url` (requires `--zip`) makes the generated manifest use `url:` + `checksum:`. |
| `--skip-interface-verification` | When emitted `.swiftinterface` files don't verify. Also keeps compiled `.swiftmodule`s. |
| `--include-binary-swiftmodules` | Keep compiled `.swiftmodule`s without skipping verification. |
| `--disable-library-evolution` | When the package doesn't compile with `-enable-library-evolution`. No `.swiftinterface`s are emitted, only compiled `.swiftmodule`s (so `--skip-interface-verification` isn't needed); clients must use the same compiler. |
| `--debug-info` | Static frameworks keep DWARF (archive of per-file objects instead of the prelinked `.o`), so lldb/xcsrclink can map sources. Larger; the app loads only referenced members (`-ObjC`/`-all_load` to load all). Dynamic frameworks always have dSYMs. |
| `--bundle-id-prefix`, `--framework-version` | `CFBundleIdentifier` prefix (default `packable`) and bundle version (default `1.0.0`). |
| `--scratch-path` | Default `<package>/.build/packable`. A new one is seeded from the package's `.build` dependencies as APFS clones (no extra disk). To reclaim an old duplicate, delete its `checkouts`, `repositories`, `artifacts` and `workspace-state.json`. |
| `-Xswiftc`, `-Xcc`, `-Xlinker` | Pass-through flags (`-Xlinker` also reaches the dylib link with `--linkage dynamic`). |
| `--rebuild` | Build even when the output is up to date (see below). |
| `-v` | Stream `swift build` output. Use it when a build fails. |

Output:

```
MyPackage-binary/
├── Package.swift            # same library product names, all binaryTargets
├── XCFrameworks/
│   ├── MyLib.xcframework    # one XCFramework per module: dependency, C and system library modules included
│   └── MyLibCore.xcframework
├── Resources/<Module>/      # static only: resource carriers for the package's own modules
├── Packages/<Dep>-resources/ # static only: a dependency's carriers, in a package named after it
└── Links/<Dep>/             # link target that pulls that package in
```

Clients point their dependency at that folder (or the published URL) instead of the source; `import`s stay the same. Every generated binary package also has `packable-metadata.json` (source tag/commit, the modules it bundles, and the build checksum).

**Unchanged builds are skipped.** The build checksum is a SHA-256 of the file contents of the package and every package in its graph (minus `.build`, `.git`, `.swiftpm`, output and scratch folders), the output-shaping options, `swift --version`, `xcodebuild -version` and the `swift-packable` binary. If it matches the existing output and the XCFrameworks are all there, the command prints `✔ Up to date` and builds nothing. Modification dates don't count. Use `--rebuild` to force a build.

What is handled for you:

- **Module closure.** Each product's XCFrameworks are the modules it actually links, remote dependencies included. Link all of them into an app, not only the top-level one. Empty modules nothing imports (e.g. swift-sharing's `Sharing1`/`Sharing2` version markers) are left out and logged as `skipping <Module>`; `#if canImport(...)` on them is then false.
- **System library targets** (`.systemLibrary`, e.g. GRDB's `GRDBSQLite`) that a packaged module depends on get an XCFramework with the module map, headers and an empty binary, so interfaces that import them compile.
- **Resources.** For a static module with resources, the generated manifest renames the binary target to `<Module>Binary` and adds a carrier target `<Module>` holding the resource files (localized `.lproj` files and asset catalogs included), so `Bundle.module` works. A dependency's carriers go in `Packages/<Dep>-resources/`, a local package with the dependency's name, so the bundle keeps the `<Dep>_<Target>` name its code looks for. Dynamic frameworks keep the bundle inside the framework and need no carrier.
- **Any target layout.** Custom `path:`, `sources:`/`exclude:`, `Source/`, `src/`, `srcs/`, `publicHeadersPath: "."`.
- **Dynamic frameworks** link their dependency frameworks via `@rpath`, carry dSYMs, and set `MinimumOSVersion` outside macOS.

## Switching a client between source and binary

1. Put `packable.yml` next to the client's `Package.swift` (keys: [packable-yml.md](references/packable-yml.md)):
   ```yaml
   dependencies:
     ShowcaseKit:
       mode: source
       source: { path: ../ShowcaseKit }
   ```
2. Run `swift-packable generate`. It inserts `packableDependencies` and `packable(_:from:)` between `// packable:begin` and `// packable:end` (full block and options in [packable-yml.md](references/packable-yml.md)).
3. Use those two names in the rest of the manifest. They don't change between modes. `packable("<product>", from: "<packable.yml key>")` resolves the package name for the current mode, so never write `.product(…)` for these dependencies:
   ```swift
   let package = Package(
     name: "App",
     dependencies: packableDependencies,
     targets: [
       .target(name: "App", dependencies: [packable("ShowcaseKit", from: "ShowcaseKit")])
     ]
   )
   ```
4. Flip with `swift-packable use binary ShowcaseKit` (or `use source --all`). `use` clears `.build` except checkouts, downloads, the lock file, `index-build` and `packable-cache`; `--no-clean` skips that. `generate` and `use` both take `--package-path`, `--config`, `--rebuild` and `-v`.

Binary mode uses `binary:` when declared; otherwise it packages `source` with the build pipeline and caches it in the package's `.build/packable-cache` (or `cache:`). Local sources rebuild only when their build checksum changes (their files, their dependencies' files, settings or toolchain); remote sources are cached per version. `--rebuild` (on `generate` or `use`) forces a rebuild and moves remote sources to their newest allowed version.

## Common mistakes

| Symptom | Fix |
|---|---|
| `xcodebuild -create-xcframework` fails / not found | Command Line Tools are selected. `sudo xcode-select -s /Applications/Xcode.app`. |
| A platform slice fails to build | Its SDK is missing: `xcodebuild -showsdks`, then `xcodebuild -downloadPlatform iOS` (or tvOS, watchOS, visionOS). |
| Interface verification error (e.g. swift-collections 1.7.x) | Rebuild with `--skip-interface-verification` (`skip-interface-verification: true` in `packable.yml`). Clients should then use the same compiler version. |
| Compile error only with library evolution (passes with plain `swift build`) | Rebuild with `--disable-library-evolution` (`disable-library-evolution: true` in `packable.yml`). Clients must then use the same compiler version. |
| lldb shows no source for a static framework, or xcsrclink says `no debug info with source paths` | The prelinked object only has a debug map into the scratch folder. Rebuild with `--debug-info` (`debug-info: true` in `packable.yml`). |
| Link errors right after switching modes | Stale objects. `use` cleans `.build` unless `--no-clean` or another SwiftPM process held the lock (it warns); in Xcode also Product › Clean Build Folder. |
| Hand edits inside `// packable:begin … end` disappear | That block is regenerated. Change `packable.yml` and rerun `generate`. |
| `generate` stops naming a duplicate module | A binary already bundles a module that another entry also provides. Drop the separate entry, or keep both from source. |
| Warning that a binary was built from a different tag/commit | Version drift between `binary:` and `source:`. Rebuild or repoint the binary. |
| ``Couldn't find `Name:` (in block style)`` from `use` | The dependency is written in flow style (`Name: { … }`). Rewrite it as a block mapping; locations may stay flow style. |
| `'<name>' isn't declared in packable.yml` | `use` takes `packable.yml` keys, not product or package names. |
| Validation error on a location | A `path` takes no version; a `url` needs exactly one of `from`, `exact`, `up-to-next-minor`, `branch`, `revision`. |
| Fresh clone, or after `swift package clean`/`reset`, the binary package path is missing | Run `swift-packable generate` to rebuild the cache in `.build/packable-cache`. |
| `swift run` with dynamic frameworks: `Library not loaded: @rpath/…` | `swift run -Xlinker -rpath -Xlinker @executable_path`, or `--build-system native`. Apps and `swift test` are fine. |
| App using a static `.xcframework` directly (no package) can't find resources | Copy `<Package>_<Module>.bundle` from inside the framework into the app bundle. |

Not supported yet: macro targets and `binaryTarget` dependencies. Apple platforms only.
