# Interaction regressions

Run from the repository root with Node.js and the TypeScript compiler bundled
with the installed DevEco Studio. No npm dependency installation is required.

```text
node tools/tests/interaction-regressions.cjs --typescript <path-to-typescript/lib/typescript.js>
```

Alternatively, set `DEVECO_TYPESCRIPT_PATH` to that compiler file and run the
script without arguments.

The runner transpiles the actual ArkTS service sources and injects deterministic
network, storage, clock and platform adapters. It checks account replacement,
request ordering, proxy readiness/failure, playback candidate ownership and pause
intent, download cancellation/file ownership, recovery fences, persistence and
HLS URL resolution. Tests perform no real network requests or user-file changes.

This complements compiler/linter checks and the full `devecocli build`; it does
not validate native playback, ArkUI rendering or device networking behavior.
