# Debug info for static frameworks

Status: both are implemented. `--debug-info` embeds the debug info in the frameworks (option 1); `--debug-objects <dir>` keeps it in a separate folder (option 2). In `packable.yml` they're `debug-info: true` and `debug-objects: true`.

## The problem

A static framework's binary is SwiftPM's prelinked `<Module>.o`, which Swift Build makes with:

```bash
clang -Xlinker -reproducible -target <triple> -r -isysroot <sdk> \
  -filelist <Target>-t.build/Objects-normal/<arch>/<Target>.LinkFileList -nostdlib \
  -Xlinker -add_ast_path -Xlinker <Module>.swiftmodule \
  -o Products/<Configuration>-<sdk>/<Module>.o
```

`ld -r` never copies DWARF into its output (no linker flag changes that). The prelinked object holds only a **debug map**: `N_OSO` stabs with the absolute paths of the per-file objects in the scratch folder, which do hold the DWARF, and an `N_AST` stab pointing at the `.swiftmodule`.

When an app links the static framework, its linker copies those stabs into the app. lldb (in Debug, without a dSYM) and `dsymutil` (when Xcode makes the app's dSYM) then open the per-file objects at the recorded paths:

```bash
nm -ap <app> | grep OSO
# … <scratch>/out/Intermediates.noindex/<Package>.build/Release/<Target>-t.build/Objects-normal/arm64/<File>.o
```

So on the machine that packaged the framework, while its scratch folder exists, the sources are debuggable. Anywhere else:

- lldb leaves file:line breakpoints pending and shows assembly.
- `xcsrclink info`/`link` on the framework reports `no debug info with source paths`, since the framework itself has no DWARF.

lldb can't be pointed at moved objects. Tested with the objects moved away, the breakpoint stays pending with either setting:

| Setting | Effect on `N_OSO` paths |
|---|---|
| `target.source-map <old> <new>` | none (maps source paths only) |
| `target.debug-file-search-paths <dir>` | none |

Dynamic frameworks aren't affected: `dsymutil` follows the debug map while the objects still exist, and the dSYM ships in the XCFramework.

## How the debug map reaches the app

Apple's linker never copies DWARF into a linked output. It writes a debug map instead, as stabs in the symbol table. The same rule applies at every stage, so the debug map passes through unchanged and always points at the objects that hold the DWARF:

| Stage | File | DWARF | Debug map (`nm -ap`) |
|---|---|---|---|
| Compile | `Objects-normal/<arch>/Demo.o` | yes (6 `__debug_*` sections) | none |
| Prelink (`ld -r`) | `Products/<Configuration>/Demo.o`, then the framework binary via `libtool` | none | `SO` source dir and file, `OSO <scratch>/…/Objects-normal/arm64/Demo.o`, then `BNSYM`/`FUN`/`ENSYM` per function and `STSYM`/`GSYM` per variable |
| App link (`ld`) | the app executable | none | the library's `SO`/`OSO`/`FUN` entries copied through, next to the app's own `OSO …/main.o` |
| Debug | lldb, or `dsymutil` for the app's dSYM | read from each `OSO` object | — |

When the linker reads an input object that has DWARF (the app's `main.o`), it writes a new `OSO` entry for it. When the input already carries stabs (the prelinked object), it copies them and relocates their addresses. For example, `Demo.answer()` is at `0x0` and `Demo.checksum` at `0xac` in the per-file object. In the client they sit at `0x100001d18` and `0x100001dc4`, the same `0xac` apart. So the app's map names the per-file objects directly, never the prelinked object or the framework. `dsymutil --dump-debug-map <app>` shows them as its object list:

```
- filename: '<client-scratch>/…/Client-p.build/Objects-normal/arm64/main.o'
- filename: '<scratch>/…/Demo-t.build/Objects-normal/arm64/Demo.o'
- filename: '<scratch>/…/CDemo-t.build/Objects-normal/arm64/cdemo.o'
- filename: '<debug folder>/macos/arm64/Core.o'          # the relocated prototype
```

To find a function's source, lldb (or `dsymutil`) looks the address up in the map, opens that `OSO` object and reads its DWARF at the matching object address. The DWARF holds the absolute source paths, which `target.source-map` (what `xcsrclink` writes) can remap.

Details that matter for the design:

- **Timestamps.** An `OSO` entry's value is normally the object's modification time, and lldb ignores an object whose time doesn't match. The prelink runs with `-Xlinker -reproducible`, which records `0`, so copied objects don't need their dates preserved. A relocating prelink must keep that flag.
- **Stripping.** `strip -S`, or `-Xlinker -S` at prelink, removes the stabs and with them every way back to the DWARF. Stripping the app after `dsymutil` has run (Xcode's `STRIP_INSTALLED_PRODUCT`) is fine.
- **Option 1 differs.** Archive members carry DWARF themselves, so the app's map names the member inside the framework copy that the client's build placed in its products folder: `OSO <client-scratch>/out/Products/Debug/DemoCore.framework/DemoCore(Core.o)` (in Xcode, under DerivedData). The DWARF then lives with the app's own build, not in a folder of its own.
- **Swift module info.** In this test, neither the prelinked object nor the app had an `AST` entry for the library's `.swiftmodule`. Breakpoints and source lines work. Whether `po` in library frames finds the module still needs checking.

## Option 1: archive of per-file objects (implemented: `--debug-info`)

Each static framework's binary is `libtool -static -filelist <Target>.LinkFileList`, so the members carry their DWARF.

- Works anywhere; `xcsrclink` reads the framework directly.
- About 2.5× larger output (8.6 MB vs 3.5 MB for a typical app module). The app binary doesn't grow; DWARF goes to its dSYM.
- **Linking changes.** The app's linker loads only members it references, as with any static library Xcode builds. A file nothing references by symbol, such as one that only adds a protocol conformance used through `as?`, is dropped unless the app links with `-ObjC` or `-all_load`.

## Option 2: separate debug objects (implemented: `--debug-objects <dir>`)

The framework stays as lean as the default and links exactly like it, but the debug info goes to a folder of your choice. For each static module slice:

1. Copy the objects listed in `<Target>.LinkFileList` and the per-architecture `Objects-normal/<arch>/<Module>.swiftmodule` to `<dir>/<Module>/<platform>/<arch>/`, with a new file list naming the copies.
2. Prelink the copies again, so the `N_OSO` stabs point into `<dir>`:
   ```bash
   xcrun ld -r -arch <arch> -reproducible -filelist <dir>/<Module>/<platform>/<arch>/<Target>.LinkFileList \
     -add_ast_path <dir>/<Module>/<platform>/<arch>/<Module>.swiftmodule -o <Module>.o
   ```
   `ld -r` takes the platform and deployment target from its inputs. For the Demo fixture its output has the same symbols and `LC_BUILD_VERSION` as Swift Build's own prelinked object, so no target triple or SDK is needed.
3. Make the framework binary from that object with `libtool -static`, as by default.

Other behavior:

- A module's folder in `<dir>` is cleared the first time a run writes it. Other folders are left alone, so one `<dir>` can serve several packages, as long as they don't package the same module.
- The build checksum includes the folder's path (the frameworks record it), and the folder isn't hashed as input. A build whose debug objects are missing isn't up to date.
- `packable-metadata.json` records `debugObjects: { path, modules }`.
- With `--linkage dynamic` the option is ignored with a warning, since dSYMs already carry the debug info.
- On demand, `debug-objects: true` puts the folder in the cache entry (`<cache>/<name>/<entry>-debug-objects/debug-objects/`), next to the binary package. For remote sources the scratch folder is deleted after the build, and the debug objects stay.

`xcsrclink` (0.4.0) reads the folder's loose `.o` files: `xcsrclink link <dir> --source <checkout>`. Given the framework, it reports `no source paths in debug info`, because it doesn't follow `N_OSO` entries.

### Verification

- End-to-end test `debugObjectsOutliveTheBuildFolder`: the Demo fixture's frameworks have no DWARF, and all their `OSO` entries point into `<dir>`. After the client is built, the packaging scratch folder is deleted, and `dsymutil` on the client still produces a dSYM with Demo.swift, Core.swift and cdemo.c.
- Prototype on the Demo fixture: with the scratch folder moved away, `breakpoint set --file Core.swift --line 5` bound (`Client`Core.value() at Core.swift:6:3`) and stopped on `run`. With the sources moved too, `xcsrclink link <debug folder> --source <new sources> --lldbinit <file>` wrote `target.source-map`, and lldb listed the lines.

### Limits

- **`N_OSO` paths are absolute.** The debug folder must stay at the path used when packaging. On another machine, or after moving it, the paths inside the framework need rewriting. `xcsrclink`'s patch strategy rewrites source paths in `.a`/dSYM files today; rewriting the `N_OSO`/`N_AST` paths of a static library (new path no longer than the old, like its other patches) would be a new `xcsrclink` feature.
- **Debug folder must be present when the app is built** for its dSYM (Release, `dwarf-with-dsym`) to include the library's DWARF, and when debugging a Debug build.
- The debug objects hold the build machine's absolute source paths, as any `-g` build does; `xcsrclink` maps them to a local checkout.

## Open questions

- Should `xcsrclink` follow a static library's `N_OSO` entries (or read `debugObjects` from `packable-metadata.json`), so `xcsrclink link <framework>` works for option 2 too?
- Rewriting `N_OSO` paths after the folder moves (see Limits).
