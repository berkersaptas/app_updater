# Rollback model

An installed patch begins as `pending`. Immediately before engine construction the native loader
writes `pending_boot`. Flutter sends `markBootSuccess` after its first rendered frame, changing the
state to `active`.

If the next process observes `pending_boot`, the prior attempt never confirmed startup. It writes
`failed`, sets `enabled=false`, and boots packaged `libapp.so`. Missing files, unsafe paths, invalid
JSON, and SHA-256 mismatches also select base; validation failures with a readable state are
recorded as `failed`.

Release/build, Flutter engine, Dart SDK, ABI, or build-mode mismatches follow the same fail-closed
path before the engine sees the alternate artifact. `failure_reason` records the mismatched values.

Successful activation atomically snapshots the patch metadata as `last_known_good.json`. Failed
artifacts below `filesDir/ota/patches` are moved to a timestamped quarantine directory together
with `failure.json`. Cleanup retains at most five quarantine entries and preserves only active or
last-known-good patch directories. Phase 1 still falls back to the APK base; last-known-good is
recorded for controlled recovery in a later phase, not automatically executed.

## Hang protection (`BootWatchdog`)

The restart-based detection above only runs on the *next* process start. If a patched boot hangs
instead of crashing — the main thread deadlocks or spins before ever rendering a first frame, so
`markBootSuccess` never fires but the process also never dies — that detection never gets a chance
to run within the same process lifetime. `BootWatchdog` closes this gap: a background timer
(independent of the main looper, so it still fires even if the main thread is stuck) is armed the
moment a patched artifact is selected and disarmed the moment `markBootSuccess` is reported. If it
fires first (20s default), it proactively marks the stuck patch `failed` and bad-listed on disk, so
whichever restart eventually happens (the user reopens the app, or the system reaps a long ANR)
boots clean immediately instead of re-attempting the same hung patch. It deliberately does not kill
the process itself — forcing an automatic restart was considered and left as a possible fast-follow.

## Circuit breaker (cross-patch failure counter)

`BadPatchStore` permanently blacklists a single bad *patch number*, but on its own that means a
broken build pipeline that keeps pushing new broken patches would crash-once-per-relaunch
indefinitely, one patch number at a time. A separate cross-patch circuit breaker in
`OtaLifecycleStore` tracks consecutive `PatchLoader` failures (any reason) and resets on the next
successful boot. After 3 consecutive failures it opens: `OtaUpdateClient` refuses to even contact
the backend for a new patch while it's open, so the device just runs its last-known-good/base state
until either a boot succeeds again or 6 hours pass (half-open retry), rather than repeatedly
installing and re-attempting more bad patches. Observable via `status().circuitOpen`.

## Still not covered

No real multi-process lock (two processes racing `PatchStateStore` writes is theoretically
possible, not currently guarded), and telemetry is limited to the existing best-effort
`PatchInstallStarted`/`Success`/`Failure` event posts — no structured crash/ANR reporting beyond
what's captured in `failure_reason`/quarantine.
