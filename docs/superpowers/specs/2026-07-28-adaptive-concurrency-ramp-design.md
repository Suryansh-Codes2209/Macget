# Adaptive concurrency ramp, host-cap decay, and endgame splitting

**Date:** 2026-07-28
**Status:** Approved, not yet implemented
**Area:** `Macget/Engine/` (download pipeline), `Macget/Persistence/HostCapStore.swift`, inspector UI

## Problem

Downloads reach full parallelism far too slowly, and some hosts never reach it at all.

`DownloadCoordinator.runDownload` pins `adaptiveCeiling` to `AdaptiveConcurrency.initialWorkers` (4) and `checkAdaptiveConcurrency` then adds **one** connection per probe, probing once every 12 publish ticks × 250 ms = **3 seconds**. With the default `threadCount` of 8 that is ~12 s to reach the user's configured parallelism; with the slider at `Download.maxThreadCount` (16) it is ~36 s. Files that finish inside that window never reach the parallelism the user asked for.

Three compounding defects make it worse than the arithmetic suggests.

**The probe's stopping rule is inverted.** `AdaptiveConcurrency.didImprove` keeps an added connection only when throughput rose ≥15%. But once the link is saturated, adding connection N+1 *correctly* produces no improvement — and the code reads that as "stop climbing." The signal cannot distinguish "this connection didn't help" from "nothing would have helped," and treats both as a reason to stop. On a fast link the probe therefore halts early precisely when extra connections were free.

**The stop is one-way.** `adaptiveProbeStopped = true` is never cleared. A single 3-second window that doesn't clear the threshold — TCP slow-start still ramping, a competing transfer on the same Wi-Fi — ends the climb for the remainder of that download.

**Learned host caps are permanent.** `noteRapidFailure` demotes on four sub-16 KB attempts inside a 10 s window and persists the result via `HostCapStore.recordCap`. Caps ratchet downward only, have no expiry, and nothing calls `clear(host:)` — there is no reset UI. A brief network drop fails *every* in-flight worker at once, trips the threshold instantly, and permanently halves that host. `checkAdaptiveConcurrency:630` then refuses to probe upward on every future download from it.

Separately, at the tail of a download: `fillFreedSlot` only assigns *unassigned* incomplete pieces. Once every remaining piece has a worker, a finishing worker exits and idles while one slow connection drains the last piece. `ChunkSplitter` already implements the fix (IDM's in-half division rule) but is reachable only from `adjustThreadCount`, i.e. when the user drags the thread slider.

## Goals

- Reach the user's configured connection count in ~1 s instead of 12–36 s.
- Stop misattributing local network faults to host hostility.
- Let learned caps heal; give the user a way to clear them.
- Keep every connection busy through the tail of a download.
- Make the above verifiable rather than assumed.

## Non-goals

- Raising `Download.maxThreadCount` above 16 or changing the default of 8.
- Per-chunk speed tracking (see "Deliberate simplifications").
- Any change to piece planning — `ChunkPlanner.plan` already receives the full cap.
- HTTP/2 or HTTP/3 transport work.

## Approach

Chosen from three candidates:

- **A. Open at the configured count immediately; delete upward probing.** *(chosen)*
- B. Geometric ramp (4→8→16) with a recoverable stop.
- C. Immediate open plus a throughput-aware down-shift.

A was chosen because the probe's premise — that an added connection may *hurt* — is rare for HTTP range GETs against a single host, and when it is true the cause is server-side throttling that surfaces as failures and RSTs. `noteRapidFailure` already detects that and reacts in ~1 s rather than 3 s per step. B preserves a signal that Section 1 argues is inverted; it would reach the wrong stopping point faster. C cannot be measured honestly: you cannot know what 8 connections would have yielded without running at 8, so the down-shift rule degenerates into guesswork with more state to maintain.

The user's framing: **fast by default, back off hard on evidence.**

---

## 1. Ramp rework

The core change is a deletion. Once `adaptiveCeiling` starts at the hard cap it is permanently equal to `hardCapExcludingAdaptive()`, so `effectiveThreadCount() = min(hardCap, ceiling)` reduces to `hardCap` and the ceiling ceases to be a distinct concept.

**Removed:**

- `Macget/Engine/AdaptiveConcurrency.swift` — the whole file (`initialWorkers`, `improvementThreshold`, `didImprove`).
- `DownloadCoordinator.checkAdaptiveConcurrency()` and its publish-loop call site.
- State: `adaptiveCeiling`, `probeBaselineSpeed`, `adaptiveProbeStopped`, `adaptiveProbeCounter`, `adaptiveProbeEveryNTicks`.
- `hardCapExcludingAdaptive()`, which collapses into `effectiveThreadCount()`.
- The `adaptiveCeiling` parameter and its output line in `DownloadDiagnostics.report`, plus the corresponding argument in `DownloadCoordinator.diagnosticsReport()`. Section 4's binding-constraint value replaces it in both the diagnostics text and the inspector.

**`effectiveThreadCount()` becomes** `max(1, min(download.threadCount, perHostCap ?? .max, demotedThreadCount ?? .max))`.

**Unchanged** — these are the "back off hard on evidence" half:

- `noteRapidFailure` / `demotedThreadCount` — now the primary regulator.
- `cancelExcessWorkers(toRetain:)` — sheds least-progressed workers first.
- `spawnStaggerNanos` at 100 ms. With 8 workers that is 700 ms to fully spawn, against 12 s today. It defends against a different threat (middleboxes pattern-matching a burst of SYNs from one IP) than the one being deleted, so it stays.

**`adjustThreadCount` simplifies.** Lines pinning `adaptiveCeiling = clamped` and `adaptiveProbeStopped = true` are removed; `download.threadCount = clamped` already feeds `effectiveThreadCount()`, so the user's slider takes effect through one path instead of two.

**`demotedThreadCount` remains session-permanent.** Within a single download, a host that RSTed you is still hostile; nothing should re-raise it mid-transfer. The cross-session version of that judgment is Section 2, and that one does decay.

## 2. Host-cap decay and reset

### 2.1 Do not misattribute network faults to host hostility

`noteRapidFailure` counts any attempt that moved <16 KB. When the local link drops, *every* in-flight worker fails simultaneously, so the `demoteThreshold` of 4 is reached at once and a blameless host is capped. Section 1 sharpens this failure mode, since more workers reach the threshold sooner.

The distinguishing signal: a host rejecting excess connections fails *some* workers while others keep moving bytes; a network fault fails *all* of them.

Gate demotion on at least one worker having made progress within the same window. When nothing anywhere is moving, the existing retry/backoff path is the correct response and no cap is learned.

This is the change that addresses the "specific hosts are slow" complaint. The expiry below is the safety net for caps already mislearned.

### 2.2 Timestamped caps with a 7-day expiry

`HostCapStore.caps` changes from `[String: Int]` to `[String: CapRecord]`, where `CapRecord` is `{ cap: Int, recordedAt: Date }`.

- `cap(for:)` returns nil for records older than 7 days.
- `recordCap` refreshes `recordedAt`.
- Expired entries are dropped at load, so `host_caps.json` self-prunes.
- The ratchet-down-only rule is retained *within* the window. The direction was correct; the permanence was not.

Caps are forgotten outright rather than relaxed gradually, because re-learning is cheap: if the host is still hostile, one demotion event costs ~1 s of the next download.

**Migration.** Decoding tries `[String: CapRecord]` first and falls back to `[String: Int]`, stamping legacy entries with the load time. Existing users' mislearned caps then expire 7 days after upgrade rather than persisting indefinitely.

The 7-day window is a judgment call: long enough to avoid re-probing a genuinely hostile host on every download, short enough that a server configuration change heals within a week.

### 2.3 Reset control

Add `clearAll()` to `HostCapStore` (`clear(host:)` already exists with no callers outside tests). Surface it in `SettingsView.swift`'s `networkTab` as "Reset learned connection limits", labelled with the current count (e.g. "3 hosts have learned limits") so it is not an unexplained button.

## 3. Endgame chunk splitting

**Consolidate three near-duplicate spawn paths into one.** After Section 1, `growWorkers()` has a single caller and differs from `fillFreedSlot()` only in that it loops; both select "next incomplete, unassigned piece." They merge into `fillIdleSlots()`:

```
while inFlight.count < effectiveThreadCount():
    if an unassigned incomplete piece exists   -> spawn on it            (work-stealing, unchanged)
    else if a splittable in-flight piece exists -> split it, spawn both   (new: endgame)
    else break
```

Called from `chunkFinished` (a worker freed a slot) and from `adjustThreadCount` (user raised the slider).

The splitting arm is lifted verbatim from the existing loop in `adjustThreadCount`, including the fresh-UUID worker swap — the cancelled task's `chunkFinished` must remove only its own dead entry, not the newly-spawned one. That subtlety is the main argument for having exactly one copy of this code.

**`minimumSplitBytes = 1 MB`, distinct from `ChunkPlanner.minimumChunkBytes` (64 KB).** `ChunkSplitter` currently refuses to split below `2 × minimumChunkBytes` (128 KB). That floor is correct for *planning* but too low for *splitting*, because splitting cancels a live worker and reconnects; a TLS handshake costs 100–300 ms and should not be spent to rescue 64 KB. At 1 MB, a slow worker at 200 KB/s represents ~5 s of tail, comfortably worth a reconnect. This also bounds thrash: without it, each freed worker would split ever-smaller tails and churn connections through the last second of every download.

**Piece-count ceiling of `ChunkPlanner.maxPieces × 2` (512).** Splits append to `download.chunks`, and `collapseChunksForCompletion` runs only at completion, so the array stays large through the tail. At 512 pieces that is roughly 66 KB of JSON per in-flight download against a debounced 500 ms write — acceptable, but bounded rather than unbounded.

## 4. Instrumentation

`SpeedSeries` is already a general rolling window of `Double` with no speed-specific logic, so this reuses it.

- **`InspectorModel.workerSeries`** alongside `selectedSeries`/`totalSeries`, appending `Double(inspection.activeWorkers)` on the existing poll tick. Use `chartScale(minimum: Double(effectiveThreads))` so the axis is worker-scaled rather than using the 64 KB floor, and render `samples` raw rather than `smoothed` — worker count is a step function, and a 3-wide moving average would invent fractional connections.
- **Overlay on `SpeedChartView`, not a separate chart.** The question is whether throughput tracked connection count, which is only legible on a shared x-axis. Worker count on a secondary y-axis, stepped, visually subordinate to the speed curve.
- **Replace `DownloadInspection.adaptiveCeiling`** (deleted in Section 1) with the *binding constraint* — an enum identifying which cap is currently in force: the user's setting, the learned host cap, or the in-session demotion. Rendered as one line, e.g. "Limited to 4 by learned host limit". This answers "why is this host slow", and sits next to Section 2.3's reset button so the user can act on the answer.
- **`DownloadInspection.splitCount`** — one `Int` on the coordinator, incremented per endgame split. It is the only way to confirm Section 3 fires, and it surfaces the failure mode noted below: a high count on downloads that were not tail-bound means the bytes-vs-time heuristic needs revisiting.

Logging: one debug-level line per split. Demotion already logs at warning.

## Found during implementation

**`fillWorkersUpToTarget` checked the cap before its stagger sleep, not after.** The loop read `inFlight.count >= target`, then awaited 100 ms, then spawned unconditionally. A worker finishing inside that window lets `chunkFinished` → `fillIdleSlots` take the last slot, and the pending spawn then overshoots. Fixed by re-checking the cap (and the chunk's own state) after the await.

**Concurrency transiently reaches cap + 1 during an endgame split.** `applySplit` cancels one connection and opens two halves immediately, but the cancelled socket's teardown is asynchronous. The overlap is exactly one connection and lasts milliseconds. Not worth serializing the split around a teardown wait — that would stall the tail this feature exists to shorten — but it does mean concurrency assertions must allow it.

## Deliberate simplifications

**`ChunkSplitter.nextSplit` selects by bytes remaining, not time remaining.** These diverge — a fast worker that started late can hold more bytes than a slow worker nearly done, and the wrong piece gets split. Fixing it properly requires per-chunk speed tracking on the hot path. IDM ships the bytes heuristic, and at the tail the two measures largely agree because the slow piece is the one still large. Revisit only if `splitCount` shows healthy workers being split.

## Testing

The codebase's established pattern is pure decision logic (`ChunkSplitter`, `RetryAfter`, and the `AdaptiveConcurrency` being deleted) with thin actor plumbing around it. The replacement logic follows the same shape.

**New pure units:**

- `SlotFiller.nextAction(chunks:assigned:cap:) -> .spawn(UUID) | .split(ChunkSplitDecision) | .none` — the Section 3 loop body. Tests: prefers an unassigned piece over a split; splits only when no unassigned piece remains; honors the worker cap, the `minimumSplitBytes` floor, and the 512-piece ceiling.
- `DemotionPolicy.shouldDemote(failureCount:throughputBytesPerSecond:) -> Bool` — the Section 2.1 gate. Aggregate throughput (from the existing `SpeedMeter`) is the concrete form the "did anything progress?" signal took: it must clear `healthyThroughputBytesPerSecond` (16 KB/s), so a dying trickle doesn't read as a healthy host. Tests: demotes at threshold *with* bytes flowing; does **not** demote when throughput has collapsed (the Wi-Fi-drop case); no demotion below threshold.

`fillIdleSlots` and `noteRapidFailure` shrink to plumbing around these.

**`HostCapStore`** gains `now: @Sendable () -> Date = Date.init` in `init`, matching how it already injects `fileURL`. Tests: cap returns nil past 7 days and survives within; legacy `[String: Int]` decodes and stamps load time; ratchet-down holds inside the window; `clearAll()` empties the store.

**`ChunkSplitterTests`** gains cases for the `minimumSplitBytes` floor.

**Test file bookkeeping.** `AdaptiveConcurrencyTests.swift` is deleted with the file it covers, but six of its eleven tests exercise `ChunkPlanner`'s piece cap rather than the probe (`test_pieceCapProducesMorePiecesThanWorkers`, `test_pieceCapCoversRangeContiguously`, `test_pieceCountNeverExceedsMaxPieces`, `test_pieceCapNeverGoesBelowRequestedThreads`, `test_nilCapMatchesLegacyBehavior`, `test_pieceCapStillRespectsMinimumChunkSize`). These move to `ChunkPlannerTests.swift`.

**The test that validates the spec.** A range-aware `URLProtocol` stub — the existing `StubURLProtocol` in `UnknownSizeDownloadTests` serves the full body and ignores `Range`, so this is a new variant that parses `Range: bytes=a-b`, replies 206 with `Content-Range`, and records peak concurrent in-flight requests. Drive a real `DownloadCoordinator` with `threadCount: 8` over a ~64 MB body and assert peak concurrency reaches 8 within ~1.5 s (allowing 7 × 100 ms of stagger). Against current code this fails on both counts — it stops near 5 and takes ~12 s — which is the property being locked down.

**Known flake risk.** The companion endgame test (serve one piece slowly, assert `splitCount > 0`) is wall-clock dependent and the most likely thing here to flake in CI. `SlotFiller` carries the deterministic coverage; the integration test's assertion stays loose ("a split occurred") rather than asserting on timing. If it still flakes it should be cut, not retried into passing.

`SpeedSeries` already has tests and `workerSeries` introduces no new arithmetic. Chart rendering is not unit-tested, consistent with the rest of the UI.

## Docs to update

`CLAUDE.md` is stale in two places this work touches and should be corrected alongside it:

- It states threads are bounded **1–20**; `Download.maxThreadCount` is **16**.
- It describes the streaming step as `withThrowingTaskGroup` over all incomplete chunks. The real implementation is a dynamic worker pool with work-stealing over 8 MB pieces (`fillWorkersUpToTarget`, `fillFreedSlot`, `chunkFinished`), which this spec extends further.
