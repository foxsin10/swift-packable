---
name: swiftformat
description: Umbrella's Swift house style, enforced by the locally installed SwiftFormat. Use when writing or editing any `.swift` file in this repo, when asked to format or lint Swift, or when a SwiftFormat rule name comes up.
---

# SwiftFormat house style

The rules live in [`swiftformat.config`](swiftformat.config), next to this file. It is the single source of truth: the user's personal SwiftFormat config (from `~/Workspace/CoinFind/.swiftformat`) adapted to this repo — Swift 6.0, and `wrapGuardStatementBodies` in place of the deprecated `wrapConditionalBodies`.

The binary is Homebrew's `swiftformat` (0.64.x). Run every command from the repo root.

## Steps

1. **Write in the house style** (summary below) so the formatter has little to change.
2. **Format the files you touched**, and only those:
   ```sh
   swiftformat --config .claude/skills/swiftformat/swiftformat.config <changed .swift files>
   ```
3. **Lint to confirm**:
   ```sh
   swiftformat --lint --config .claude/skills/swiftformat/swiftformat.config <changed .swift files>
   ```
   Done when it prints `0/N files require formatting.`
4. **Build** (`swift build`, piped through `xcsift`) if the formatter moved declarations or rewrote expressions, since `organizeDeclarations`, `redundantSelf` and `hoistTry` edit code, not just whitespace.

To understand a finding, run `swiftformat --ruleinfo <ruleName>`; it prints the rule's purpose, options, and before/after examples. `swiftformat --rules` lists every rule with its default state.

To exempt code, use SwiftFormat directives, narrowest first: `// swiftformat:disable:next <rule>`, then `// swiftformat:disable <rule>` … `// swiftformat:enable <rule>`.

## House style at a glance

Where this config differs from SwiftFormat's defaults, or from what you would write by habit:

- **Layout**: 2-space indent, 90-column limit, LF line endings, `} else {` and `guard … else {` on the same line, `{}` with no inner space.
- **Bodies always wrap**: every `if`, `guard`, loop, function, computed property, `switch` case and `enum` case body goes on its own line. No one-liners like `guard let x else { return }`.
- **Wrapped lists** (arguments, parameters, collections): any list that would push a line past 90 columns gets one element per line, broken before the first element, closing paren balanced on its own line:
  ```swift
  public init(
    id: NodeID,
    target: String,
    linesOfCode: Int = 0
  ) {
  ```
- **Wrap-friendly code**: at 90 columns the formatter splits whatever it can, including subscripts inside closures. Pull long sub-expressions into named `let`s so the wraps land at clean points. String literals are never split, so keep long messages in their own `let` or break them with `+`.
- **Declaration order** (`organizeDeclarations`, visibility mode): inside types, group members by lifecycle then visibility — init first, then `public` → `internal` → `fileprivate` → `private`. No MARK comments on types or extensions.
- **Extensions**: put the access modifier on the `extension` itself (`public extension Foo { … }`), not on each member.
- **Expressions**: drop explicit `self.`; `foo.isEmpty` over `count == 0`; hoist `try`/`await`/pattern `let` to the outermost position (`if case let .a(x, y)`); constants on the right of comparisons; `a ..< b` with spaces; `T?` over `Optional<T>`; `some P` over a single-use generic.
- **Unused arguments** are renamed `_`, closures and functions alike.
- **Comments**: `///` doc comments on declarations, before any attributes; `//` lines instead of `/* */` blocks.
- **Acronyms** `URL` and `UUID` are fully capitalized in identifiers (`baseURL`, not `baseUrl`).
- **Number literals**: uppercase hex digits, grouped with `_` (`1_000_000`, `0xFFFF_FFFF`).
- **Tests**: prefer Swift Testing (`@Test`, `#expect`) over XCTest.
