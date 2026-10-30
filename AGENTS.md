# Agent notes

## Keep docs in sync

`README.md` and the agent skill in `skills/swift-packable/` (`SKILL.md`, `references/packable-yml.md`) describe the same CLI. When you change a command, flag, default, `packable.yml` key, output layout or error message, update both in the same change.

## Versioning

The tool version is `version:` in the `CommandConfiguration` in `Sources/swift-packable/SwiftPackable.swift` (printed by `swift-packable --version`).

- Bump it when a change ships, following semver: patch for fixes, minor for new commands, flags or `packable.yml` keys, major for breaking changes.
- Tag the release only after final verification passes (`swift test`, plus `Examples/run-showcase.sh` for build or switching changes). The tag is the bare version, for example `git tag 0.2.0`, on the commit that contains that `version:`.
- Keep the two in sync: the latest tag must equal `version:` at that commit. Never tag before verification, and never leave a bumped version untagged once it's verified.
