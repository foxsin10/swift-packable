# Examples

Showcase of `swift-packable` on a small library, with a client app that uses the
result. Everything runs offline.

```bash
Examples/run-showcase.sh      # ~2.5 min; outputs go to Examples/build/
```

## The packages

| Package | Role |
| --- | --- |
| [`ShowcaseKit`](ShowcaseKit) | The source library that gets packaged. Two products, `ShowcaseKit` and `ShowcaseStats` |
| [`MathUtils`](MathUtils) | Stands in for a third-party dependency of `ShowcaseStats` (referenced by path) |
| [`ShowcaseApp`](ShowcaseApp) | Client executable that depends on the generated binary package, `build/ShowcaseKit-binary` |
| [`SwitchableApp`](SwitchableApp) | Client that declares ShowcaseKit in [`packable.yml`](SwitchableApp/packable.yml) and switches it between source and binary |

`ShowcaseKit` covers the cases the tool has to handle:

| Module | What it exercises |
| --- | --- |
| `ShowcaseKit` | Public Swift API, an `@objc` class (merged `-Swift.h` header), a resource bundle, `@_exported import ShowcaseCore` |
| `ShowcaseCore` | Internal Swift module that ShowcaseKit depends on and re-exports |
| `CChecksum` | C module with public headers in `include/` (packaged with a framework module map) |
| `ShowcaseStats` | Second product, depending on another package |
| `MathUtils` | A dependency package's module, packaged automatically |

## What the script shows

1. **Inspect** the package: `swift-packable list Examples/ShowcaseKit`
2. **Package everything** for the manifest's platforms (macOS, iOS, iOS Simulator):
   `swift-packable Examples/ShowcaseKit -o Examples/build/ShowcaseKit-binary`
   This produces 5 XCFrameworks (one per module) and a `Package.swift` with both products as binary targets.
   Running the same command again prints `✔ Up to date` without building: the build checksum
   (sources, dependencies, options, toolchain) hasn't changed.
3. **Consume the binaries**: `ShowcaseApp` is built and run on macOS, then built for the iOS Simulator.
   Its `import ShowcaseKit` / `import ShowcaseStats` are the same as with the source package.
   Expected output:
   ```
   ShowcaseKit 1.0.0, linked from XCFrameworks
     greet (en): Hello, Swift!
     greet (zh): 你好，Swift！
     greet (fr): Bonjour, Swift !
     crc32("hello"): 0x3610A686
     objc greeter: Hello, Objective-C!
     stats: count=8 mean=5.0 sd=2.0
   ```
4. **Narrow the build**: one product, one platform, one architecture:
   `swift-packable Examples/ShowcaseKit -p ShowcaseStats --platform macos --arch macos=arm64`
5. **Release**: zipped XCFrameworks, SwiftPM checksums, and a `Package.swift` pointing at a hosting URL:
   `swift-packable Examples/ShowcaseKit --zip --base-url https://example.com/showcasekit/1.0.0`
6. **Switch between source and binary**: `SwitchableApp` runs with ShowcaseKit from source, then
   `swift-packable use binary ShowcaseKit` packages ShowcaseKit on demand (no `binary:`
   location is declared) and rewrites the block in `Package.swift`; the app runs the same on the
   binaries. Switching back to source and to binary again reuses the cached binary. The cache
   is `Examples/SwitchableApp/.build/packable-cache`; the script leaves the app in source mode.

## Resources

`ShowcaseKit` reads `greetings.json` through `Bundle.module`. In the generated binary package,
its binary target is named `ShowcaseKitBinary`, and a small `ShowcaseKit` target carries the
original resource files (`build/ShowcaseKit-binary/Resources/ShowcaseKit`). SwiftPM, or Xcode,
processes them for the client's platform and installs `ShowcaseKit_ShowcaseKit.bundle` where
the compiled code looks for it. That's why `ShowcaseApp` and `SwitchableApp` run with a plain
`swift run`, without copying anything.

## Using the output from Xcode

Run step 2 (or the whole script), then in Xcode choose **File → Add Package Dependencies… →
Add Local…**, select `Examples/build/ShowcaseKit-binary`, and add the `ShowcaseKit` and/or
`ShowcaseStats` products to your app target.
