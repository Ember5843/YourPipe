# entry/AGENTS.md

> UI shell for YourPipe. Stage-model `entry` module, loaded by
> `EntryAbility`. Wires up stores, log sinks, engine config providers,
> auth, network proxy, and startup prewarm. Owns all user-facing pages,
> presentation mode, cross-device handoff, and the SABR PoToken WebView
> mint bridge. Durable architecture only — no changelogs.

## 1. Layout
```
entry/src/main/
  ets/
    entryability/EntryAbility.ets          — UIAbility (lifecycle, init, injection, prewarm)
    entrybackupability/EntryBackupAbility  — backup extension ability
    product/Index.ets                      — root page; bottom tabs + NavPathStack + Options sheet
                                             (home tab UI + feed state machine live in
                                             features/home/HomeTabContent.ets, options sheet host in
                                             features/options/OptionsSheetHost.ets)
    common/                                — shared stores, components, models, utils
    features/<feature>/                    — per-feature pages + services (§2)
  module.json5                             — abilities, permissions, deviceTypes
  resources/                               — i18n strings, media assets
```

Bottom tabs in `product/Index.ets`: **Home | Subscriptions | Favorites | Local**.
Search is a `NavDestination` (not a tab). Options is a panel/sheet (not a tab):
one `bindSheet` (LARGE, system drag bar, close menu on the root title bar)
hosting `OptionsSheetHost` — a single inner `HdsNavigation(optionsNavStack)`;
all options pages —
including About sub-pages (about_open_source / about_ai_models /
about_changelog) — are
destinations on that one stack (no third nav stack, no per-page safe-area
padding: `buildSheetTitleBar` handles in-sheet insets). The inner
`HdsNavigation` sets `hideBackButton(true)` — HDS shows its own back key in
MINI title mode by default (even on the empty-stack root); sub-page back
comes from `OptionsNavScaffold`'s custom `backIcon`.

## 2. Features (`features/<feature>/`)
| Feature | Contents |
|---|---|
| `home` | Home feed, channel/playlist/search services + parsers (incl. TV lockup view-model parsing), recommend swiper / list UI; `HomeTabContent` — 首页 tab 内容宿主（feed 加载状态机 + 推荐位 banner + 三个 @LocalBuilder 卡片），Index 经 `HomeTabController` 触发 reset |
| `search` | `SearchPage` (NavDestination) |
| `player` | Player / detail pages, play queue, `YouTubePlayService`, environment, continuation, PiP, **SABR PoToken mint** (`SabrWebViewPoTokenProvider`, `SabrPoTokenWebRuntime`, `SabrLocalDomPoTokenGenerator`), stream-info sheet live stats (`StatsBarGraph` + 500ms `controller.getPlaybackStats()` polling, only while the sheet is open), **布局状态机**（PlayerPage 方法派生，输入 `@Env(WINDOW_SIZE/BREAK_POINT)` + 视频比例：竖向窗口 → 上视频+下信息；真横屏且容得下 → 左视频+右信息栏 `clamp(W/3, 320, 480)`；非竖向但容不下 → 挤压强制铺满，信息经播放器菜单"视频信息"以 CENTER sheet 打开；内容组件 `components/PlayerInfoPanel.ets` 三处复用；信息 sheet 设 `showClose: false`（自带关闭按钮会与面板 Tab 栏重叠，关闭走拖拽条/点空白）。强制全屏态（分屏 / 挤压铺满，即 `isFullLandscapeScreen() && !isManualFullscreen`）经 `VideoPlayer.showFullscreenButton=false` 隐藏右下角全屏切换按钮——该状态下按钮无意义，仅用户手动全屏保留退出入口。注意：ArkUI V1 @Component 不支持 ES get 访问器，布局派生必须用普通方法）, **AI subtitle**: live path = P0 tlang 服务端自动翻译轨（`withAutoTranslatedTrack` 追加虚拟轨；注意 YouTube 按出口 IP 做 429 风控，出不出字幕取决于网络）；**[DISABLED]** P1 系统 AICaptionComponent、P2 gtx/LLM 整轨翻译（`translate/`）、P3 端侧 ASR（`asr/` + `workers/AsrStreamingWorker.ets`：`AsrLiveCaptionService` 真流式识别，MPV PCM tap + sherpa OnlineRecognizer 流式 zipformer 中英双语 int8；菜单项、Options 入口/设置页、PlayerSession/AVPlayer 接线、build-profile worker 注册均已注释，`AsrModelManager.clearAll`/`clearCaches` 的清数据接线保留以清理已下载模型）——入口/设置项均已注释，代码保留，重新启用 = 取消对应 [DISABLED] 注释块 |
| `playlist` | Playlist list + detail |
| `subscription` | Subscription manage + feed service (bottom tab) |
| `favorites` | `FavoritesPage` |
| `local` | Local library + downloads |
| `options` | `OptionsSheetHost` — options sheet 宿主（inner HdsNavigation + 全部子页 destination + `OptionsNavScaffold`），Index 经单对象 params 传回调。Main / appearance / playback (incl. per-state 播放端点: guest `visionos|mweb`, signed-in `tv_downgraded|mweb`, persisted in `PlaybackConfig`, applied via `AuthStateHelper.applyPlayerClientConfig` + prefetch-cache clear) / language-region / **network** / data-account / recovery / ai-subtitle (`OptionsAiTranslatePage` — 端侧识别模型下载/删除管理，标题 `yt_option_ai_subtitle`，OptionsMainPage 入口行已开放；P2 翻译引擎 gtx/LLM 配置区 **[DISABLED]** 注释保留在页内) / about-update (GitHub Releases check + AppGallery test link; the update check — `UpdateChecker` + `APPGALLERY_TEST_URL` — is inline in `OptionsMainPage`, while the About UI is `common/components/AboutPage.ets`, hosted as the `about_page` destination on `optionsNavStack` via `onAboutClick` — there is no `OptionsAboutPage`) |
| `help` | `HelpGuidePage` — 6-page onboarding/help swiper (welcome + sign-in, account data, network proxy, quality/cache, downloads). Two entries: first-launch full-screen overlay on `Index` (an `if`-mounted layer in the root Stack, shown while `PreferencesStore` key `cfg_help_seen` != `'true'` with a 500 ms delay; bindSheet/bindContentCover on Navigation-hosted nodes do NOT present at app-start timing — do not revert to them) and Options main page "帮助" item (`help_page` destination in the options sheet). `resetAllConfigs` resets the flag; `clearAllAppData` clears it via `PreferencesStore.clearAll()`. Illustrations are `resources/base/media/guide_*.png` (welcome page uses `app_icon.png`). |
| `user` | User / channel info; Library saved playlists (WEB classic renderers + TV lockup view models) |
| `auth` | WebView cookie login (`WebViewLoginPage`) + device/QR OAuth (`DeviceQrLoginPage`) |

## 3. Common stores / singletons (`common/`)
Persistent state and shared singletons:
- `PreferencesStore.init(context)` — key/value store; init in `EntryAbility.onCreate`.
- `AppState`, `UIConfig`, `PlaybackConfig` — `AppStorage`-backed config models
  (playback quality/cache/GPU, background video-off delay, system AI caption
  (`systemAiCaption` + `systemAiCaptionSource`), etc.).
- `LlmTranslateConfig` — AI 字幕翻译引擎配置（gtx/llm、baseUrl/model/apiKey、双语），
  `PreferencesStore` 持久化（`cfg_ai_translate_*`），`resetAllConfigs` 复位（含 key）；
  翻译缓存 `cacheDir/ai_subtitle/` 与 ASR 模型/缓存（`filesDir/asr_models/`、
  `cacheDir/asr_caption/`）接入 `clearAllAppData`。
- `NetworkProxyConfig` — HTTP/SOCKS proxy prefs; applies system
  `setAppHttpProxy` and injects `HttpProxyOptions.setProvider` into
  `youtube_core`. `applySystemAndProviders` is async: SOCKS5 first starts
  the loopback CONNECT bridge, then points both the app-level proxy and
  the ArkWeb `ProxyController` override at it; `awaitReady()` lets the
  first network work (home load in `Index.aboutToAppear`, the Options
  proxy test, startup prewarm chains) wait for the bridge instead of
  leaking direct. Applies are serialized (promise-chain mutex) so
  concurrent applies never interleave and the last requested config
  lands last. During a
  bridge self-heal re-listen (post-startup), the snapshot keeps the
  bridge's last-known-good port so consumers fail fast on the dead port
  rather than leaking direct there either; a successful self-heal
  re-listen lands on a NEW ephemeral port, and the bridge's
  `setPortChangeListener` hook (registered once by `NetworkProxyConfig`)
  re-points only the app-level proxy + WebView override at the new port
  (never a full re-apply), then fires `setBridgeRepointListener`
  (registered by `PlayerSession`) to re-apply MPV's process-level
  `http_proxy` env for the current source — the env is written only at
  `load()` and would otherwise keep hitting the dead port
  (`AvPlayerController.refreshNetworkProxy`). On fuse-blown the `setFailureListener` hook
  logs an ERROR and toasts `yt_proxy_bridge_unavailable`; no
  auto-restart — a user re-save re-applies and resets the fuse. The WebView
  override has **no** direct-fallback rules — a dead proxy fails visibly.
- `NetworkHandoverService` — network-handover adaptation. Single
  subscription site (`connection` default-network `netAvailable` /
  `netUnavailable` events; the SDK kit set has no NetworkBoostKit
  `netHandover`), started/stopped by `EntryAbility`. On a default-network
  switch or loss (debounced 2s, netId-tracked) it aborts stale in-flight
  connections so playback fails fast instead of stalling on timeouts:
  `LocalMediaProxy.abortAllUpstreamFetches` (local-proxy upstream fetches)
  and `sabrSessionStore.abortAllInFlightPosts` (SABR UMP in-flight POST
  only — sessions stay open, their own retry/backoff paths recover).
- `PlayerSession` — singleton player state for the active `AvPlayerController`.
- `PlayerPresentation` — foreground / background / share / cast / PiP presentation
  mode; drives when video may be disabled for background audio-only.
- `WatchHistoryStore`, `SearchHistoryStore`, `DownloadManager`, `LocalStore`,
  `PlaylistModel`, `SubscriptionModel`, `SubscriptionFeedStore` — feature stores.
- `AppLogStore` — in-memory + persistent log buffer (sink for all modules).
- `ThemeManager`, `ThemeColorUtil`, `ColorModeManager`, `LanguageManager`,
  `SearchLocaleManager` — UI prefs.
- `DataBackupManager`, `AuthStateHelper`, `FeedServiceProvider`, `ActionHub`,
  `LocaleBundle`, `Constants`, `AnimationUtil`, `AppLog`, `VibratorUtil`,
  `ShareUtil`（系统分享收口） — misc.

Reusable components: `HdsTitleBar`, video cards / grids / thumbs, error / about /
log / tab error panels, option rows, backup + language pickers, placeholders.
`MediaVideoFeed` is the shared video-feed skeleton (loading / error / empty /
grid / wide-strip / single-list branches over Grid|List + LazyForEach); pages
feed it a `FeedDataSource` (`common/model/FeedDataSource.ets`, prefix-diff
`setData` for paged appends) plus stable Scroller/callback members, and pass
volatile display state as a single `MediaVideoFeedParams` object-literal
`@Prop`. `FeedDataSource` implements `IDataSourcePrefetching`: `MediaVideoFeed`
binds it to a `BasicPrefetcher` and reports the visible range from
`onScrollIndex`; `prefetch(index)` warms the item's first-choice thumbnail via
`ThumbPrefetcher` (`common/model/ThumbPrefetcher.ets` → `cacheDownload`,
LAZY strategy, bounded in-flight, `cancel(index)` aborts), so cards hit the
system image cache when scrolled into view. Grid column counts are centralized in `ListLayoutUtils`
(`getVideoGridColumnCount` / `getWideListColumnCount`). Builders passed into
`MediaVideoFeed`'s `@BuilderParam`s must be declared `@LocalBuilder` (not
`@Builder`, and never `.bind(this)`) — a plain `@Builder` passed by reference
runs with `this` bound to the call-site component, so page builders that touch
page state crash with "undefined is not callable".
Its Grid branch must leave normal cards without `columnStart`/`columnEnd`
(auto-flow placement); explicitly positioning every item pins them all to
column 0 and collapses the grid to a single column — only full-width items
(header/footer/span>1 cards) set `columnStart(0).columnEnd(columns-1)`.
Feed-item entrance animation is **one-shot gated** (`armEntryAnim` /
`entryTransitionOf` + `customAnimationUtil.isScaleTranEnter`): only the first
screen of items after a (re)load **while the list is scrolled to the top** may
play the insert-only scale/fade-in; `entryAnimDone` persists across reloads so
a key that has played never replays. Mid-scroll full reloads (background
subscription merges, auth-fallback refetches) do not arm at all, and
`FeedDataSource.setData` with an unchanged key sequence (same length, same
order — including redundant re-syncs) skips the full reload and only fires
per-item `onDataChange` for reference-changed items, so recycled/recreated and
paginated items always get `.transition(null)` and render instantly. Never hand
a plain always-on `.transition(isScaleTran(...))` to LazyForEach feed items or
to static header/footer items inside a lazy Grid/List — recycling or branch
rebuilds replay it, so cards scrolled past the top/bottom edge vanish in place
(scale-to-0 ghost) or pop in late instead of scrolling off; use the insert-only
`isScaleTranEnter` where an entrance is genuinely wanted. Symmetric
`isScaleTran` remains acceptable only on eager `ForEach` lists (favorites /
local / downloads / comments), which never recycle and use the delete half as
user-action feedback.
Root-tab pages let content scroll **under** the root title bar (translucent
material): reserve `safeAreaTop + TITLE_BAR_HEIGHT` as padding on a wrapper
(Refresh/Column), keep the inner List/Grid `clip(false)`, and expose the
page's primary `Scroller` via a coordinator static
(`SubscriptionScrollCoordinator` / `FavoritesScrollCoordinator` /
`LocalScrollCoordinator`) — `Index` binds all of them plus the home feed
scrollers to the root `HdsNavigation.bindToScrollable` so the scroll-driven
blur engages on every tab. `LocalPage` additionally wraps its nested Tabs in
an outer `Scroll` (UserPage pattern: top spacer + Tabs, inner lists
`nestedScroll` PARENT_FIRST), so the 观看历史/下载视频 tab bar follows the
content upward instead of staying pinned.
`SubTabBar` (`SubTabBarItem`) is the shared in-page sub-tab builder (48vp bar,
16fp, 36×2 theme-color indicator) used by Local / Player / User pages. It takes
a single `SubTabBarItemParams` object-literal param (by-reference refresh) —
global `@Builder`s with multiple by-value params never re-render on caller
state changes; keep new shared builders on the same single-param pattern.
Shared geometry tokens live in `MediaCardTokens` (`MEDIA_CARD_*`,
`SECTION_CARD_RADIUS`, `TITLE_BAR_HEIGHT`); floating-title-bar pages reserve
`safeAreaTop + TITLE_BAR_HEIGHT` at content top and set
`avoidLayoutSafeArea: true` on the title bar.

## 4. AppStorage keys
- `context`, `uiContext`, `isAppBackground`, `currentBreakpoint`, `playerLoading`
- `uiConfig` (`UIConfig`), `playbackConfig` (`PlaybackConfig`)
- `networkProxyConfig` (`NetworkProxyConfig`) — set in `AppState.init` / Options Network
- `autoPlayQueue` (boolean) — session-scoped queue auto-play switch; seeded
  from `playbackConfig.autoPlayNext` on every launch and on settings
  save/reset/restore.
- `PlaybackContinuationService.APP_STORAGE_PENDING_KEY` — JSON-serialized
  continuation payload awaiting consumer.

## 5. Cross-module wiring (in `EntryAbility.onCreate`)
- `PreferencesStore.init(context)` and `AppState.init()` (loads proxy + applies providers).
- `PlaybackPreferences.setProvider(...)` — UI/playback prefs → `mediaservice`.
- `ContextProvider.setProvider(...)` — lazy `UIAbilityContext` getter →
  `mediaservice` (AVSession init, background continuous task).
- `AvPlayerController.setEngineConfigProvider(...)` — MPV engine knobs → `mediaservice`.
- `AppLogStore.init(enabled, context.filesDir)`.
- `AuthSessionManager.init(context)` (youtube_core) +
  `AuthSessionManager.setAuthStateChangeListener(() => AuthStateHelper.refresh())`
  + `AuthStateHelper.refresh()` — the listener hook makes internal
  credential-loss paths (OAuth `invalid_grant`, server-cleared SID-family
  cookies) trigger the same auth-state refresh as explicit login/logout.
- `AuthStateHelper.reconcilePlaybackClient()` — 登录态/鉴权开关变化后的唯一
  入口（内部调用 `YoutubePlayerClientConfig.resetToAuthDefault`，落到
  per-state configured 值）。Configured defaults: `mweb` (SABR) signed-in,
  `visionos` guest (pot-free via the GAPIS endpoint, direct adaptiveFormats
  URLs); **tv_downgraded** (token-free direct URLs) stays selectable in
  Options → 播放端点 for the signed-in state. Endpoint changes go through
  `AuthStateHelper.applyPlayerClientConfig` (config + identity/pot reset);
  `EntryAbility.onCreate` pushes the persisted values via
  `YoutubePlayerClientConfig.setConfiguredClients` before reconcile.
- SABR wiring in `YouTubePlayService.initialize()`:
  `sabrSessionStore.setPoTokenProvider(...)` (UMP per-video pot),
  `sabrSessionStore.setInfoReloader(...)` (mid-playback re-probe, serialized
  through the extraction chain), and
  `SessionIdentityManager.setPlayerPoTokenHook(...)` (mweb/web_safari player
  requests carry `context.client.visitorData` +
  `serviceIntegrityDimensions.poToken`, fast-skipped while BotGuard is cold).
- `EnhancedLogger.setSink(...)` (mediaservice) → `AppLogStore.push`.
- `YTCoreLogger.setSink(...)` (youtube_core) → `AppLogStore.push`.
- Startup prewarm chain (`startPlaybackPrewarm` + cipher/PoToken). Every
  network-touching step is gated on `NetworkProxyConfig.awaitReady()`
  (proxy apply is kicked off earlier in `AppState.init()`), so nothing
  goes direct inside the async proxy-apply window; local-only steps
  (MPV engine creation, loopback server warmup) run immediately:
  1. `YoutubeJavaScriptPlayerManager.startAppPrewarm` (after
     `awaitReady()`) — cold-start disk fast
     path (persisted STS `signatureTimestamp` + WEB `clientVersion` beside
     the cipher JS cache); the prewarmed visitorData pre-initializes the
     BotGuard WebView runtime (`SabrWebViewPoTokenProvider.warmRuntime`,
     queued until the WebView attaches) so the first real mint skips the
     home page bootstrap + interpreter dance mid-playback
  2. `PlayerSession.prewarmPlaybackEngine()` (MPV; local, not gated)
  3. `LocalMediaProxy.warmup()` (local loopback, not gated) +
     `LocalMediaProxy.setStartupUrlGate(...)`
     — demand-side SIDX/segment fetches wait for the pending PoToken
     injection without blocking play() submission
  4. `YouTubePlayService.initialize()` / `prewarmClientVersion()` (after
     `awaitReady()`)
  5. Queue-next prefetch: once playback is stable, `YouTubePlayService.prefetch`
     extracts the next queue item's streams on idle bandwidth (TTL'd result
     cache, consumed via `takePrefetched`). Extraction is serialized through
     a mutex — the extractor is a stateful singleton; prefetch must never
     run concurrently with real playback extraction.
- `LanguageManager.applyPersistedLanguage()`, `ColorModeManager.applyPersistedMode(context)`.
- `NetworkHandoverService.start()` / `stop()` — network-handover listener
  lifecycle (see §3).

## 6. SABR PoToken ownership (entry)
- Product VOD is direct-link DASH; the mweb SABR/UMP path is an opt-in/debug
  selection, and protected SABR responses need a PoToken.
- Entry owns the **WebView mint** stack under `features/player/`:
  - `SabrWebViewPoTokenProvider` — provider facade, wired into
    `sabrSessionStore.setPoTokenProvider` via `YouTubePlayService`; also
    implements `SessionPoTokenHook` (player-request pot) and
    `invalidatePoTokenIdentity` (attestation rotation: clears every
    visitor-bound cache + resets the breaker + invalidates the generator
    bootstrap, then youtube_core re-pins a fresh visitorData and the next
    mint re-bootstraps from the home page)
  - `SabrPoTokenWebRuntime` — hidden WebView BotGuard runtime (desktop UA
    pinned via `setCustomUserAgent`). Its `onControllerAttached` (the app's
    first WebView attach) also fires `WebviewController.prepareForPageLoad`
    socket pre-connects for `www.youtube.com` / `accounts.google.com`,
    gated on `NetworkProxyConfig.awaitReady()` so the pre-connect never
    goes direct while the proxy override is still being applied.
  - `SabrLocalDomPoTokenGenerator` — local-DOM mint path (home page
    attestation bootstrap + EVENT_ID-bound BotGuard)
- Do not move PoToken WebView policy into `mediaservice` or `youtube_core`;
  those modules only consume the `SabrPoTokenProvider` interface.
- Mint is **bounded**: a timeout + circuit breaker so a wedged ArkWeb can
  never hang SABR playback. An empty SABR response ("come back with a
  PoToken") triggers an immediate mint instead of waiting out the backoff,
  and mediaservice gates demand-side SIDX on the pending injection via the
  startup URL gate.
- Only the player-token cache is **visitor-bound** (it stores the visitorData
  + videoId it was minted against and re-mints on mismatch); the per-video and
  DASH caches key on `videoId` only — a visitor change takes effect through
  the generator's bootstrap invalidation plus the invalidate-time cache clear.
  Player/per-video pot cache TTL is 6h (inline literal).
- **Binding follows the home page experiment flags** (PipePipe 5.3.0):
  content binding mints per identifier (videoId for /player + UMP pots),
  session binding mints once against the DataSync ID (signed-in) or the
  bootstrap visitorData (anonymous) and every mint returns that session token.
  DASH `pot=` has its own short-TTL cache. All are cleared together on
  identity invalidation.
- **Attestation bootstrap** (PipePipe 5.3.0 `YoutubePageAttestationBootstrap`,
  issue #2820): the BotGuard challenge is parsed from the
  `https://www.youtube.com` home page (`ytcfg.set` + `window.ytAtN`) —
  `/att/get` is no longer used. The home fetch sends `Accept-Language: en-US`,
  the login cookie when signed in (else `PREF=hl=en&gl=US`) and the desktop
  `SABR_POTOKEN_USER_AGENT` (also pinned on the WebView via
  `setCustomUserAgent`); GenerateIT keeps `x-goog-api-key` +
  `x-user-agent: grpc-web-javascript/0.1`. The WebView helper injects
  `window.yt.config_.EVENT_ID` before BotGuard and calls `vm.a(...)` with the
  9-argument signature (program, callback, true, interaction element, no-op,
  `[[], []]`, undefined, false, the 5-element `loggerFunctions` array as the
  9th argument). After a successful
  bootstrap the generator pins the bootstrap visitorData into
  `SessionIdentityManager`.
- `warmRuntime(visitorData): void` is fire-and-forget BotGuard pre-init
  (queued until the WebView attaches, re-triggered by `setMinter`);
  `invalidatePoTokenIdentity(...)` clears the caches and resets warm/breaker
  state without awaiting BotGuard. `getPlayerPoToken` keeps the not-warm
  fast-skip so TTFF never waits on BotGuard.

## 7. i18n
- 14 locales shipped: `base`, `ar_SA`, `de_DE`, `en_US`, `es_ES`, `fr_FR`,
  `it_IT`, `ja_JP`, `ko_KR`, `pt_BR`, `ru_RU`, `zh_CN`, `zh_HK`, `zh_TW`.
- All new user-visible strings must be added to every locale.
- Files: `entry/src/main/resources/<locale>/element/string.json`.

## 8. Conventions
- **State**: cross-component state lifted to `AppStorage` keys or singletons
  in `common/`. Components hold only local `@State` / `@Prop`. Cross-component
  observation uses `@Observed` + `@Track` on the model + `@ObjectLink` in the
  child (ArkTS V1). The project does **not** use V2 decorators (`@ComponentV2`
  / `@Local` / `@Trace`) — do not introduce them.
- **Logger**: use `AppLog.getInstance(tag)` for entry-level logging; modules
  rely on their own `setSink` hooks. New entry features must log lifecycle,
  request/state boundaries, retries/fallbacks, timings, and caught failures;
  never use `console.*` or direct `hilog` outside `AppLogStore` internals.
- **Config reads**: `entry` is the only place that calls `AppStorage.get`.
  `mediaservice` / `youtube_core` receive values through `setProvider`
  callbacks (playback, engine, HTTP proxy).
- **Permissions** (`module.json5`): `INTERNET`, `VIBRATE`, `GET_NETWORK_INFO`,
  `KEEP_BACKGROUND_RUNNING`.
- **Background playback**: continuous task lifecycle is owned by
  `mediaservice/PlayerStateMachine` (+ safety-net start from
  `EntryAbility.onBackground`, registered only while the player is in an
  active state — PLAYING/PAUSED/BUFFERING/READY/LOADING, the same set as
  mediaservice's `BackgroundTaskStateListener`). Presentation (when to drop
  video tracks) is owned by `PlayerPresentation` in entry, not by native MPV
  defaults alone.
- **Audio focus / interruptions**: handled at the application layer
  (player UI + AV session path), not as a native-only policy inside
  `libmpv_napi`.
- **Cross-device handoff**: `PlaybackContinuationService` is the only owner
  of want-param marshalling. Called by `EntryAbility.onContinue` /
  `handleContinuationWant`.
- **Auth-aware surfaces**: home / account / feed code must go through
  `AuthStateHelper` + youtube_core dual-rail session APIs — do not scrape
  cookies or Bearer tokens ad hoc. Credential modes and
  `useAuthForUserData` / `useAuthForPlayback` live in Options Data & Account.
  A failed signed-in home rail (`AuthExpiredError` or otherwise) falls back
  to the guest kiosk in `HomeFeedService` — the feed is never dead-ended;
  an auth rejection additionally raises the
  `yt_home_auth_expired_notice` banner via `homeModeNoticeMessage` in
  `features/home/HomeTabContent.ets`.

## 9. Player navigation and UI regression checks
- Before adding a navigation path from `PlayerPage`, trace the comparable
  existing path end to end: UI component -> generic media card -> `ActionHub`
  -> `Index`. Opening a secondary page (channel, playlist, tag search) must
  only push a destination and must not reset `PlayerSession`, release MPV, or
  clear the queue. Playback is allowed to continue while `PlayerPage` is
  hidden.
- A video selected from any secondary page must keep using
  `ActionHub.openVideo` and `Index.openVideoDetail`. That method owns the
  external-video transition: save old history, `forceReset` the old source,
  invalidate stale preparation, prepare the new item, and
  `moveToTop('PlayerPage')`. Do not duplicate this sequence or push a second
  player/controller path in a feature page.
- Destination launch data belongs in the `NavPathStack` route parameter and
  the destination component's props. Do not introduce shared mutable state
  for per-page inputs such as an initial search query; multiple instances of
  the same destination must remain independent.
- ArkUI `Search` can emit `onFocus` during destination creation and `onChange`
  after assigning its bound value in code. For an auto-running initial query,
  suppress the programmatic change, prevent initial focus until the request
  settles, hide the keyboard, and then restore normal editing. Verify result
  mode after the asynchronous callbacks, not only immediately after setting
  state.
- UI regression workflow: build and install with `devecocli build` and
  `devecocli run`; use `devecocli log` to verify player/session transitions.
  When coordinate-level emulator interaction is required and devecocli has no
  equivalent, `hdc shell uitest uiInput`, `uitest dumpLayout`, and
  `snapshot_display` may be used only as diagnostic UI probes. Check all three
  layers: screenshot for layout, dumpLayout for focus/result state, and logs
  for session/page-stack behavior. Keep captures outside tracked source and
  remove them after verification.

## 10. Reference clients
- Reference clones (NewPipe, PipePipe, …) usually live in the parent
  directory `../` — always check the local clones first when comparing
  behavior, and ask the user for the path if one is missing (this machine
  currently has only `../PipePipe`). Relevant Android sources include
  `app/src/main/java/org/schabi/newpipe/fragments/detail/BaseDescriptionFragment.java`,
  `fragments/detail/DescriptionFragment.java`, and
  `fragments/list/search/SearchFragment.java` under each tree as applicable.
- Use these projects to establish product semantics, not as architecture to
  copy. Translate behavior into ArkUI route params, `ActionHub`, and the
  existing YourPipe player/session ownership model; do not port Android
  Fragment/back-stack or player-lifecycle code directly.
- When comparing a new interaction, first identify the closest existing
  YourPipe path (for example, player -> author -> new video), write down which
  layer owns navigation, session reset, queue creation, and player-page reuse,
  then make the new entry point converge on those same owners.

## 11. Do not
- Bypass the YouTube extractor (`youtube_core`) to fetch a stream directly.
- Add a new string to only one locale.
- Add a new module (HAR/HSP) without updating root `build-profile.json5`
  `modules[]` and the consumer's `oh-package.json5#dependencies`.
- Commit `Crash_*.dmp`, `.cxx/`, `oh_modules/`, `build/`, `.hvigor/`,
  `.deveco/plans/`, or signing material.
- Add top-level mutable state in a HAR module's `Index.ets` — use
  `getInstance()` or factories.
- Call `AppStorage.get` from `mediaservice` or `youtube_core` code paths.
- Put changelogs or commit-specific notes into this file.
