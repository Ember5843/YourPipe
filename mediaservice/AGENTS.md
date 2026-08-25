# mediaservice/AGENTS.md

> Playback engine HAR. Wraps MPV (via `libmpv_napi`), owns the player
> state machine, AV session, background continuous task, and a local HTTP
> proxy that serves both progressive/DASH byte-range and **SABR dual-track**
> sessions. Re-exports stream types and `muxAudioVideo`. Durable
> architecture only — no changelogs.

## 1. Public surface (`mediaservice/Index.ets`)
- `AvPlayerController`, `NativeLogBridgeFns` — main controller entry.
- `LocalMediaProxy` — facade over local proxy sessions (range + SABR dual).
- `sabrSessionStore` — SABR lease / track-buffer store.
- `SabrOfflineDownloader`, `SabrOfflineProgress`, `SabrOfflineDownloadOptions`
  — offline SABR download (used by entry `DownloadManager`).
- `PlaybackEngine` (interface), `PlaybackEngineState`, `PlaybackState`,
  `PlaybackErrorCategory`, `EngineConfig`, `PlaybackStats` — engine contract
  types (`PlaybackStats` = on-demand snapshot for the entry stats UI:
  MPV demuxer-cache-duration / dropped frames plus `networkSpeedBps`.
  For proxy-fed sources `networkSpeedBps` comes from `proxyTrafficMeter` —
  real network bytes metered in `RangeProxy` (upstream chunks) and at the
  SABR UMP POST response (wired via `setSabrNetworkTrafficSink` in
  `sabrSessionStore.setHttpClient`), since MPV `cache-speed` is loopback
  throughput and pins at 0 once the demuxer cache cap is reached. For
  direct network sources (live HLS bypasses the proxy — `isDirectNetworkSource()`)
  `AvPlayerController` fills it from MPV `cache-speed` instead).
- `VideoHwCaps` — device HW decoder capability snapshot + hwdec-codecs
  whitelist passthrough (value owned by native `getHwdecCodecsWhitelist`).
- `PlayerState`, `isValidTransition`, `describeState`, `PlayerStateMachine`,
  `StateChangeListener`, `PlayerUiViewModel`.
- `PlaybackPreferences`, `PlaybackPreferencesSnapshot`, `PlaybackPreferencesProvider`.
- `BackgroundTaskManager`.
- `Logger`（共享默认实例，tag `[Mediaservice]`）, `EnhancedLogger`, `LogSinkFn`, `LogSinkLevel`.
- `PlayerModel`, `StreamCategories`, `CurrentStreams`, `VideoEntry`,
  `AudioTrackOption`, `VideoData`, `StreamInfo`, `SelectOption`,
  `AVPlayerState`, `CommonConstants`, `secondToTime`.
- `ChapterInfo`, `SubtitleTrack` — re-exported from `youtube_core`.
- `muxAudioVideo` — local-file remux (from `libmpv_napi`).

**Internal (not exported from Index)**: `MpvPlaybackEngine`,
`AvSessionManager`, `PlayerStateRelay`, proxy/SABR implementation files.

## 2. Layout
```
mediaservice/src/main/ets/
  controller/
    AvPlayerController.ets       — lifecycle, AV session, state, source/URL build
    LocalMediaProxy.ets          — facade: range + youtube-dual + sabr-dual
  engine/
    PlaybackEngine.ets           — engine interface + state / error / config types
    MpvPlaybackEngine.ets        — sole PlaybackEngine impl (MPV via libmpv_napi)
    VideoHwCaps.ets              — HW decoder capability helpers
  proxy/
    LocalProxyServer.ets         — loopback HTTP server
    RangeProxy.ets               — byte-range passthrough
    InputParser.ets              — request URL parsing
    SessionStore.ets             — session map (`single` | `youtube-dual` | `sabr-dual`)
    YoutubeDashManifest.ets      — synthetic DASH helpers
    YoutubeDashIndex.ets         — SIDX / index helpers for dual progressive
  sabr/
    SabrSessionStore.ets         — acquire/release leases, PoToken provider +
                                   info-reloader hooks
    SabrTrackBuffer.ets          — per-track buffer + ensureReady
    SabrProxyServe.ets           — serve SABR media over loopback
    SabrDashProxy.ets            — SABR DASH manifest/path serve
    SabrOfflineDownloader.ets    — offline download path
  state/
    PlayerState.ets              — state enum + valid transitions + describeState
    PlayerStateMachine.ets       — state machine + StateChangeListener
    PlayerStateRelay.ets         — observer + ProgressSubscriber relay
    PlayerUiViewModel.ets        — UI-facing observable state model
  model/
    PlayerModel.ets, VideoData.ets
  common/
    AvSessionManager.ets         — AV session (app-layer focus / interruption)
    BackgroundTaskManager.ets    — background continuous task lifecycle
    PlaybackPreferences.ets      — UI/playback config (injected via setProvider)
    CommonConstants.ets
  utils/
    Logger.ets, EnhancedLogger.ets, CommUtils.ets
```

## 3. Engine contract
- `PlaybackEngine` is the abstraction. `MpvPlaybackEngine` is the **only**
  product implementation. Do not add a second decoder/player backend.
- Product defaults lean on MPV’s OHOS path (ohcodec + gpu-next family
  settings) with config supplied by entry — not hard-coded in UI.
- The engine reads its config through `AvPlayerController.setEngineConfigProvider` —
  not via `AppStorage`.
- `VideoHwCaps` / NAPI probe inform auto quality / codec preference;
  manual quality switches remain available to the user.
- Render surface is wired through entry's inline XComponent (`id:
  'PlayerXComponent'`, no `libraryname`) in `AVPlayer.ets`: on `onLoad` the
  surfaceId is routed via `AvPlayerController.setSurfaceID` →
  `MpvPlaybackEngine.bindSurface` → `controller.setVideoSurfaceId()` /
  `setVideoSurfaceSize()`. `libmpv_napi`'s `MpvPlayerView` (libraryname-driven
  native surface callbacks) is a DORMANT standby path, not used in production.
- Background **audio-only** (disabling video tracks after a delay) is
  coordinated with entry’s `PlayerPresentation`; engine APIs apply
  property changes, they do not invent presentation policy.
- Source submission has a **single writer** — entry `PlayerSession.play()`;
  duplicate suppression lives there, so a controller submission always
  means a real load.
- MPV direct network fetches (HLS masters/segments, `sub-add` subtitle
  URLs) follow the app proxy through the process environment:
  `MpvPlaybackEngine.applyNetworkProxy` (on `load()`) calls libmpv_napi
  `setHttpProxyEnv`, which sets `http_proxy` (+ `no_proxy` =
  `127.0.0.1,localhost` so the loopback proxy stays direct). The vendored
  libmpv has **no** `network-proxy` property — do not reintroduce that
  `setProperty` call.

## 4. Local proxy architecture
`LocalProxyServer` exposes a loopback HTTP endpoint so MPV always consumes a
stable local URL. Session types in `SessionStore`:

| Type | Role |
|---|---|
| `single` | Simple range/proxy session (also the per-track building block of EDL dual playback) |
| `youtube-dual` | Progressive/DASH dual (video+audio) with SIDX/`YoutubeDashIndex` (reference/rollback only, not on the production path) |
| `sabr-dual` | SABR UMP dual tracks via `sabrSessionStore` (mweb opt-in path) |

**Direct-link dual path (product VOD: visionos / tv_downgraded)**:
`AvPlayerController.buildDualEdlUrl` creates two `single` open-range sessions
(video + audio) and hands MPV a native `edl://` URL
(`!new_stream` / `!delay_open`, the pre-SABR production pattern). MPV never
touches a DASH demuxer for these clients; the SIDX `youtube-dual` static
manifest path (`buildDualDashUrl`) is retained for reference only.
Upstream transports in `RangeProxy`: VISIONOS (and TVHTML5) googlevideo
requests stream over RCP (visionos = body-less GET) so MPV's first byte never
waits for a full buffered chunk; other clients use buffered `@ohos.net.http`
GET. Connect timeout is 10s (PipePipe OkHttp parity); transfer/read stays 30s
(RCP `transferMs` covers the whole stream). Every RCP session — YouTube and
non-YouTube alike — resolves the app proxy through the shared
`resolveRcpProxy` (http → upstream URL with auth, socks5 → loopback bridge
URL with `createTunnel:'always'`, otherwise `'no-proxy'`).

**SABR dual path (mweb opt-in)**:
1. Extractor returns SABR bootstrap (`YoutubeSabrInfo` / streams with SABR delivery).
2. `sabrSessionStore.acquire` builds `YoutubeSabrSession` (youtube_core UMP).
3. `SabrTrackBuffer.ensureReady` warms video then audio (PoToken via entry provider when needed).
4. Loopback DASH/range URLs from `SabrDashProxy` / `SabrProxyServe` are handed to MPV.
5. Offline: `SabrOfflineDownloader` for entry downloads.

Startup: demand-side SIDX fetches gate on the pending DASH PoToken injection
(`LocalMediaProxy.setStartupUrlGate`). The former fire-and-forget SIDX
prefetch was removed from the play path — its cache was only consumed by the
non-product `youtube-dual` session, so it was dead traffic on the EDL path.

**Pacing / lease rules**:
- The SABR session owns the UMP server backoff: `pumpOnceLocked` waits out
  the remaining deadline **inside** the serialized pump lock
  (`YoutubeSabrSession.ets`, capped by `MAX_BACKOFF_MS`), and local
  recovery/seek never clears the server deadline.
- A failed session build must release the lease so the store can retry.
- entry injects both the `SabrPoTokenProvider` and the `SabrInfoReloader`
  into `sabrSessionStore` (`setPoTokenProvider` / `setInfoReloader`);
  `acquire` passes them into every new `YoutubeSabrSession`. PoToken is
  minted lazily by the session (empty/protected response, or background
  warmup on status>=2 media); protection recovery (rotate/reload) happens
  inside the session via youtube_core's policy layer.
- Transient vs terminal SABR errors are distinguished by
  `SabrProtocolException.kind` ('protection'/'no_media'/'segment_unavailable'
  are retryable, 'beyond_end' signals end-of-stream to the caller;
  'attestation_required'/'reload_exhausted' are terminal) — never match on
  error message strings.
- `SabrTrackBuffer` pumps on demand to satisfy each range request
  (`readRange` → `ensureBytes`); each pump first tries an opportunistic
  direct fetch of the next segment, then falls back to the session's
  serialized `pumpOnce`, so a single slow pump or one dropped POST cannot
  underrun the player.

Do not teach MPV remote SABR URLs directly; always go through the local proxy.

## 5. Config injection
- `PlaybackPreferences.setProvider(...)` is the **only** way
  `mediaservice` reads UI/playback prefs. `entry` wires this in
  `EntryAbility.onCreate`.
- `AvPlayerController.setEngineConfigProvider(...)` — MPV engine-specific
  knobs (hwdec, cache, demuxer, GPU API, etc.).
- PoToken mint is **not** configured here; entry injects
  `SabrPoTokenProvider` into `sabrSessionStore`.

## 6. Logger injection
- `EnhancedLogger.setSink((level, tag, message) => ...)` is wired in
  `EntryAbility.onCreate` → `AppLogStore.push`. Do not call `hilog` /
  `console.log` directly inside `mediaservice` code; use the sink.

## 7. State machine
- States: `idle`, `initializing`, `loading`, `ready`, `playing`, `paused`,
  `buffering`, `completed`, `released`, `error`. See `PlayerState.ets` for the
  full enum + `isValidTransition` rules.
- Listeners register via `PlayerStateMachine.addStateChangeListener(listener)`.
- The `backgroundTaskListener` is attached in `AvPlayerController` to keep
  the background continuous task alive across the playing lifecycle.

## 8. Conventions
- **No `AppStorage` reads of config/prefs.** Use the `setProvider` hooks
  above. Reading the `UIAbilityContext` (`AppStorage.get('context')`) and
  the AVSession GC pin (`__avSession_pin`) are established exceptions.
- **No direct `console.log` / `hilog`.** Use the sink.
- **No cross-device continuation APIs.** `@kit.AbilityKit` is imported only
  for `common` / `wantAgent` (UIAbilityContext, background task); handoff is
  `entry`'s job (`PlaybackContinuationService`); `mediaservice` exposes
  state only.
- **Audio focus / interruptions**: cooperate via `AvSessionManager` and
  controller APIs; do not re-embed focus policy inside native MPV glue.
- **`Index.ets` exports are static references.** No top-level `let x = new X()`
  at module load time — export factories or `getInstance()` instead.
- **Mux/remux**: `muxAudioVideo` is the only path for combining local
  audio + video. Do not call FFmpeg directly.
- **SABR ownership split**: UMP protocol/session in `youtube_core`; lease,
  buffer, serve, offline download in `mediaservice`; PoToken WebView in `entry`.

## 9. Do not
- Read config/prefs via `AppStorage` — inject through the `setProvider`
  hooks (the `UIAbilityContext` lookup and AVSession pin are existing
  exceptions).
- Use cross-device continuation APIs (handoff is `entry`'s concern);
  `@kit.AbilityKit` imports stay limited to `common` / `wantAgent`.
- Edit files under `libmpv_napi/src/main/cpp/{ffmpeg-sdk,mpv-sdk}` — vendored.
- Add a second playback backend beside `MpvPlaybackEngine`.
- Feed MPV remote SABR/googlevideo URLs without the local proxy.
- Add top-level mutable state in `Index.ets`; export factories or
  `getInstance()` accessors instead.
- Commit `Crash_*.dmp`, `.cxx/`, `build/`, `.hvigor/` artifacts or any
  `AGENTS.md`.
- Put changelogs or commit-specific notes into this file.
