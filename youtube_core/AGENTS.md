# youtube_core/AGENTS.md

> YouTube extraction HAR. Pure logic — no UI, no `AppStorage`, no
> `mediaservice` imports. Resolves YouTube IDs to playable streams via
> configured player clients, runs the cipher (native JSVM + PipePipe
> remote), parses HLS, runs **SABR/UMP sessions**, dual-rail auth
> (Cookie/WEB + OAuth/TV), and optional app HTTP proxy. Durable
> architecture only — no changelogs.

## 1. Public surface (`youtube_core/Index.ets`)
显式命名导出（无 `export *`），名单 = entry / mediaservice 的实际消费面；
新增跨模块符号必须在 `Index.ets` 登记。按组分块，以文件内注释为准：
extractor（模型 + 异常层次 + 评论 + HLS 解析 + `ItagItem`）、sabr/identity（opt-in/debug
路径）、cipher（`YoutubeJavaScriptPlayerManager`）、model/localization、
network（含 `YOUTUBE_COOKIE_STORAGE_NAME`）、auth（含 `AUTH_STORAGE_NAME`
与 `AuthExpiredError` / `isAuthRejectionResponse`）、
service（`YoutubeApi` 的高层函数）、`YTCoreLogger`。

## 2. Layout
```
youtube_core/src/main/
  ets/
    extractor/
      YouTubeExtractor.ets             — main extraction flow
      CommentsExtractor.ets            — comments/replies (CommentsBackend 窄接口)
      PlayabilityChecker.ets           — playability 状态判定（无状态静态方法）
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
      WebRailHeaders.ets               — shared WEB-rail header assembly
                                         (Cookie/X-Origin/DNT/Authorization)
      SmartTubeAuthProbe.ets           — OAuth device-code (TV rail)
      DebugAuthConstants.ets           — OAuth client/device constants
      AuthModels.ets                   — AuthRail, status, token types
      AuthExpiredError.ets             — typed 401 / UNAUTHENTICATED error
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
      WebClientVersionResolver, YoutubeSearchQueryHandlerFactory,
      YTCoreLogger, ProtoUtil
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
   - **per-state configurable** (entry Options → 播放端点 →
     `setConfiguredClients(guest, auth)`): guest allow-list `visionos|mweb`
     (default `visionos`, pot-free GAPIS endpoint `youtubei.googleapis.com`,
     no sts/pot), signed-in allow-list `tv_downgraded|mweb` (default
     `mweb` SABR; `tv_downgraded` stays the token-free direct-URL option);
     direct clients resolve to direct adaptiveFormats URLs. `applyAuthDefault` / `resetToAuthDefault` pick the
     configured value for the current auth state (entry 侧统一经
     `AuthStateHelper.reconcilePlaybackClient`). `web_safari` / `android_vr`
     are unused endpoints kept for reference (android_vr was dropped upstream
     by PipePipe v5.3.0). The explicit pin (`setYoutubePlayerClient`) survives
     per-extraction `applyAuthDefault` but is DORMANT — the settings UI goes
     through the per-state config, not the pin.
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
     - visionos with zero streams + no HLS → ANDROID `reel/reel_item_watch`
       muxed `formats[]` fallback (PipePipe fetchAndroidReelMuxedFormats, but
       deferred: fired only when the primary path is empty, not per extraction)
      - HLS only when: post-live | live+`tv_downgraded` | `web_safari`;
        live HLS masters are background-parsed into per-variant quality
        streams (variant `bitrate` carries BANDWIDTH/AVERAGE-BANDWIDTH; audio-only
        STREAM-INF entries without RESOLUTION whose CODECS resolves to no
        video codec are classified into `audioStreams` with their bitrate — mediaservice attaches the top one
        as an mpv external audio file; the quality menu fills in when ready and a switch
        restarts at the live edge on the new variant URL)
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
  protected (via `SabrPoTokenProvider` implemented in entry). UMP response
  body bytes are reported as they arrive (per `dataReceive` chunk) through
  `setSabrNetworkTrafficSink` (wired by mediaservice to its proxy traffic
  meter for the stats UI). `abortInFlightPost(reason)` is the
  network-handover lever (wired by entry through mediaservice
  `sabrSessionStore.abortAllInFlightPosts`): aborts only the in-flight UMP
  POST so a stale connection fails fast on a default-network switch — the
  session stays open, no policy/epoch state changes, and the existing
  catch/retry paths re-POST on the new network.
- **Consumers**: `mediaservice` `sabrSessionStore` / `SabrTrackBuffer` lease the
  session and serve loopback DASH/range to MPV. Do not invent a second UMP client.
- **Session identity** (`identity/SessionIdentityManager`): one visitorData is
  pinned per app session — prefer the prewarmed watch-page value, else the
  first player-response value; once the entry PoToken generator completes a
  home page bootstrap it pins the bootstrap visitorData (PipePipe parity: the
  mweb pot path runs on the home page identity). PoToken mints and the mweb
  /player request are anchored on this value. `invalidate()` marks the
  identity dead; the next re-pin prefers the fresh player-response value over
  the prewarmed one so attestation rotation actually lands on a new identity.
  Mechanism: `invalidate()` sets `invalidatedSinceLastPin`; the next
  `getSessionVisitorData` pin then prefers the fresh player-response
  visitorData over the prewarmed value (`SessionIdentityManager` +
  `YoutubeJavaScriptPlayerManager`). Never log the value.
- **UMP request headers** mirror PipePipe `buildRequestHeaders`
  (`YoutubeSabrSession.buildSabrHeaders`): one constant shape for every
  profile — `Content-Type: application/x-protobuf` + `Accept:
  application/vnd.yt-ump` + `Accept-Encoding: identity` + MWEB UA. **No**
  `Origin`/`Referer`/`Accept-Language`/`X-Goog-Visitor-Id`, and **no**
  `Cookie` or `Authorization` on UMP POSTs (login is bound through the
  /player request, never on the UMP rail).
- **Request URL params**: `alr=yes` and `cpn` are append-if-missing (an
  existing value in the serverAbr URL wins), `rn` is replace-or-append and
  **0-based** (`rn = String(requestNumber)`, so `rn=0` for the first POST).
- **Media integrity** (PipePipe `getIntegrityIssues` /
  `MAX_INCOMPLETE_MEDIA_RESPONSES=3`): every decoded UMP response is checked
  (duplicate-media-header / missing-media / length-mismatch vs
  `contentLength` / missing-media-end / media-without-header /
  media-end-without-header). A response with recoverable issues is **never
  ingested or cached** — the pump re-POSTs up to 3 times, then throws;
  non-recoverable issues throw immediately. This also keeps bare media
  headers of a bad response from advancing the advertised buffered range.
- **Protection state machine** (policy layer, PipePipe origin/main): responses
  are decided by `BuiltinSabrSessionPolicy` → action chains, executed by
  `YoutubeSabrSession`. No-media + status>=3 (attestation required) fails
  immediately (`kind='attestation_required'`). status==2 (pending) rotates
  first **with or without media** (PipePipe 60462a13 — a pending response can
  carry the demanded segment): `ROTATE_IDENTITY` (budget 3: invalidate
  identity → re-probe via `reprobeSabrInfo` → visitorData must change → epoch
  reset; local progress (FormatProgress + segment cache) lives in
  `YoutubeSabrStreamState` outside the epoch, and `executeRotateIdentity`
  only calls `epoch.resetServerState()` (cookie/contexts/poToken cleared),
  so progress survives untouched and the fresh epoch still advertises the
  cached range); with media a successful
  rotation retries the fetch loop and the preserved segmentCache delivers.
  No-media pending falls through `APPLY_PO_TOKEN` (force-refresh budget 2,
  resets when media arrives) → `RELOAD_PLAYER` (only once the refresh budget
  is spent) → FAIL. The pending counter increments only on no-media pending
  responses; three consecutive fail regardless. All budgets live in
  `policy/SabrSessionPolicy.ets` (`SABR_MAX_*`).
- **Token acceptance past ~1min** (PipePipe 5.3.0, issue #2820 / BgUtils
  PR#44): YouTube binds the initial BotGuard attestation challenge to the home
  page session's `EVENT_ID` and embeds it in the page HTML (`window.ytAtN`).
  The bootstrap MUST be parsed from `https://www.youtube.com` (home fetch with
  login cookies or anonymous `PREF=hl=en&gl=US`): `ytcfg.set` calls yield
  `EVENT_ID`, `VISITOR_DATA`/`EOM_VISITOR_DATA`, `DATASYNC_ID`, WEB
  clientVersion and the `html5_generate_content_po_token` /
  `html5_generate_session_po_token` experiment flags that select CONTENT /
  SESSION binding. Out-of-band `/att/get` challenges mint tokens the SABR
  server rejects at the ~1min protection boundary (status 2 → 3). The
  BotGuard JS must set `window.yt.config_.EVENT_ID` before running the VM and
  call `vm.a(...)` with the 9-argument signature (`program`, callback, `true`,
  interaction element, no-op, `[[], []]`, `undefined`, `false`,
  `loggerFunctions[5]` — see
  `entry/src/main/resources/rawfile/sabr_po_token.js`); a stale signature
  produces tokens the server rejects mid-playback. A forced mint must discard
  the old bootstrap/minter (`invalidate()`) before rebuilding.
- **Backoff is session-owned**: the UMP server backoff applies to EVERY
  response — media-carrying ones included (PipePipe `updateBackoff`) — and a
  server backoff above 30s is fatal. The deadline (epoch `backoffUntilMs`) is
  honored before every POST and is **not** cleared by seek, hole/policy
  recovery, or local stall resets; it clears when the server stops demanding
  it, or an identity rotation starts a new epoch. An empty response without a
  PoToken mints one immediately instead of waiting out the backoff
  empty-handed.
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
  `SessionPoTokenHook.getPlayerPoToken(..., videoId)`, capped call-side by
  `PLAYER_PO_TOKEN_TIMEOUT_MS` in `ConfiguredPlayerClient`.
- **Context updates**: `SABR_CONTEXT_UPDATE` (57) / `SABR_CONTEXT_SENDING_POLICY`
  (59) parts are absorbed into the epoch and echoed back via streamerContext
  field 5 (active contexts). Sending-policy fields follow PipePipe
  `ingestContextSendingPolicy`: field 1 = activate, field 2 = deactivate,
  field 3 = dispose (drop from active set and stored contexts); values may be
  single or packed varints. `getUnsentSabrContextTypes` is an MVP stub that
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
  Client-Name / Client-Version only) and, when the BotGuard runtime is
  already warm,
  `serviceIntegrityDimensions.poToken` — sourced through
  `SessionIdentityManager.setPlayerPoTokenHook` (entry provider, 5s cap; the
  binding follows the home page experiment flags: content binding mints per
  videoId, session binding reuses the pre-minted session token; when
  the BotGuard runtime is cold it attempts ONE bounded cold mint under the
  same 5s cap instead of skipping — an un-potted android_vr response 403s on
  googlevideo — and falls back to skipping on timeout). tv_downgraded requests
  stay entirely token-free (PipePipe 7673caed). The UMP streamerContext
  carries the separate per-video pot (content binding = `videoId`, ~91B).
  Identity invalidation clears all three caches (UMP, dash, player) and
  invalidates the generator's bootstrap so the next mint re-fetches the home
  page.

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
- Auth attachment is **rail-aware** (PipePipe `addLoggedInHeaders`):
  when a cookie credential exists, Cookie/SAPISIDHASH attaches to any client
  (TVHTML5/`tv_downgraded` included); OAuth Bearer is only the TV fallback
  for cookie-less OAuth-only sessions. The two rails never mix on the same
  request — never stuff Bearer into Cookie fields or Cookie into Bearer
  headers.
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
  them, `tv_downgraded` included);
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
- `setAuthStateChangeListener` — single-slot static hook fired after any
  credential-state change is persisted (`signOut` / `saveToken` /
  `saveCookieCredential` / OAuth `invalid_grant` clear / server-cleared
  SID-family cookies). Entry wires it to `AuthStateHelper.refresh()` right
  after `init`, so internal invalidation paths also refresh `authStatus`,
  run credential-fingerprint detection, and reset visitorData/PoToken caches.
- Prefer `getWebAuthorizationHeader` / `getTvAuthorizationHeader` at call sites.
- Credential-state changes (login/logout/rail switch) must reset the pinned
  session identity + PoToken caches (PipePipe LocalDomPoTokenProvider
  credential-bound isolation): entry `AuthStateHelper.refresh()` does this via
  a credential-rail fingerprint → `resetSessionVisitorData()` +
  `SabrWebViewPoTokenProvider.resetForAuthChange()`.
- `SmartTubeAuthProbe` — OAuth **device-code** sign-in (entry `DeviceQrLoginPage`).
- Cookie WebView login is entry-owned (`WebViewLoginPage`); this module stores credentials.
- **Expiry detection / repair**:
  - `AuthExpiredError` + `isAuthRejectionResponse` (401, or Innertube error
    `code 16` / `status UNAUTHENTICATED`): thrown by `YoutubeApi` browse
    POSTs only when auth was attached (`withAuth`); anonymous responses keep
    returning the error body as before.
  - `mergeAccountSetCookies` merges account-cookie rotations from
    youtube.com `Set-Cookie` back into the stored `CookieAuthCredential`
    (registered as the `HttpDownloader` Set-Cookie observer at `init`);
    a server-cleared SID/SAPISID-family cookie marks the web rail rejected.
  - OAuth `invalid_grant` on refresh clears the persisted refresh token.
  - `noteAuthRejection(rail, reason)` / `consumeAuthRejectionNotice()` —
    one-shot in-memory notice consumed by entry to show the re-login
    banner. Never log cookie/token values.
- `DebugAuthConstants` holds OAuth client/device URLs used by the device flow;
  do not scatter new hard-coded OAuth secrets elsewhere.

## 7. Network
- `YouTubeHttpClient` — wraps `@ohos.net.http` with cookie persistence via
  `CookieJar`. Sets the right `Origin` / `Referer` for YouTube.
- `HttpProxyOptions.setProvider` — only way this module sees app proxy config;
  entry `NetworkProxyConfig` injects it. Do not read system proxy ad hoc.
- `HttpDownloader` — used by entry `DownloadManager` to save streams.
  `setSetCookieObserver` (registered by `AuthSessionManager.init`) reports
  every response's `Set-Cookie` for account-credential repair. Buffered
  `request()` runs an API 22 `HttpInterceptorChain` per attempt: a
  REDIRECTION interceptor strips Cookie/Authorization when a redirect
  leaves the YouTube host family (auth-header leak guard; local
  `isYoutubeHostUrl` copy — importing the auth one would be circular),
  and a FINAL_RESPONSE interceptor fires the Set-Cookie observer.
  Interceptors do NOT apply to `requestInStream`, so
  `postBinary`/`postBinaryStreamOnce` keep the manual observer call.
- `Socks5Bridge` — loopback HTTP CONNECT bridge → SOCKS5. As of API 26 the
  netstack paths (`HttpDownloader.applyProxyToOptions`, incl. the PipePipe
  decoder calls) no longer use it: they set
  `HttpRequestOptions.usingSocks5Proxy` with the real upstream proxy
  (`dnsStrategy: connection.Socks5DnsStrategy.PROXY_MODE` so DNS resolves
  proxy-side, loopback exclusionList) instead of pointing `usingProxy` at the
  bridge. The bridge still must run for its remaining consumers — ArkWeb
  `ProxyController`, RCP `createTunnel`, and MPV's `http_proxy` env — entry
  starts/stops it independently. Self-heals: a server `error` event schedules bounded
  re-listens (1s/2s/4s, generation-guarded); tunnel connects retry once
  except for SOCKS5 auth errors (2301207/2301209). `getPort()` reports a
  last-known-good port: it is NOT cleared during the self-heal re-listen
  window, so proxy consumers keep routing at the dead loopback port and fail
  fast (connect-refused) instead of silently going direct. When self-heal
  ultimately fails (re-listen failure or restart budget exhausted) the bridge
  blows its fuse (`blowFuse`): the port is STILL kept, the server socket is
  closed, pending heal timers are cancelled, and the single-slot
  `setFailureListener` hook fires (entry surfaces "proxy unavailable" /
  re-applies); `isFuseBlown()` exposes the state. Re-listens use `port: 0`
  (a fresh ephemeral port each time); after a successful self-heal
  re-listen whose port differs from the previous one, the single-slot
  `setPortChangeListener` hook fires so entry can re-point the app-level
  proxy / WebView override at the new port (mediaservice `RangeProxy` follows
  `getPort()` lazily on its own). Only a real `stop()` (user
  disabled/changed the proxy, or initial listen failed) clears the port to 0
  and resets the fuse; a new `start()` does the same via its internal stop.

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
- Commit `Crash_*.dmp`, `.cxx/`, `build/`, `.hvigor/` artifacts.
- Add top-level mutable state in `Index.ets`; export factories or
  `getInstance()` accessors instead.
- Put changelogs or commit-specific notes into this file.
