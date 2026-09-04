# AGENTS.md — YourPipe

> AI agent context file. Read this first. Tracked in git — keep it free of
> machine-specific absolute paths and secrets.
> This file is the **project-level overview**: what the app is, how
> modules wire, and which tools/conventions agents must follow.
> For per-module deep context (file maps, internal conventions, do-nots),
> see `<module>/AGENTS.md`.
>
> **Style rule for all `AGENTS.md` files**: keep durable architecture,
> ownership boundaries, tool commands, and conventions only. Do **not**
> write changelogs, commit history, or “recent change” bullet lists.

## 1. Project
- **Name / package**: YourPipe (`com.talon.yourpipe`, vendor `talon`, v0.5.9,
  versionCode 1000024).
- **What it is**: YouTube client for OpenHarmony / HarmonyOS. Plays YouTube
  content through a native **MPV** pipeline (vendored `libmpv.so` + static
  `libav*` for mux/remux). Product VOD path is **direct-link DASH** for guest
  (`visionos` /player via the GAPIS endpoint, pot-free — PipePipe parity →
  adaptiveFormats direct URLs → dual-track local proxy → MPV); signed-in
  playback defaults to **mweb SABR/UMP**. Both states are user-selectable
  (Options → 播放端点: guest `visionos|mweb`, signed-in
  `tv_downgraded|mweb`). `android_vr` and `web_safari` are unused endpoints,
  unreachable in product (no UI, kept for reference only); `android_vr`
  requires a session pot.
  The `libmpv_napi` module
  (`MpvPlayerView` / `MpvPlayerController`) is the NAPI bridge to MPV,
  originally derived from the upstream `wang-bin/libmdk-napi` package
  (historical `mdk` names exist only in old commits) — there is no MDK
  Player runtime.
- **Stage model**, `apiType: stageMode`. Target SDK `26.0.0` (HarmonyOS
  7.0.0 / API 26), runtimeOS
  `HarmonyOS`. Native compiler: `BiSheng`.
- **Devices**: phone / tablet / 2in1 / tv / car.
- **Distribution / updates**: AppGallery test channel plus GitHub Releases
  (`https://github.com/Ember5843/YourPipe`); in-app update check from
  Options/About reads the latest release (with a `version.json` asset) and
  opens the repo / AppGallery page.

### Reference projects

Local clones of the reference projects below usually live in this repo's
parent directory (`../`), or in a directory the user points to. **Always look
for the local clones first** (check `../`, or a user-given path) when
comparing behavior or porting logic. If a needed clone is missing or
incomplete, ask the user where it is — do not guess paths, and only fetch
upstream as a last resort. Do not hardcode absolute machine paths here.

Typical clone layout (when present): `NewPipe/`, `NewPipeExtractor/`,
`PipePipe/` (extractor under `PipePipe/PipePipeExtractor`), `libmdk-napi/`,
`mpv/`, `yt-dlp/`.

| Project | Role in YourPipe | Upstream |
|---|---|---|
| NewPipe | Reference for the Android YouTube client experience, including browsing, search, and user-facing behavior. | `https://github.com/TeamNewPipe/NewPipe` |
| NewPipe Extractor | Primary reference for YouTube extraction behavior, stream models, parsing, and service-specific logic. | `https://github.com/TeamNewPipe/NewPipeExtractor` |
| PipePipe | Reference for selected YouTube request behavior, player-client selection, and extractor compatibility decisions. | `https://github.com/InfinityLoop1308/PipePipe` |
| libmdk-napi | Historical origin of the `libmpv_napi` bridge structure and of the `mdk` names in old commits. It is not the product player runtime. | `https://github.com/wang-bin/libmdk-napi` |
| MPV | Product playback core and the authoritative reference for libmpv behavior and APIs. | `https://github.com/mpv-player/mpv` |

These projects are references, not alternate runtime implementations. Preserve
YourPipe's module ownership and MPV-only player architecture when porting or
adapting upstream behavior.

## 2. Module map
| Module | Type | Role | Module doc |
|---|---|---|---|
| `entry` | `entry` | UI shell, ArkUI pages, i18n, preferences, presentation / handoff, SABR PoToken WebView mint, startup prewarm / queue-next prefetch, update check (GitHub Releases). | `entry/AGENTS.md` |
| `mediaservice` | HAR | Playback engine, state machine, AV session, local range + SABR dual proxy, offline SABR download. | `mediaservice/AGENTS.md` |
| `youtube_core` | HAR | YouTube extraction, cipher (JSVM + PipePipe), HLS, SABR/UMP session (session-pinned visitorData), dual-rail auth, HTTP proxy options. | `youtube_core/AGENTS.md` |
| `libmpv_napi` | HAR | NAPI bridge to MPV; ships vendored FFmpeg + libmpv (arm64 product; x86_64 stub). | `libmpv_napi/AGENTS.md` |
| `asrengine` | HAR | On-device ASR audio decode for AI subtitles (system NDK demux + AAC decode → 16kHz mono PCM file). | `asrengine/AGENTS.md` |

Wire-up:
```
entry  →  mediaservice  →  youtube_core
  │              └────→  @yourpipe/libmpv-napi (libmpv_napi)
  ├──────────→  youtube_core   (auth, extractor, proxy options, models)
  ├──────────→  asrengine      (AI subtitle P3 audio decode)
  └──────────→  sherpa_onnx    (ohpm; on-device ASR inference)
```
`youtube_core` has no HAR package deps (native `yourpipe_cipher` only).
`libmpv_napi` is self-contained (embeds FFmpeg + libmpv on arm64).

## 3. CodeGraph (code intelligence)

This repo is indexed by **CodeGraph** (`.codegraph/` at repo root, git-ignored).

- **Always prefer the `codegraph_explore` MCP tool for code search and
  comprehension** — how does X work, architecture, where/what is X, surveying
  an area, or reading the symbols you are about to change. One call returns
  the verbatim, line-numbered source of the relevant symbols plus call paths
  and blast radius. Use it BEFORE Grep/Glob/Read loops; only fall back to the
  built-in tools for exact-string searches or files outside the index.
- Shell equivalent (always works): `codegraph explore "<symbols or question>"`,
  `codegraph node <name>`, `codegraph query <search>`.
- **Keep the index fresh**: after finishing a batch of code edits, run
  `codegraph sync` (incremental) so subsequent queries see current code.
  `codegraph index` rebuilds from scratch when sync reports drift or after
  large refactors / branch switches.
- Never commit `.codegraph/` (git-ignored); indexing is per-machine.

## 4. deveco-mcp (static syntax analysis)

The `deveco-mcp` MCP server provides the `deveco-mcp_check` tool for static
syntax analysis on HarmonyOS project source files.

- **Supported languages**: ArkTS and C/C++ (can be mixed in one call).
- **When to use**: after editing ArkTS or native C/C++ source, run
  `deveco-mcp_check` on the changed files to catch syntax errors, type
  mismatches, and SDK misuse before invoking `devecocli build`. It is
  significantly faster than a full build for local syntax verification.
- **Usage**: call the `deveco-mcp_check` tool with `files` — an array of
  paths relative to the project root. Example:
  `deveco-mcp_check(files: ["entry/src/main/ets/Foo.ets", "youtube_core/src/main/cpp/bar.cpp"])`.
- **Relation to lint**: `deveco-mcp_check` is a syntax/type checker
  (compiler-level), complementary to the ArkTS lint rules in
  `code-linter.json5` (style/security/performance). Run both before
  considering a change complete.

## 5. harmonyos_developer_knowledge (鸿蒙开发者知识)

The `harmonyos_developer_knowledge` MCP server provides search and retrieval
for official HarmonyOS developer documentation.

- **Tools**: `searchDocuments` (search by keyword, returns matching text
  blocks + doc IDs) and `getDocumentsById` (retrieve full document content
  by ID — up to 10 per call).
- **Coverage**: release notes, API references, development guides, best
  practices, FAQ, IDE guides, UX design, app distribution, and more.
- **When to use**: looking up HarmonyOS API behavior, SDK usage, ArkUI
  component specs, or official development patterns. Use this before
  guessing at SDK semantics.
- **Usage flow**: call `searchDocuments` with `query` keyword(s) → extract
  the `parent` field from results → call `getDocumentsById` with those IDs
  for full document content when the summary blocks are insufficient.
- **Remote server**: `https://connect-api.cloud.huawei.com/api/developerknowledge/mcp`

## 6. Build / run / lint / docs (devecocli)
HarmonyOS work in this repo **must** go through `devecocli` (DevEco CLI skill).
Prefer it over raw `hvigor` / `ohpm` / `hdc` unless diagnosing the tool itself.

| Goal | Command |
|---|---|
| Build (default — always prefer this) | `devecocli build` |
| Product / release bundle | `devecocli build --product <name> --build-mode release` |
| Clean | `devecocli build clean` |
| Run (build + install + launch) | `devecocli run` (`--module`, `--device`, `--ability`, `--uninstall`, `--skip-build` as needed) |
| Devices | `devecocli device list` / `devecocli device view -t <name\|serial>` |
| Emulator | `devecocli emulator list\|start\|stop\|create\|delete` (+ `image list\|download\|remove`) |
| Logs / crash | `devecocli log` (`--crash`, `--level`, `--bundle-name`, `--from`/`--to`, `--tail`, `--follow`) |
| HarmonyOS docs | `devecocli docs search <kw…>` / `docs read <documentId>` / `docs catalog` |

**Build policy for agents**: always run full product build via
`devecocli build` (no `--modules`). Do **not** use
`devecocli build --modules entry` (or other single-module builds) for
verification — entry depends on HARs and partial builds can miss
cross-module breakage. Module-scoped builds only when diagnosing a
specific module toolchain issue.

Defaults when omitted: product `default`, build mode `debug`, ability from
`module.json5` (this app: `EntryAbility` → `product/Index`). ABIs:
`arm64-v8a` (product MPV), `x86_64` (emulator UI stub for libmpv_napi).
Build outputs (`.cxx/`, `build/`, `.hvigor/`, `oh_modules/`, `Crash_*.dmp`)
are git-ignored.

If `PackageHap` fails with `spawn java ENOENT`: point the user-level
`JAVA_HOME` at DevEco Studio's bundled JBR (the `jbr` directory inside the
DevEco install) and add its `bin` directory to the user `PATH`
(Windows: `%JAVA_HOME%\bin`; macOS/Linux: `$JAVA_HOME/bin`, e.g. in
`~/.zshrc`) — per-command env tweaks don't reach devecocli's child
processes, and only new shells see the change.

- **Lint**: `code-linter.json5` (root) — `@performance/recommended` +
  `@typescript-eslint/recommended` + `@security/*` blocking unsafe crypto.
- **Signing**: `build-profile.json5` is **git-ignored** (machine-local); the
  committed `build-profile.template.json5` is the sanitized template with EMPTY
  `signingConfigs`. Fresh clones: `cp build-profile.template.json5
  build-profile.json5` (DevEco sync needs it). Real material must never be
  committed — git history is scrubbed and `.githooks/pre-commit` blocks it.
  For local builds: `tools/restore-signing.sh` overlays git-ignored
  `signing-backup/build-profile.local.json5` (seeding from the template when
  missing); `tools/strip-signing.sh` resets to the template (hygiene only).
- **Sandbox**: `devecocli build` / `run` / `update` are outside sandbox;
  escalate when the environment requires it.

## 7. Top-level layout
```
AppScope/                  — app-level config (icon, label, version)
README.md                  — public project overview (open-source repo)
entry/                     — UI module → entry/AGENTS.md
mediaservice/              — playback engine → mediaservice/AGENTS.md
youtube_core/              — YouTube extractor → youtube_core/AGENTS.md
libmpv_napi/               — MPV NAPI bridge → libmpv_napi/AGENTS.md
tools/                     — restore/strip signing helpers
signing-backup/            — local signing overlay (git-ignored material)
build-profile.json5        — root Hvigor config (git-ignored, machine-local; seed from template)
build-profile.template.json5 — committed sanitized template for build-profile.json5
code-linter.json5          — ArkTS lint rules
hvigorfile.ts              — Hvigor entry
```

Root scratch notes matching `*-analysis.md` / `*-design.md` (and capture
JSON) are git-ignored; prefer `AGENTS.md` + code over local drafts.

## 8. Cross-cutting rules
- **Config ownership**: only `entry` reads `AppStorage`. Downstream modules
  receive config via `setProvider` / function args injected from
  `EntryAbility.onCreate` (and `NetworkProxyConfig` → `HttpProxyOptions`).
- **Logging**: modules push through their `setSink` hooks into
  `AppLogStore`; do not scatter raw `console.log` / `hilog` in library code.
- **Player stack**: product backend is MPV only (`libmpv_napi` +
  `MpvPlaybackEngine`). Do not reintroduce a second decoder/player path.
- **Playback media path**: guest VOD is direct-link-first (`visionos` →
  adaptiveFormats direct URLs → loopback proxy synthesizes a static MPD from
  SIDX → vendored mpv's native `demux_dash`; the dual-track `edl://` pattern
  survives only as a build-time fallback); signed-in VOD
  defaults to the mweb **SABR** path, with `tv_downgraded` direct links
  still selectable. `android_vr` and `web_safari` are unused endpoints,
  unreachable in product (no UI, kept for reference only); `android_vr`
  requires a session pot. SABR ownership:
  extractor bootstraps SABR; `youtube_core` owns UMP session fetch;
  `mediaservice` owns lease/store/serve + MPV load URL; `entry` owns PoToken
  WebView mint.
- **Startup latency**: cold start takes a disk fast path — extractor startup
  metadata (STS `signatureTimestamp` + WEB `clientVersion`) persisted beside
  the cipher JS cache — BotGuard pre-initializes at launch, and the next
  queue item's streams are prefetched after playback stabilizes. Extraction
  is serialized through a mutex (the extractor is a stateful singleton);
  prefetch must never run concurrently with real playback extraction.
- **SABR pacing / PoToken** (mweb opt-in path): the UMP server backoff is
  session-owned (epoch state) and must survive recovery/seek — local stall
  resets never clear it. PoToken mint is bounded by a timeout + circuit
  breaker so a wedged WebView can never hang SABR playback. Mid-stream
  protection challenges follow youtube_core's policy chain (`sabr/policy/`):
  status==2 pending → ROTATE_IDENTITY (budget 3) → PoToken force-refresh
  (budget 2) → RELOAD_PLAYER (budget 2); status>=3 fails fast. Visitor
  identity is pinned/invalidated only through `SessionIdentityManager`; a
  PoToken must never be reused across a visitorData change. Details:
  `youtube_core/AGENTS.md` §4, `entry/AGENTS.md` §6.
- **Login data expiry**: `youtube_core` browse APIs raise a typed
  `AuthExpiredError` on 401 / Innertube error 16 (`UNAUTHENTICATED`) when
  auth was attached; the signed-in home feed then falls back to the guest
  kiosk and surfaces a re-login notice (`noteAuthRejection` /
  `consumeAuthRejectionNotice`). Account-cookie rotations in youtube.com
  `Set-Cookie` are merged back into the stored credential
  (`AuthSessionManager.mergeAccountSetCookies`, hooked into every
  `HttpDownloader` response); a server-cleared SID/SAPISID marks the web
  rail rejected, and OAuth `invalid_grant` clears the refresh token.
- **Proxy coverage**: one app proxy config (HTTP or SOCKS5) drives every
  network stack — netstack `http` (API 26 native `usingSocks5Proxy`,
  proxy-side DNS, no bridge hop), RCP sessions, ArkWeb `ProxyController`,
  and MPV's direct fetches (`http_proxy`/`no_proxy` process env via
  `setHttpProxyEnv`). ArkWeb / RCP / MPV route SOCKS5 through the
  self-healing loopback CONNECT bridge `Socks5Bridge`, so the bridge must
  run whenever socks5 is configured even though netstack no longer uses it.
  The ArkWeb override has no direct-fallback rules — a failing proxy must
  fail, not silently go direct. Loopback stays direct. Startup prewarm
  chains gate on `NetworkProxyConfig.awaitReady()` so a proxy user's first
  requests never go direct while the proxy is still being applied. Details:
  `entry/AGENTS.md` §3, `youtube_core/AGENTS.md` §7,
  `mediaservice/AGENTS.md` §3.
- **Network handover**: entry `NetworkHandoverService` owns the single
  `connection` default-network event subscription (SDK kit set has no
  NetworkBoostKit `netHandover`); on a switch/loss (2s debounce) it calls
  `LocalMediaProxy.abortAllUpstreamFetches` and
  `sabrSessionStore.abortAllInFlightPosts` so stale in-flight connections
  fail fast and the existing retry paths recover on the new network. SABR
  sessions are never closed by this path — only the in-flight POST is
  aborted.
- **Dependency direction**: never import `entry` from HARs; never import
  `mediaservice` from `youtube_core`.
- **AI subtitles**: the only live path is P0, the server-side `tlang`
  translation track — built by `youtube_core`
  (`extractor/SubtitleTranslate.ets`, `SubtitleTrack.isAutoTranslated`),
  appended by entry `YouTubePlayService.withAutoTranslatedTrack`;
  mediaservice `fetchText` attaches login Cookie + SAPISIDHASH for `tlang=`
  URLs via `AvPlayerController.setSubtitleAuthHeaderProvider` and throws on
  non-200 so the overlay retry path sees failures. Known limitation: YouTube
  risk-controls `tlang` by exit-IP reputation (HTTP 429 "automated queries",
  anonymous AND signed-in) — whether a track produces output depends on the
  network; there is no client-side workaround. P1 (system
  AICaptionComponent), P2 (gtx/LLM track translation), and P3 (on-device
  sherpa-onnx ASR via `AsrLiveCaptionService` + worker) are all [DISABLED]
  at their entry points — menu/Options entries and wiring commented out,
  code retained; re-enable by uncommenting those blocks. The `asrengine`
  HAR is retained in the build but has no consumer.
  `AsrModelManager.clearAll` / `AsrLiveCaptionService.clearCaches` stay
  wired into clear-all-data so already-downloaded models are still cleaned.
  Details: `entry/AGENTS.md` §2 (player feature), `mediaservice/AGENTS.md`
  §3.
- **Secrets / artifacts**: do not commit keystores, `Crash_*.dmp`, or build
  trees. `AGENTS.md` files are tracked project docs — keep them in sync
  with the code they describe, and never put machine-specific absolute
  paths or credentials in them.
- **Persistence and recovery**: every new persistent preference, database,
  file, or cache must define how it participates in both "restore default
  settings" and "clear all app data". Wire disposable state into the relevant
  recovery action and reset matching in-memory/native caches as well. The
  deliberate exception is user-downloaded media under `filesDir/downloads`,
  which must survive "clear all app data" unless product requirements and the
  confirmation copy explicitly change.

### Logging architecture and requirements
- `entry` code logs through `AppLog.getInstance(<stable component tag>)`.
  `AppLog` writes to system `hilog` at the matching level and forwards the
  same normalized record to `AppLogStore`.
- `mediaservice` logs through `Logger` / `EnhancedLogger`. Both must dispatch
  to the `EnhancedLogger.setSink` installed by `EntryAbility`; do not use
  `console.*` or direct `hilog` in feature, state, engine, proxy, or controller
  code.
- `youtube_core` logs through `YTCoreLogger`. It writes matching-level system
  logs and forwards to the sink installed by `EntryAbility` so extraction and
  authentication logs are visible both in DevEco logs and in an enabled app
  log session.
- `AppLogStore` is the only exception allowed to use direct `hilog` for its
  own file/session diagnostics, because routing those messages back through
  itself would recurse. Native MPV forwarding is controlled through its
  `setNativeBridge` start/stop hooks.
- Every new feature must log its important lifecycle boundaries, external
  requests, state transitions, retry/fallback decisions, completion timing,
  and caught failures. Use `DEBUG` for high-frequency detail, `INFO` for
  meaningful milestones, `WARN` for recoverable degradation/retry, and
  `ERROR` for terminal failures.
- Use stable searchable tags and structured `key=value` fields. Include the
  relevant correlation ID (`videoId`, `sessionId`, task ID, request stage)
  where available. Never log cookies, authorization headers, SAPISID hashes,
  PoTokens, full signed media URLs, or other credentials; redact or summarize
  sensitive URLs and payloads.
- A caught exception must either be deliberately documented as harmless or be
  logged through the module logger. User-visible error handling does not
  replace diagnostic logging.

## 9. Quick refs
- Pages entry: `entry/src/main/resources/base/profile/main_pages.json`.
- i18n keys: `entry/src/main/resources/<locale>/element/string.json`.
- Lint config: `code-linter.json5` (root).
- Signing: `tools/restore-signing.sh` / `tools/strip-signing.sh` (committed
  intent is empty signing material).
- Module deep docs: `entry/AGENTS.md`, `mediaservice/AGENTS.md`,
  `youtube_core/AGENTS.md`, `libmpv_napi/AGENTS.md`.
