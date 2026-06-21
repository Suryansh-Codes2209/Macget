<!-- Thanks for contributing to MacGet! Keep PRs small and focused. -->

## What & why

<!-- What does this change, and what problem does it solve? -->

Closes #

## Changes

<!-- Bullet the key changes. -->
-

## Testing

<!-- How did you verify this? Required for any Engine/ change. -->
- [ ] `xcodebuild test -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS'` passes
- [ ] Added/updated unit tests (required for `Engine/` changes)
- [ ] Manually verified the affected flow

## Checklist

- [ ] Follows the conventions in [CONTRIBUTING.md](../CONTRIBUTING.md) / [CLAUDE.md](../CLAUDE.md)
- [ ] Respects the actor / `@Sendable` model; UI mutates engine state only via engine methods
- [ ] New persisted fields stay `Codable` + `Sendable`; threads/chunks stay clamped 1–20
- [ ] No secrets, signing keys, or personal paths committed
