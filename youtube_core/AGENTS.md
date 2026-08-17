# youtube_core/AGENTS.md

> YouTube extraction HAR. Pure logic — no UI, no `AppStorage`, no
> `mediaservice` imports. Resolves YouTube IDs to playable streams via
> configured player clients, runs the cipher (native JSVM + PipePipe
> remote), parses HLS, runs **SABR/UMP sessions**, dual-rail auth
> (Cookie/WEB + OAuth/TV), and optional app HTTP proxy. Durable
> architecture only — no changelogs.

## 1. Public surface (`youtube_core/Index.ets`)
- Extractor: `YouTubeExtractor`, `VideoInfo`, `StreamInfo`, `ItagInfo`,
  `ItagItem`, `MediaFormat`, `HlsManifestParser`, `YouTubeExceptions`,
  `PlayerResponseTypes`, `CommentItem`.
- Cipher: `PipePipeApiDecoder`, `YoutubeJavaScriptPlayerManager`, `ApiConfig`.
- Player clients: `ConfiguredPlayerClient`, `ClientTypes` module
  (`ClientFetchResult` / `ClientFetchContext`),
  `YoutubePlayerClientConfig`.
- SABR/UMP: `YoutubeSabrInfo`, `YoutubeSabrSession`, `YoutubeSabrStreamState`,
  `SabrMediaSegment`, `SabrPoTokenProvider`, `SabrProtocolException`.
- Auth: `AuthSessionManager`, `CookieAuthCredential`, `SapisidHashUtil`,
  `DebugAuthConstants`, `SmartTubeAuthProbe`, `AuthModels` (`AuthRail`, status).
- Network: `YouTubeHttpClient`, `CookieJar`, `HttpDownloader`,
  `HttpProxyOptions` (+ snapshot/kind types), `Socks5Bridge`.
- Models: `Localization`, `ContentCountry`, `DeliveryType`,
  `ClientsConstants`, `SearchContentFilter`, `SearchResultModel`, `VideoModel`,
  chapters/subtitles on `VideoInfo` as applicable.
- Service: `YoutubeApi` (high-level façade).
- Logger: `YTCoreLogger.setSink(...)`.
- Utils: `Utils`, `YoutubeParsingHelper`, `WebClientVersionResolver`,
  `SearchQueryHandlerFactory`, `YoutubeSearchQueryHanderFactory`.

## 2. Layout
```
youtube_core/src/main/
  ets/
    extractor/
      YouTubeExtractor.ets             — main extraction flow
      VideoInfo.ets, StreamInfo.ets, ItagInfo.ets
      HlsManifestParser.ets            — HLS m3u8 parser
      PlayerResponseTypes.ets          — player_response JSON shapes
      YouTubeExceptions.ets            — extraction errors
      CommentItem.ets
      cipher/
        PipePipeApiDecoder.ets         — sig decode via PipePipe API
        YoutubeJavaScriptPlayerManager — local JSVM + prewarm + fallback
        ApiConfig.ets
      clients/
        ConfiguredPlayerClient.ets     — sole stream player (mweb/safari/vr/tv)
        ClientTypes.ets
      sabr/
        YoutubeSabrInfo.ets            — bootstrap from player response
        YoutubeSabrSession.ets         — UMP POST session + segment fetch (executor)
        YoutubeSabrStreamState.ets     — local track progress + seek (delegates
                                         cookie/contexts/poToken to the epoch)
        SabrServerEpoch.ets            — server-owned epoch state (url/rn/redirect/
                                         backoff/cookie/contexts/poToken/budgets)
        policy/
          SabrSessionPolicy.ets        — action types + policy context + budgets
          BuiltinSabrSessionPolicy.ets — response → action-chain decisions
        YoutubeSabrRequestBuilder.ets
        UmpReader.ets, SabrProto.ets, SabrResponseDecoder.ets
        SabrMediaSegment.ets, SabrMediaHeader.ets, SabrDecodedResponse.ets
        SabrMp4SegmentIndex.ets, SabrBufferedRange.ets
        SabrPoTokenProvider.ets        — interface (impl lives in entry)
        SabrInfoReloader.ets           — re-probe interface (impl lives in entry)
        SabrProtocolException.ets      — typed `kind` error (no string matching)
      identity/
        SessionIdentity.ets            — visitorData + client + playerPoToken
        SessionIdentityManager.ets     — pin/invalidate + SessionPoTokenHook
      itag/
        ItagItem.ets, MediaFormat.ets
    auth/
      AuthSessionManager.ets           — dual-rail session lifecycle
      CookieAuthCredential.ets
      SapisidHashUtil.ets              — SAPISIDHASH for WEB rail
      SmartTubeAuthProbe.ets           — OAuth device-code (TV rail)
      DebugAuthConstants.ets           — OAuth client/device constants
      AuthModels.ets                   — AuthRail, status, token types
    network/
      YouTubeHttpClient.ets
      HttpDownloader.ets
      CookieJar.ets
      HttpProxyOptions.ets             — injected from entry NetworkProxyConfig
      Socks5Bridge.ets                 — loopback HTTP CONNECT bridge → SOCKS5
    service/
      YoutubeApi.ets
    model/
      Localization, ContentCountry, DeliveryType, ClientsConstants,
      SearchContentFilter, YoutubePlayerClientConfig
    common/
      VideoModel, SearchResultModel, Utils, YoutubeParsingHelper,
      WebClientVersionResolver, SearchQueryHandlerFactory,
      YoutubeSearchQueryHanderFactory, YTCoreLogger
  cpp/
    CMakeLists.txt                     — native module `yourpipe_cipher`
    cipher_jsvm_napi.cpp               — JSVM n/sig decode NAPI
    ejs_bundle.generated.h             — embedded player JS helpers
    types/libyourpipe_cipher/          — NAPI types package
```

## 3. Extractor flow (playback-critical path)
1. **Resolve video ID** from URL or ID string.
2. **Client selection** via `YoutubePlayerClientConfig` (single client):
   - allow-list: `mweb` | `web_safari` | `visionos` | `android_vr` | `tv_downgraded`
   - **product default follows PipePipe**: guest → `visionos` (pot-free,
     POSTs the GAPIS endpoint `youtubei.googleapis.com`, no sts/pot), signed-in →
     `tv_downgraded` (entry calls `resetToAuthDefault`/`applyAuthDefault`);
     both resolve to direct adaptiveFormats URLs. `android_vr` is a guest
     fallback that requires a session pot. `mweb` (SABR) is an
     opt-in/debug selection only
   - `tv_downgraded` + Bearer doubles as the **restricted / OAuth recovery**
     path (skipped when the selected client already is tv_downgraded)
3. **Critical path only** (`extractVideoStreams`):
   - STS: process cache → prewarm decoder metadata → watch HTML → remote latest-player
   - one stream `POST www.youtube.com/youtubei/v1/player?prettyPrint=false`
     (no `$fields` projection; `$fields=microformat,playabilityStatus,
     storyboards,videoDetails` applies only to the deferred WEB metadata
     player)
   - mweb starts with cached/hardcoded WEB client version; dynamic resolve
     (`WebClientVersionResolver` / `sw.js`) runs on empty-`streamingData` recovery
   - `buildAndCacheStreams`:
     - `mweb` + VOD + `serverAbrStreamingUrl` → **SABR** streams (`deliveryMethod: SABR`)
     - else adaptiveFormats (not `formats[]`), skip for `tv_downgraded`+LIVE
      - HLS only when: post-live | live+`tv_downgraded` | `web_safari`;
        live HLS masters are background-parsed into per-variant quality
        streams (quality menu fills in when ready; a switch restarts at the
        live edge)
     - `dashMpdUrl` always empty
   - n/sig decode via local JSVM (`yourpipe_cipher` / manager READY), else PipePipe remote API
4. **Deferred enrichment** (`fetchPlaybackExtras`, after source commit):
   - WEB metadata `/player` (no streamingData)
   - `/next` (related, likes, chapters)
   - RYD dislikes
5. Comments and channel profile fetch are UI-driven and must not race stream extract.

## 4. SABR / UMP
- **Bootstrap**: `YoutubeSabrInfo` from player response (`serverAbrStreamingUrl` + formats).
- **Session**: `YoutubeSabrSession` POSTs UMP, parses with `UmpReader` /
  `SabrResponseDecoder` / `SabrProto`, caches segments, applies PoToken when
  protected (via `SabrPoTokenProvider` implemented in entry).
- **Consumers**: `mediaservice` `sabrSessionStore` / `SabrTrackBuffer` lease the
  session and serve loopback DASH/range to MPV. Do not invent a second UMP client.
- **Session identity** (`identity/SessionIdentityManager`): one visitorData is
  pinned per app session — prefer the prewarmed watch-page value, else the
  first player-response value. PoToken mints and the mweb /player request are
  anchored on this value. `invalidate()` marks the identity dead; the next
  re-pin prefers the fresh player-response value over the prewarmed one so
  attestation rotation actually lands on a new identity. Mechanism:
  `invalidate()` sets `invalidatedSinceLastPin`; the next
  `getSessionVisitorData` pin then prefers the fresh player-response
  visitorData over the prewarmed value (`SessionIdentityManager` +
  `YoutubeJavaScriptPlayerManager`). Never log the value.
- **UMP request headers** mirror PipePipe `buildSabrHeaders` per profile
  (`YoutubeSabrSession.buildSabrHeaders`): every profile sends
  `Content-Type: application/x-protobuf` + `User-Agent`; **web-like profiles
  (mweb/web)** additionally send `Accept: */*` + `Accept-Language` +
  `Origin: https://www.youtube.com` + `Referer: https://www.youtube.com/`;
  **non-web profiles** instead send `Accept: application/vnd.yt-ump` +
  `Accept-Encoding: identity` + `X-Goog-Visitor-Id` (when visitorData is
  known). **No** `Cookie` or `Authorization` on UMP POSTs (login is bound
  through the /player request, never on the UMP rail). Do not put the
  non-web ump header shape (`Accept: application/vnd.yt-ump` /
  `Accept-Encoding: identity` / visitor id) on a web-like profile, or the
  reverse.
- **Request URL params**: `alr=yes` appended when missing; `cpn` and `rn`
  are replace-or-append (`replaceOrAppendQuery` — an existing value is
  overwritten), `rn` is the 1-based request number
  (`rn = String(requestNumber + 1)`, so `rn=1` for the first POST).
- **Protection state machine** (policy layer, PipePipe origin/main): responses
  are decided by `BuiltinSabrSessionPolicy` → action chains, executed by
  `YoutubeSabrSession`. No-media + status>=3 (attestation required) fails
  immediately (`kind='attestation_required'`). status==2 (pending) rotates
  first **with or without media** (PipePipe 60462a13 — a pending response can
  carry the demanded segment): `ROTATE_IDENTITY` (budget 3: invalidate
  identity → re-probe via `reprobeSabrInfo` → visitorData must change → epoch
  reset, local progress kept via `YoutubeSabrStreamState.ingestLocalProgress`
  so the fresh epoch advertises the cached range); with media a successful
  rotation retries the fetch loop and the preserved segmentCache delivers.
  No-media pending falls through `APPLY_PO_TOKEN` (force-refresh budget 2,
  resets when media arrives) → `RELOAD_PLAYER` (only once the refresh budget
  is spent) → FAIL. The pending counter increments only on no-media pending
  responses; three consecutive fail regardless. All budgets live in
  `policy/SabrSessionPolicy.ets` (`SABR_MAX_*`).
- **Token acceptance past ~1min** (PipePipe 99caff45b "mint accepted SABR PO
  tokens"): the att/get challenge and GenerateIT must be bound to the session
  visitorData + WEB client identity — att/get body carries `visitorData` and
  the request headers carry `X-Goog-Visitor-Id`, `X-YouTube-Client-Name(1)`,
  `X-YouTube-Client-Version`, `Origin`, `Referer`. A token minted without this
  binding is accepted initially but rejected at the ~1min protection boundary.
  The BotGuard JS `vm.a(...)` call must pass the current 9-argument signature
  (incl. the `loggerFunctions` array); a stale signature produces tokens the
  server rejects mid-playback. A forced mint must discard the old minter
  (invalidateGenerator semantics) before rebuilding.
- **Backoff is session-owned**: the UMP server deadline (epoch `backoffUntilMs`)
  is honored before every POST and is **not** cleared by seek, hole/policy
  recovery, or local stall resets; it clears only when media arrives, the
  server stops demanding it, or an identity rotation starts a new epoch. An
  empty response without a PoToken mints one immediately instead of waiting
  out the backoff empty-handed.
- **Player reload** (`RELOAD_PLAYER` action): a `RELOAD_PLAYER_RESPONSE` part
  means the server's streaming URL / ustreamer config expired on a long watch.
  The session calls its `SabrInfoReloader` (wired by entry through
  `sabrSessionStore.setInfoReloader`, backed by `YouTubeExtractor.reprobeSabrInfo`
  serialized through the extraction chain), swaps in the new bootstrap and
  resumes in place — `requestNumber > 0` is kept so the next POST is a
  follow-up on the new URL, never a restart. Bounded by
  `SABR_MAX_RELOADS_PER_SESSION`; a visitorData change clears the PoToken and
  re-mints before resuming (a failed re-mint is terminal, never a reuse of the
  old token). If no reloader is wired or the budget is spent, reload fails.
- **Identity rotation re-probe**: `reprobeSabrInfo(videoId)` re-resolves the
  STS, re-fetches the mweb stream player, and rebuilds the bootstrap via
  `buildSabrInfo` — the fresh player-response visitorData is pinned through
  the normal `getSessionVisitorData` path (post-invalidation it wins over
  the prewarmed value), and the /player request picks up a PoToken bound to
  the new identity via `SessionIdentityManager.getPlayerPoToken(...)` →
  `SessionPoTokenHook.getPlayerPoToken(...)`, capped call-side by
  `PLAYER_PO_TOKEN_TIMEOUT_MS` in `ConfiguredPlayerClient`.
- **Context updates**: `SABR_CONTEXT_UPDATE` (57) / `SABR_CONTEXT_SENDING_POLICY`
  (59) parts are absorbed into the epoch and echoed back via streamerContext
  field 5 (active contexts). `getUnsentSabrContextTypes` is an MVP stub that
  returns empty — field 6 is not yet echoed.
- **PoToken minting**: entry pre-initializes the BotGuard runtime at app
  startup (`warmRuntime` on the pinned visitorData), so a mid-playback mint is
  only `mintIdentifier`. The session mints lazily: on an empty response
  without a token, on a protection boundary, and as a background warmup when
  media arrives with status>=2 and no token. Mint is bounded by a 30s timeout
  + circuit breaker in the entry provider.
- **Session pot on the player request**: every non-TV Innertube /player request
  (mweb / web_safari / android_vr — PipePipe `prepareSessionPoTokenPlayerRequest`
  skips only TVHTML5; `visionos` hits the GAPIS endpoint and is pot-free by
  design) carries `context.client.visitorData` in the body
  (identity-layer value; the request headers stay Content-Type / UA /
  Client-Name / Client-Version only — `X-Goog-Visitor-Id` appears only on
  non-web UMP POSTs) and, when the BotGuard runtime is already warm,
  `serviceIntegrityDimensions.poToken` — sourced through
  `SessionIdentityManager.setPlayerPoTokenHook` (entry provider, content
  binding = the visitorData string itself, ~128B session pot, 5s cap; when
  the BotGuard runtime is cold it attempts ONE bounded cold mint under the
  same 5s cap instead of skipping — an un-potted android_vr response 403s on
  googlevideo — and falls back to skipping on timeout). tv_downgraded requests
  stay entirely token-free (PipePipe 7673caed). The UMP streamerContext
  carries the separate per-video pot (content binding = `videoId`, ~91B).
  Identity invalidation clears all three caches (UMP, dash, player).

## 5. Player clients
- `ConfiguredPlayerClient` — **sole** stream player path (PipePipe shape).
  All keys POST `www.youtube.com/youtubei/v1/player` with
  `playbackContext.signatureTimestamp` + client-specific UA / Client-Name.
- **`visionos` is the exception** (PipePipe `fetchVisionOsJsonPlayer` /
  `prepareJsonBuilder`): POST `youtubei.googleapis.com/youtubei/v1/player?prettyPrint=false&t=<12 random chars>&id=<videoId>`,
  body = `context.client{clientName/clientVersion/clientScreen=WATCH/
  platform=MOBILE/deviceMake/deviceModel/osName/osVersion/hl/gl/
  utcOffsetMinutes=0/[visitorData]}` + `context.request{internalExperimentFlags,
  useSsl}` + `context.user{lockedSafetyMode}` — **no** playbackContext/
  signatureTimestamp/pot; headers = Content-Type + visionOS UA +
  `X-Goog-Api-Format-Version: 2` only.
- **Live classification** (`resolveIsLive` / `resolveIsPostLive`) follows
  PipePipe `setStreamType`: `videoDetails.isLive` is the primary LIVE signal,
  `isPostLiveDvr` marks DVR replays, microformat `isLiveNow` and
  `liveStreamability`+HLS are fallbacks. Never rely on microformat alone —
  visionos GAPIS responses carry no microformat block (a running live was
  misclassified as post-live and sent down the DASH path → infinite buffer).
  The anonymous MWEB HLS helper only fires when the selected client's
  response lacks `hlsManifestUrl`.
- Auth attachment is **rail-aware**: mweb uses Cookie/SAPISIDHASH only;
  TV client uses Bearer only. Never stuff Bearer into Cookie fields or
  Cookie into TV headers.
- **Player request body must mirror PipePipe's NORMAL path exactly**
  (`createJsonPlayerBody` / `fetchConfiguredJsonPlayer` +
  `prepareSessionPoTokenPlayerRequest`): `context.client{utcOffsetMinutes,
  timeZone, hl, gl, userAgent, clientName, clientVersion, [visitorData],
  [VR device fields]}` + `playbackContext.contentPlaybackContext{
  html5Preference, signatureTimestamp}` + `cpn/videoId/contentCheckOk/
  racyCheckOk` + `serviceIntegrityDimensions.poToken` (session pot).
  **Never** send `platform`, `context.request`, `context.user`, or
  `referer/vis/splay/lactMilliseconds` — those exist only in PipePipe's
  reload-only probe body (`createPlayerBody`), not the normal path.
- Player request headers: `Content-Type: application/json`, `User-Agent`,
  `X-YouTube-Client-Name`, `X-YouTube-Client-Version` only — **no
  Origin/Referer** (PipePipe `getJsonPlayerResponseAsync` does not add
  them), except `tv_downgraded` which adds
  `Origin: https://www.youtube.com` + `Referer: https://www.youtube.com/tv`;
  Cookie/X-Origin/DNT/Authorization only when logged in.
- WEB metadata `/player?$fields=...` and `/next` share the WEB desktop
  body (`buildDesktopWebPayload` = PipePipe `prepareDesktopJsonBuilder` +
  videoId/contentCheckOk/racyCheckOk); neither request carries a session
  pot or visitorData — `fetchWebMetadataPlayerResponse` sends only
  `buildDesktopWebPayload` + `webDesktopApiHeaders()`; `/next` stays
  anonymous (PipePipe does not pot-decorate it).

## 6. Auth (dual-rail)
```
AuthSession (credentials may coexist)
├── web rail: Cookie + SAPISIDHASH → WEB browse / most players
└── tv  rail: Bearer (+ optional pageId) → TV browse / tv_downgraded player

Priority when both present:
  user-data / home: WEB first → else TV → else kiosk
  playback:        Cookie/OAuth → tv_downgraded → else anonymous visionos

Fine-grained toggles: useAuthForUserData, useAuthForPlayback, master authEnabled
```
- `AuthSessionManager.init(context)` — bootstraps storage; called from entry.
- Prefer `getWebAuthorizationHeader` / `getTvAuthorizationHeader` at call sites.
- Credential-state changes (login/logout/rail switch) must reset the pinned
  session identity + PoToken caches (PipePipe LocalDomPoTokenProvider
  credential-bound isolation): entry `AuthStateHelper.refresh()` does this via
  a credential-rail fingerprint → `resetSessionVisitorData()` +
  `SabrWebViewPoTokenProvider.resetForAuthChange()`.
- `SmartTubeAuthProbe` — OAuth **device-code** sign-in (entry `DeviceQrLoginPage`).
- Cookie WebView login is entry-owned (`WebViewLoginPage`); this module stores credentials.
- `DebugAuthConstants` holds OAuth client/device URLs used by the device flow;
  do not scatter new hard-coded OAuth secrets elsewhere.

## 7. Network
- `YouTubeHttpClient` — wraps `@ohos.net.http` with cookie persistence via
  `CookieJar`. Sets the right `Origin` / `Referer` for YouTube.
- `HttpProxyOptions.setProvider` — only way this module sees app proxy config;
  entry `NetworkProxyConfig` injects it. Do not read system proxy ad hoc.
- `HttpDownloader` — used by entry `DownloadManager` to save streams.
- `Socks5Bridge` — SOCKS5 proxies are supported through a loopback HTTP
  CONNECT bridge.

## 8. Native cipher (`yourpipe_cipher`)
- Built from `youtube_core/src/main/cpp` as NAPI module `yourpipe_cipher`.
- `YoutubeJavaScriptPlayerManager` loads `libyourpipe_cipher.so` for local
  n/sig decode when the player JS / STS path is READY; otherwise falls back
  to PipePipe remote API.
- Entry may call `startAppPrewarm(context)` at launch so first play is warm.
- Startup metadata (STS `signatureTimestamp` + WEB `clientVersion`) is
  persisted beside the player JS disk cache (TTL'd) so a cold start can
  prepare the JSVM without watch/sw.js fetches; a background watch fetch
  still verifies and captures visitorData for session pinning.

## 9. Logger injection
- `YTCoreLogger.setSink((level, tag, message) => ...)` is wired in
  `EntryAbility.onCreate`. Do not call `console.log` / `hilog` directly.

## 10. Conventions
- **No `AppStorage.get` calls.** Pass context-dependent data via
  `setProvider` hooks (proxy, sinks) or function arguments.
- **No `mediaservice` imports.** This module is upstream of `mediaservice`.
- **No direct stream URLs without going through the extractor.** Add a
  client in `extractor/clients/` if a stream is missing — do not bypass.
- **`Index.ets` exports are static references.** No top-level mutable state.
- **Logger**: use `YTCoreLogger` (which goes to the sink), not `console.log`.
- **SABR**: keep UMP protocol here; keep loopback serve/lease in mediaservice;
  keep PoToken WebView in entry.

## 11. Do not
- Call `AppStorage.get` from this module.
- Import `mediaservice` or `entry` — wrong dependency direction.
- Bypass the extractor to fetch a stream directly. Add or fix a client
  in `extractor/clients/` instead.
- Claim SABR is “bootstrap only” or reintroduce a parallel UMP client.
- Mix WEB Cookie rail with TV Bearer rail on the same request.
- Scatter OAuth client secrets outside `DebugAuthConstants` / session manager.
- Commit `Crash_*.dmp`, `.cxx/`, `build/`, `.hvigor/` artifacts or any
  `AGENTS.md`.
- Add top-level mutable state in `Index.ets`; export factories or
  `getInstance()` accessors instead.
- Put changelogs or commit-specific notes into this file.
