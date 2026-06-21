# Contributing to MacGet

Thanks for taking the time to contribute! MacGet is a solo-maintained, open-source
macOS download manager, and issues + PRs are genuinely welcome.

> **Naming:** the brand is **MacGet**, but every technical identifier — scheme,
> project file (`Macget.xcodeproj`), bundle ID (`com.suryansh.Macget`), and paths —
> is lowercase **`Macget`**. Use the lowercase form in code and commands.

## Ground rules

- **Be kind.** Assume good faith. This is a hobby project maintained in spare time.
- **One change per PR.** Small, focused PRs get reviewed and merged faster.
- **Open an issue first** for anything non-trivial (new features, behavior changes,
  refactors). It saves us both from wasted work.

## Getting set up

Full instructions are in [`SETUP.md`](SETUP.md). The short version:

```bash
git clone https://github.com/Suryansh-Codes2209/Macget.git
cd Macget
open Macget.xcodeproj      # then ⌘R to run, ⌘U to test
```

Requirements: **full Xcode** (not just Command Line Tools) and **macOS 26.4
(Tahoe)** or newer. No package manager step — the `.xcodeproj` is committed.

## Development workflow

1. Fork the repo and create a branch from `main`
   (`git checkout -b fix/short-description`).
2. Make your change.
3. **Run the tests** before pushing:
   ```bash
   xcodebuild test -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS'
   ```
4. Push and open a PR against `main`. Fill in the PR template.

CI (`.github/workflows/ci.yml`) builds and tests every push/PR — it must be green
to merge.

## Code conventions

These mirror [`CLAUDE.md`](CLAUDE.md), which is the authoritative reference. The
architecture is documented in [`docs/architecture.md`](docs/architecture.md).

- **The `Engine/` directory is high-stakes code.** Any change there **must** come
  with unit tests, and must respect the actor / `@Sendable` model. The engine is
  the heart of the app — bugs here corrupt downloads.
- **Concurrency:** `DownloadEngine`, `DownloadCoordinator`, `FileWriter`,
  `SpeedMeter`, `DownloadStore`, and `HostCapStore` are **actors**. View models are
  `@MainActor @Observable`. Mutate engine state only through engine actor methods —
  never mutate a `Download` from the UI.
- **Persisted state:** new fields on `Download` / `Chunk` / `AppSettings` must stay
  `Codable` **and** `Sendable`. The store does a whole-file read-modify-write, so
  don't add very large fields.
- **Bounds:** threads/chunks are clamped to **1–20** at every layer. Keep it that
  way.
- **Logging:** use `Log.app/engine/ui/net` from `Supporting/Logger+MacGet.swift`
  (subsystem `com.macget`). Don't `print`.
- **Networking:** use `URLSessionFactory.shared` everywhere — don't construct
  ad-hoc `URLSession`s. For network-touching tests, inject a stub `session:`
  (the engine types all accept one) rather than hitting the live network.

## Tests

Unit tests live in `MacgetTests/` (XCTest), UI tests in `MacgetUITests/`. Run one
suite while iterating:

```bash
xcodebuild test -project Macget.xcodeproj -scheme Macget -destination 'platform=macOS' \
    -only-testing:MacgetTests/ChunkPlannerTests
```

## Commit messages

Short, imperative, present tense: `Fix chunk demotion off-by-one`. Reference the
issue it closes (`Closes #123`) in the PR description.

## Reporting bugs & requesting features

Use the [issue templates](https://github.com/Suryansh-Codes2209/Macget/issues/new/choose).
For **security** issues, do **not** open a public issue — follow
[`SECURITY.md`](SECURITY.md).

## License

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
