# mediaservice/AGENTS.md

> Playback engine HAR. Wraps MPV (via `libmpv_napi`), owns the player
> state machine, AV session, background continuous task, and a local HTTP
> proxy that serves both progressive/DASH byte-range and **SABR dual-track**
> sessions. Re-exports stream types and `muxAudioVideo`. Durable
> architecture only — no changelogs.

## 1. Public surface (`mediaservice/Index.ets`)
- `AvPlayerController` — main controller entry. Includes the thin ASR PCM
  tap passthrough (`enableAudioTap` / `disableAudioTap` / `setAudioTapCallback`
  → `MpvPlaybackEngine` → `MpvPlayerController`; no policy, entry owns
  lifecycle via `AsrLiveCaptionService` — currently [DISABLED] in entry,
  tap plumbing retained). `AudioTapChunk` is re-exported from
  `@yourpipe/libmpv-napi` for tap consumers.
- `LocalMediaProxy` — facade over local proxy sessions (range + SABR dual).
  `abortAllUpstreamFetches(reason)` is the network-handover lever: aborts
  every in-flight upstream fetch across sessions (via
  `UpstreamCancelRegistry.cancelAll`) so stale connections fail fast on a
  default-network switch; sessions/URLs stay alive and MPV's reconnect
  re-issues the fetches.
- `sabrSessionStore` — SABR lease / track-buffer store.
  `abortAllInFlightPosts(reason)` is the network-handover lever: aborts each
  active session's in-flight UMP POST (sessions stay open — unlike
  `abort(key)`, no close; the session's own catch/retry paths re-POST on the
  new network).
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
- `ContextProvider`, `UIAbilityContextProvider` — injected UIAbilityContext
  getter (replaces `AppStorage.get('context')` in mediaservice).
- `BackgroundTaskManager`.
- `Logger`（共享默认实例，tag `[Mediaservice]`）, `EnhancedLogger`, `LogSinkFn`, `LogSinkLevel`.
- `PlayerModel`, `StreamCategories`, `CurrentStreams`, `VideoEntry`,
  `StreamClassification`, `VideoData`, `StreamInfo`,
  `SelectOption`, `AVPlayerState`, `CommonConstants`, `secondToTime`.
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
    RcpSessionPool.ets           — long-lived RCP sessions per proxy session (+ connectOnly pre-connect)
    UpstreamCancelRegistry.ets   — in-flight upstream op registry (conn/session cancel)
    ProxyTrafficMeter.ets        — upstream network traffic meter (networkSpeedBps)
    ProxyEncoding.ets            — shared UTF-8 TextEncoder singleton (encodeUtf8/encodeUtf8Bytes)
    InputParser.ets              — request URL parsing
    SessionStore.ets             — session map (`single` | `youtube-dual` | `sabr-dual`)
    YoutubeDashManifest.ets      — synthetic DASH helpers
    YoutubeDashIndex.ets         — SIDX / index helpers for dual progressive
  sabr/
    SabrSessionStore.ets         — acquire/release leases, PoToken provider +
                                   info-reloader hooks
    SabrTrackBuffer.ets          — per-track buffer + ensureReady
    SabrDashProxy.ets            — SABR DASH manifest/path serve
    SabrOfflineDownloader.ets    — offline download path
  subtitle/
    VttSubtitleParser.ets        — WebVTT/SRT cue parsing + active-cue lookup
                                   (rolling-window dedup for YouTube auto captions)
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
    ContextProvider.ets          — UIAbilityContext getter (injected via setProvider)
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
- **Subtitles render via the ArkUI overlay**, not mpv’s burned-in libass
  path: `AvPlayerController.switchSubtitle` fetches the track URL
  (timedtext `fmt=vtt`) through the proxy-aware `fetchText` (one bounded
  retry), parses it with `subtitle/VttSubtitleParser`, and
  `updateSubtitleOverlayText` (driven by the engine’s ~100ms time-pos
  updates, adjusted by `PlaybackPreferences.subtitleOffsetMs`) writes
  `vm.subtitleText`. Never re-add `sub-add` calls — the engine
  `setSubtitle`/`subText` plumbing is dormant.
  `fetchText` throws on non-200; for `tlang=` (server-translated) URLs it
  attaches login Cookie + SAPISIDHASH from
  `setSubtitleAuthHeaderProvider` (wired by `EntryAbility`, PipePipe
  risk-control parity).
  App-generated subtitle content (AI translation `ai://…` / on-device ASR
  `asr://…` tracks from entry) enters through
  `AvPlayerController.switchSubtitleText(trackKey, vttText)` — same overlay
  pipeline, no fetch, same-key re-push always re-applies (same-key re-push
  no longer blanks `vm.subtitleText`, so high-frequency incremental pushes
  do not flash). P2 and P3 ASR are both **[DISABLED]** in entry
  (commented out). `parseVttSubtitles` / `SubtitleCue`
  are exported from `mediaservice/Index.ets` for entry's AI subtitle
  services.
- Source submission has a **single writer** — entry `PlayerSession.play()`;
  duplicate suppression lives there, so a controller submission always
  means a real load.
- MPV direct network fetches (HLS masters/segments, `sub-add` subtitle
  URLs) follow the app proxy through the process environment:
  `MpvPlaybackEngine.applyNetworkProxy` (on `load()`) calls libmpv_napi
  `setHttpProxyEnv`, which sets `http_proxy` (+ `no_proxy` =
  `127.0.0.1,localhost` so the loopback proxy stays direct). The vendored
  libmpv has **no** `network-proxy` property — do not reintroduce that
  `setProperty` call. The env is only written at `load()`; when the socks5
  bridge self-heals onto a new ephemeral port,
  `MpvPlaybackEngine.refreshNetworkProxy()` re-applies it for the current
  source (wired from entry's bridge port-change hook via
  `AvPlayerController.refreshNetworkProxy`).

## 4. Local proxy architecture
`LocalProxyServer` exposes a loopback HTTP endpoint so MPV always consumes a
stable local URL. Session types in `SessionStore`:

| Type | Role |
|---|---|
| `single` | Simple range/proxy session (also the per-track building block of the EDL dual-playback fallback) |
| `youtube-dual` | Direct-link DASH dual (video+audio) with SIDX/`YoutubeDashIndex` — the production path for visionos / tv_downgraded VOD |
| `sabr-dual` | SABR UMP dual tracks via `sabrSessionStore` (mweb opt-in path) |

**Direct-link dual path (product VOD: visionos / tv_downgraded)**:
`AvPlayerController.buildDualDashUrl` creates one `youtube-dual` session
(SIDX-parsed exact segment tables for both tracks) and hands MPV a loopback
`manifest.mpd` (SegmentTemplate + SegmentTimeline, per-segment proxy endpoints
`/session/{id}/video|audio/0/{init|N}`), demuxed by mpv's native `demux_dash`.
`buildDualEdlUrl` (two `single` open-range sessions + `edl://`) survives only
as the build-time fallback when SIDX/init metadata is unavailable. Segment
responses are exact and complete: `serveExactSegmentRange` in `RangeProxy`
serves one 200 per segment and slices >10MB segments into sequential upstream
fetches internally (YouTube throttles larger ranges) so MPV never sees a
truncated segment.
Upstream transports in `RangeProxy`: Android/iOS (empty-body POST) and
VISIONOS (body-less GET) googlevideo requests stream over RCP so MPV's first
byte never waits for a full buffered chunk; other clients — TVHTML5 included,
for which RCP streaming has been 403-prone on range probes — use buffered
`@ohos.net.http` GET. Connect timeout is 10s (PipePipe OkHttp parity); transfer/read stays 30s
(RCP `transferMs` covers the whole stream). YouTube streaming fetches share a
long-lived RCP session per proxy session via `RcpSessionPool` (key =
`sessionId|proxy-fingerprint`, LRU cap 32 — far below the system 1024-session
limit; evict/destroy closes sessions, wired into `wireSessionCancel`), so the
API-24 `connectOnly` pre-connect fired at source commit
(`LocalProxyServer.createSession` / `addPreparedSession` →
`preconnectYoutubeHosts`, video+audio hosts only, fire-and-forget, WARN-only
on failure) warms the exact connection pool MPV's first range fetch then
reuses. Every RCP session — YouTube and
non-YouTube alike — resolves the app proxy through the shared
`resolveRcpProxy` (http → upstream URL with auth, socks5 → loopback bridge
URL with `createTunnel:'always'`, otherwise `'no-proxy'`).

**SABR dual path (mweb opt-in)**:
1. Extractor returns SABR bootstrap (`YoutubeSabrInfo` / streams with SABR delivery).
2. `sabrSessionStore.acquire` builds `YoutubeSabrSession` (youtube_core UMP).
3. `SabrTrackBuffer.ensureReady` warms video then audio (PoToken via entry provider when needed).
4. Loopback DASH/range URLs from `SabrDashProxy` are handed to MPV.
5. Offline: `SabrOfflineDownloader` for entry downloads.

Startup: demand-side SIDX fetches gate on the pending DASH PoToken injection
(`LocalMediaProxy.setStartupUrlGate`). The former fire-and-forget SIDX
prefetch was removed from the play path; SIDX is fetched on demand at
`youtube-dual` session build (parallel for both tracks, transient-403 retry).

**Upstream cancel / teardown**:
- Every `serveRange` fetch registers its in-flight op (RCP request / netstack
  `HttpRequest`) in `UpstreamCancelRegistry`, keyed by loopback connection and
  session. A closed connection (MPV seek/disconnect, or a `TcpWriter` send
  failure) cancels that connection's op; `DashSession.cancel` — wired by
  `LocalProxyServer` at session registration and invoked by `destroySession` —
  cancels all of the session's ops and, for SABR, calls
  `sabrSessionStore.abort` (closes the UMP session only when this proxy
  session is the sole lease holder; `release` stays the refCount-driven
  closer). Aborted fetches are quiet teardown: the retry loop never retries
  an abort and logs DEBUG only. `UpstreamCancelRegistry.cancelAll` aborts
  every op across all sessions without tearing anything down — the
  network-handover path (`LocalMediaProxy.abortAllUpstreamFetches`, wired by
  entry `NetworkHandoverService`).
- `SabrTrackBuffer.readSegment` has one overall wait budget
  (`READ_SEGMENT_BUDGET_MS`, 45s) per call — the server-owned backoff deadline
  is never cleared, only the wait is capped. Exhaustion throws
  `SabrReadTimeoutError`; `SabrDashProxy` answers MPV with 504 so it retries
  per its own reconnect policy.
- `SabrTrackBuffer` keeps a `pumpGeneration` bumped by `resetForSeek`; a pump
  in flight across a seek drops its post-await results instead of ingesting
  old-window segments against the new `baseOffset`.

**Pacing / lease rules**:
- The SABR session owns the UMP server backoff: `pumpOnceLocked` waits out
  the remaining deadline **inside** the serialized pump lock
  (`YoutubeSabrSession.ets`, capped by `MAX_BACKOFF_MS`), and local
  recovery/seek never clears the server deadline.
- Offline downloads acquire their lease with the `'|dl'` key suffix, so a
  download never shares a session (playhead, segment cache, forward-jump
  resets) with concurrent playback on the same video/formats; release/abort
  key off `lease.key` and stay balanced automatically.
- A failed session build must release the lease so the store can retry.
- entry injects both the `SabrPoTokenProvider` and the `SabrInfoReloader`
  into `sabrSessionStore` (`setPoTokenProvider` / `setInfoReloader`);
  `acquire` passes them into every new `YoutubeSabrSession`. PoToken is
  minted lazily by the session (empty/protected response, or background
  warmup on status>=2 media); protection recovery (rotate/reload) happens
  inside the session via youtube_core's policy layer.
- Transient vs terminal SABR errors are distinguished by
  `SabrProtocolException.kind` (`SabrErrorKind` — 9 kinds, defined in
  `youtube_core` `extractor/sabr/SabrProtocolException.ets`):
  'protection'/'no_media'/'segment_unavailable' are retryable,
  'beyond_end' signals end-of-stream to the caller, 'closed' is quiet
  teardown on session close, 'attestation_required'/'reload_exhausted'/
  'redirect'/'protocol' are terminal — never match on error message
  strings.
- `SabrTrackBuffer` pumps on demand to satisfy each range request
  (`readRange` → `ensureBytes`); each pump first tries an opportunistic
  direct fetch of the next segment, then falls back to the session's
  serialized `pumpOnce`, so a single slow pump or one dropped POST cannot
  underrun the player.

Do not teach MPV remote SABR URLs directly; always go through the local proxy.

**Live HLS** (demuxed YouTube master, `?mpd_version=7`): one master GET in
`AvPlayerController.resolveLiveHlsStreams` picks the variant ≤ the quality
cap **and** the top-bitrate audio rendition (EXT-X-MEDIA / audio-only
STREAM-INF, itag 233/234). The video variant URL goes to MPV directly — no
proxy; the audio rendition is registered as an mpv external file before
loadfile (`change-list audio-files append/clr` in `MpvPlaybackEngine.load`),
so mpv opens audio together with the video and the first frame has sound.
Never feed mpv a bare variant URL without the external audio — variants are
video-only. Two mpv traps this avoids: list `-set` parsing splits on literal
`,` and `:` inside these URLs (change-list `append` takes one raw item), and
`audio-add` before the file is playing silently no-ops. Master-direct +
`hls-bitrate` is also rejected: FFmpeg probes every variant serially and
the audio renditions expire mid-probe. A quality
switch re-runs the same helper and restarts at the live edge with the new
variant + audio pair.

## 5. Config injection
- `PlaybackPreferences.setProvider(...)` is the **only** way
  `mediaservice` reads UI/playback prefs. `entry` wires this in
  `EntryAbility.onCreate`.
- `ContextProvider.setProvider(...)` is the **only** way `mediaservice`
  reads the `UIAbilityContext` (lazy getter, also wired in
  `EntryAbility.onCreate`).
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
- Listeners register via `PlayerStateMachine.addListener(listener)` /
  `removeListener(listener)`.
- The `backgroundTaskListener` is attached in `AvPlayerController` to keep
  the background continuous task alive across the playing lifecycle.

## 8. Conventions
- **No `AppStorage` reads in mediaservice.** Config/prefs and the
  `UIAbilityContext` go through the `setProvider` hooks. The AVSession GC
  pin (`__avSession_pin` set/delete) is the sole remaining exception.
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
- Read config/prefs or the `UIAbilityContext` via `AppStorage` — inject
  through the `setProvider` hooks (the AVSession pin is the only remaining
  exception).
- Use cross-device continuation APIs (handoff is `entry`'s concern);
  `@kit.AbilityKit` imports stay limited to `common` / `wantAgent`.
- Edit files under `libmpv_napi/src/main/cpp/{ffmpeg-sdk,mpv-sdk}` — vendored.
- Add a second playback backend beside `MpvPlaybackEngine`.
- Feed MPV remote SABR/googlevideo URLs without the local proxy.
- Add top-level mutable state in `Index.ets`; export factories or
  `getInstance()` accessors instead.
- Commit `Crash_*.dmp`, `.cxx/`, `build/`, `.hvigor/` artifacts.
- Put changelogs or commit-specific notes into this file.
