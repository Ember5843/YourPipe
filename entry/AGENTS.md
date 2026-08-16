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
    common/                                — shared stores, components, models, utils
    features/<feature>/                    — per-feature pages + services (§2)
  module.json5                             — abilities, permissions, deviceTypes
  resources/                               — i18n strings, media assets
```

Bottom tabs in `product/Index.ets`: **Home | Subscriptions | Favorites | Local**.
Search is a `NavDestination` (not a tab). Options is a panel/sheet (not a tab):
one `bindSheet` (LARGE, system drag bar, close menu on the root title bar)
hosting a single inner `HdsNavigation(optionsNavStack)`; all options pages —
including About sub-pages (open_source / ai_models / changelog) — are
destinations on that one stack (no third nav stack, no per-page safe-area
padding: `buildSheetTitleBar` handles in-sheet insets).

## 2. Features (`features/<feature>/`)
| Feature | Contents |
|---|---|
| `home` | Home feed, channel/playlist/search services + parsers (incl. TV lockup view-model parsing), recommend swiper / list UI |
| `search` | `SearchPage` (NavDestination) |
| `player` | Player / detail pages, play queue, `YouTubePlayService`, environment, continuation, PiP, **SABR PoToken mint** (`SabrWebViewPoTokenProvider`, `SabrPoTokenWebRuntime`, `SabrLocalDomPoTokenGenerator`) |
| `playlist` | Playlist list + detail |
| `subscription` | Subscription manage + feed service (bottom tab) |
| `favorites` | `FavoritesPage` |
| `local` | Local library + downloads |
| `options` | Main / appearance / playback / language-region / **network** / data-account / recovery / about-update (GitHub Releases check + AppGallery test link; about/update is inline in `OptionsMainPage` — there is no `OptionsAboutPage`; the About UI is `common/components/AboutPage.ets`) |
| `help` | `HelpGuidePage` — 6-page onboarding/help swiper (welcome + sign-in, account data, network proxy, quality/cache, downloads). Two entries: first-launch full-screen overlay on `Index` (an `if`-mounted layer in the root Stack, shown while `PreferencesStore` key `cfg_help_seen` != `'true'` with a 500 ms delay; bindSheet/bindContentCover on Navigation-hosted nodes do NOT present at app-start timing — do not revert to them) and Options main page "帮助" item (`help_page` destination in the options sheet). `resetAllConfigs` resets the flag; `clearAllAppData` clears it via `PreferencesStore.clearAll()`. Illustrations are `resources/base/media/guide_*.png` (welcome page uses `app_icon.png`). |
| `user` | User / channel info; Library saved playlists (WEB classic renderers + TV lockup view models) |
| `auth` | WebView cookie login (`WebViewLoginPage`) + device/QR OAuth (`DeviceQrLoginPage`) |

## 3. Common stores / singletons (`common/`)
Persistent state and shared singletons:
- `PreferencesStore.init(context)` — key/value store; init in `EntryAbility.onCreate`.
- `AppState`, `UIConfig`, `PlaybackConfig` — `AppStorage`-backed config models
  (playback quality/cache/GPU, background video-off delay, etc.).
- `NetworkProxyConfig` — HTTP/SOCKS proxy prefs; applies system
  `setAppHttpProxy` and injects `HttpProxyOptions.setProvider` into
  `youtube_core`.
- `PlayerSession` — singleton player state for the active `AvPlayerController`.
- `PlayerPresentation` — foreground / background / share / cast / PiP presentation
  mode; drives when video may be disabled for background audio-only.
- `WatchHistoryStore`, `SearchHistoryStore`, `DownloadManager`, `LocalStore`,
  `PlaylistModel`, `SubscriptionModel`, `SubscriptionFeedStore` — feature stores.
- `AppLogStore` — in-memory + persistent log buffer (sink for all modules).
- `ThemeManager`, `ThemeColorUtil`, `ColorModeManager`, `LanguageManager`,
  `SearchLocaleManager` — UI prefs.
- `DataBackupManager`, `AuthStateHelper`, `FeedServiceProvider`, `ActionHub`,
  `LocaleBundle`, `Constants`, `AnimationUtil`, `AppLog`, `VibratorUtil` — misc.

Reusable components: `HdsTitleBar`, video cards / grids / thumbs, error / about /
log / tab error panels, option rows, backup + language pickers, placeholders.
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
- `AvPlayerController.setEngineConfigProvider(...)` — MPV engine knobs → `mediaservice`.
- `AppLogStore.init(enabled, context.filesDir)`.
- `AuthSessionManager.init(context)` (youtube_core) + `AuthStateHelper.refresh()`.
- `YoutubePlayerClientConfig.resetToAuthDefault(...)` — product default is
  `tv_downgraded` when signed in, `android_vr` for guests (both resolve to
  direct adaptiveFormats URLs); **mweb** (SABR) is an opt-in/debug selection,
  not the default.
- SABR wiring in `YouTubePlayService.initialize()`:
  `sabrSessionStore.setPoTokenProvider(...)` (UMP per-video pot),
  `sabrSessionStore.setInfoReloader(...)` (mid-playback re-probe, serialized
  through the extraction chain), and
  `SessionIdentityManager.setPlayerPoTokenHook(...)` (mweb/web_safari player
  requests carry `context.client.visitorData` +
  `serviceIntegrityDimensions.poToken`, fast-skipped while BotGuard is cold).
- `EnhancedLogger.setSink(...)` (mediaservice) → `AppLogStore.push`.
- `YTCoreLogger.setSink(...)` (youtube_core) → `AppLogStore.push`.
- Startup prewarm chain (`startPlaybackPrewarm` + cipher/PoToken):
  1. `YoutubeJavaScriptPlayerManager.startAppPrewarm` — cold-start disk fast
     path (persisted STS `signatureTimestamp` + WEB `clientVersion` beside
     the cipher JS cache); the prewarmed visitorData pre-initializes the
     BotGuard WebView runtime (`SabrWebViewPoTokenProvider.warmRuntime`,
     queued until the WebView attaches) so the first real mint skips the
     att/get + interpreter dance mid-playback
  2. `PlayerSession.prewarmPlaybackEngine()` (MPV)
  3. `LocalMediaProxy.warmup()` + `LocalMediaProxy.setStartupUrlGate(...)`
     — demand-side SIDX/segment fetches wait for the pending PoToken
     injection without blocking play() submission
  4. `YouTubePlayService.initialize()` / `prewarmClientVersion()`
  5. Queue-next prefetch: once playback is stable, `YouTubePlayService.prefetch`
     extracts the next queue item's streams on idle bandwidth (TTL'd result
     cache, consumed via `takePrefetched`). Extraction is serialized through
     a mutex — the extractor is a stateful singleton; prefetch must never
     run concurrently with real playback extraction.
- `LanguageManager.applyPersistedLanguage()`, `ColorModeManager.applyPersistedMode(context)`.

## 6. SABR PoToken ownership (entry)
- Product VOD is direct-link DASH; the mweb SABR/UMP path is an opt-in/debug
  selection, and protected SABR responses need a PoToken.
- Entry owns the **WebView mint** stack under `features/player/`:
  - `SabrWebViewPoTokenProvider` — provider facade, wired into
    `sabrSessionStore.setPoTokenProvider` via `YouTubePlayService`; also
    implements `SessionPoTokenHook` (player-request session pot) and
    `invalidatePoTokenIdentity` (attestation rotation: clears every
    visitor-bound cache + resets the breaker, then youtube_core re-pins a
    fresh visitorData and the generator re-initializes BotGuard)
  - `SabrPoTokenWebRuntime` — hidden WebView BotGuard runtime
  - `SabrLocalDomPoTokenGenerator` — local-DOM mint path
- Do not move PoToken WebView policy into `mediaservice` or `youtube_core`;
  those modules only consume the `SabrPoTokenProvider` interface.
- Mint is **bounded**: a timeout + circuit breaker so a wedged ArkWeb can
  never hang SABR playback. An empty SABR response ("come back with a
  PoToken") triggers an immediate mint instead of waiting out the backoff,
  and mediaservice gates demand-side SIDX on the pending injection via the
  startup URL gate.
- Only the player-token cache is **visitor-bound** (it stores the visitorData
  it was minted against and re-mints on mismatch); the per-video and DASH
  caches key on `videoId` only — a visitor change takes effect through the
  generator's minter re-initialization plus the invalidate-time cache clear.
  Player/per-video pot cache TTL is 6h (inline literal).
- **Two pot kinds**: the **session pot** (only for the /player request, served
  via the `SessionPoTokenHook`, minted under the fixed `'__player__'`
  identifier — visitorData only decides minter initialization and cache
  ownership, not the content binding) and the **per-video pot** (content
  binding = `videoId`, for UMP `getPoToken`); DASH `pot=` has its own
  short-TTL cache. All are cleared together on identity invalidation.
- The att/get attestation request body is only
  `{context: {client: {clientName: 'WEB', clientVersion}}, engagementType}`;
  headers are `User-Agent` (desktop UA), `Accept`, `Content-Type`,
  `x-goog-api-key`, `x-user-agent: grpc-web-javascript/0.1` — no visitorData,
  no hl/gl, no `X-Goog-*`/`X-YouTube-*`/`Origin`/`Referer`. The BotGuard
  `vm.a(...)` bootstrap uses the 6-argument signature and the callback only
  consumes `asyncSnapshotFunction` (no `loggerFunctions`).
- `warmRuntime(visitorData): void` is fire-and-forget BotGuard pre-init
  (queued until the WebView attaches, re-triggered by `setMinter`);
  `invalidatePoTokenIdentity(...)` clears the caches and resets warm/breaker
  state without awaiting BotGuard. `getPlayerPoToken` keeps the not-warm
  fast-skip so TTFF never waits on BotGuard.

## 7. i18n
- 10 locales shipped: `base`, `en_US`, `ar_SA`, `de_DE`, `es_ES`, `fr_FR`,
  `ru_RU`, `zh_CN`, `zh_HK`, `zh_TW`.
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
  `EntryAbility.onBackground`). Presentation (when to drop video tracks)
  is owned by `PlayerPresentation` in entry, not by native MPV defaults alone.
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
- Parent-directory reference trees are `../NewPipe` and
  `../PipePipe/PipePipeClient`. Relevant Android sources include
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
  `.deveco/plans/`, signing material, or any `AGENTS.md`.
- Add top-level mutable state in a HAR module's `Index.ets` — use
  `getInstance()` or factories.
- Call `AppStorage.get` from `mediaservice` or `youtube_core` code paths.
- Put changelogs or commit-specific notes into this file.
