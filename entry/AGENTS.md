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
| `home` | Home feed, channel/playlist/search services + parsers (incl. TV lockup view-model parsing), recommend swiper / list UI; `HomeTabContent` — 首页 tab 内容宿主（feed 加载状态机 + 推荐位 banner + 三个 @LocalBuilder 卡片），Index 经 `HomeTabController` 触发 reset。**首页信息流按 `VideoItem.isShort` 拆成 `longList` / `shortList` 两份**（同一份 feed，切换维度不重新请求）：标题栏（搜索图标左侧）的切换符号在两者间切（`UIConfig.homeFeedMode`，持久化 `cfg_homeFeedMode`）。短视频只来自账号相关内容：① 首页 feed 的 Shorts 货架（`harvestShortsFromFeed` 自动多翻 ≤5 页去收）；② **feed 翻到顶后**接「我的频道」的 `/shorts`（`topUpShortsFromChannels`：订阅频道 → 观看历史频道，去重 ≤12 个，独立分页，`interleaveByChannel` 轮转交织防"整屏同一作者"）。**不用泛搜索补货**。推荐位 banner 只在长视频维度显示 |
| `search` | `SearchPage` (NavDestination) |
| `player` | Player / detail pages, play queue, `YouTubePlayService`, environment, continuation, PiP, **SABR PoToken mint** (`SabrWebViewPoTokenProvider`, `SabrPoTokenWebRuntime`, `SabrLocalDomPoTokenGenerator`), stream-info sheet live stats (`StatsBarGraph` + 500ms `controller.getPlaybackStats()` polling, only while the sheet is open), **布局状态机**（PlayerPage 方法派生，输入 `@Env(WINDOW_SIZE/BREAK_POINT)` + 视频比例：竖向窗口 → 上视频+下信息；真横屏且容得下 → 左视频+右信息栏 `clamp(W/3, 320, 480)`；非竖向但容不下 → 挤压强制铺满，信息经播放器菜单"视频信息"以 CENTER sheet 打开；内容组件 `components/PlayerInfoPanel.ets` 三处复用；信息 sheet 必须 `showClose: false`（自带关闭按钮与面板 Tab 栏重叠，关闭走拖拽条/点空白）；强制全屏态（`isFullLandscapeScreen() && !isManualFullscreen`）必须 `VideoPlayer.showFullscreenButton=false`（仅用户手动全屏保留退出入口）；ArkUI V1 @Component 不支持 ES get 访问器——布局派生必须用普通方法）, **直播聊天/实时评论（只读）**：`PlayerInfoPanel` 在 `isLiveNow` 时追加第 4 个「聊天」Tab（`LiveChatPanel`），可见时才轮询、离开/切台/换视频即停；首访 `/next` 的 `conversationBar.liveChatRenderer` 取 continuation，之后按服务端 `timeoutMs`（1–15s 夹紧）轮询 `live_chat/get_live_chat`，失败 5s 重连；只解析文本 / Super Chat / 会员消息，不做发送或点赞（避免账号风控）。协议实现见 `youtube_core` `LiveChatExtractor`，网络走 `YouTubePlayService.fetchLiveChatInitial/fetchLiveChatPage`）, **AI subtitle**: live path = P0 tlang 服务端自动翻译轨（`withAutoTranslatedTrack` 追加虚拟轨；注意 YouTube 按出口 IP 做 429 风控，出不出字幕取决于网络）；**[DISABLED]** P1 系统 AICaptionComponent、P2 gtx/LLM 整轨翻译（`translate/`）、P3 端侧 ASR（`asr/` + `workers/AsrStreamingWorker.ets`：`AsrLiveCaptionService` 真流式识别，MPV PCM tap + sherpa OnlineRecognizer 流式 zipformer 中英双语 int8；菜单项、Options 入口/设置页、PlayerSession/AVPlayer 接线、build-profile worker 注册均已注释，`AsrModelManager.clearAll`/`clearCaches` 的清数据接线保留以清理已下载模型）——入口/设置项均已注释，代码保留，重新启用 = 取消对应 [DISABLED] 注释块 |
| `playlist` | Playlist list + detail |
| `subscription` | Subscription manage + feed service (bottom tab) |
| `favorites` | `FavoritesPage` |
| `local` | Local library + downloads + **本地导入**：`LocalMediaPage`（系统文件选择器导入、应用内播放、删除）挂在 `LocalPage` 的第 3 个 sub-tab（观看历史 / 下载视频 / 本地文件）。导入文件复制到 `filesDir/local_media/`，索引 `local_media_json`，与下载库完全独立（独立目录、独立索引、独立队列来源 `localFiles`）；播放复用 `PlayerSession` 的 `LOCAL_FILE` 通道与 `local:<id>` 续播键 |
| `options` | `OptionsSheetHost` — options sheet 宿主（inner HdsNavigation + 全部子页 destination + `OptionsNavScaffold`；无入口的 app_lang/content_lang/content_country picker destination 已移除），Index 经单对象 params 传回调。Main（一级菜单分 通用/个性化/播放/其他 四组）/ appearance / playback（拆分为四页：播放 `OptionsPlaybackPage`（含 下载 并发 picker + **下载超时 picker**）/ 手势与操控 `OptionsGestureControlPage`（长按倍速 `HOLD_SPEED_VALUES` 等手势项 + **中央播放按钮开关** + **点击画面切换播放/暂停开关**）/ 字幕 `OptionsSubtitlePage`（字幕样式：字号/底边距/颜色/背景/偏移/翻译语言）/ 性能与缓冲 `OptionsPerformancePage`（后台纯音频、硬解、GPU 渲染、内存缓存/预读/缓冲大小调参）；播放端点 per-state: guest `tv_samsung|visionos|mweb` (default tv_samsung), signed-in `tv_downgraded|mweb`, persisted in `PlaybackConfig`, applied via `AuthStateHelper.applyPlayerClientConfig` + prefetch-cache clear) / language-region / **network**（含**常驻连接状态条** + **重新应用并重启**按钮 + 地址格式示例）/ log_page（应用日志页）/ data-account（页尾含 恢复 组：恢复所有配置 / 清除应用全部数据；独立 `OptionsRecoveryPage` 已删除，回调经 data_account destination 透传）/ ai-subtitle **[DISABLED]**（`ai_translate` destination 与 OptionsMainPage 入口行均已注释，产品只保留 P0 tlang；`OptionsAiTranslatePage` — 端侧识别模型下载/删除管理，标题 `yt_option_ai_subtitle`，页内 P2 gtx/LLM 配置区同处注释块） / about-update (GitHub Releases check + AppGallery test link; the update-check call site is inline in `OptionsMainPage`, `UpdateChecker` + `APPGALLERY_TEST_URL` live in `common/UpdateChecker.ets`; the About UI is `common/components/AboutPage.ets`, hosted as the `about_page` destination on `optionsNavStack` via `onAboutClick` — there is no `OptionsAboutPage`) |
| `help` | `HelpGuidePage` — 6-page onboarding/help swiper (welcome + sign-in, account data, network proxy, quality/cache, downloads). Two entries: first-launch full-screen overlay on `Index` (an `if`-mounted layer in the root Stack, shown while `PreferencesStore` key `cfg_help_seen` != `'true'` with a 500 ms delay; bindSheet/bindContentCover on Navigation-hosted nodes do NOT present at app-start timing — do not revert to them) and Options main page "帮助" item (`help_page` destination in the options sheet). `resetAllConfigs` resets the flag; `clearAllAppData` clears it via `PreferencesStore.clearAll()`. Illustrations are `resources/base/media/guide_*.png` (welcome page uses `app_icon.png`). |
| `user` | User / channel info; Library saved playlists (WEB classic renderers + TV lockup view models) |
| `shorts` | **已停用（代码保留）**：全屏 Shorts 页 + 主页悬浮球 —— `ShortsPage`（NavDestination，纵向 Swiper + 常驻单 surface）、`ShortsFeedService`、`FloatingShortsBall`、`ShortsSurface`；播放走 `PlayerSession.playShorts`（同会话换源 + `AvPlayerController.setFileLoop` 单条循环 + `YouTubePlayService.prefetch` 预取）。入口已换成**首页标题栏的长/短视频切换**（见 `home` 行），`mediaservice` 的 `setFileLoop`/`setMuted` 也随之停用。恢复方式见 `shorts-design.md` 附录 A。已踩的坑（恢复时别再踩）：Swiper 页内容只声明 `parallelGesture(TapGesture)`、不声明 `LongPressGesture`（400ms 后无条件成立，会吃掉慢速拖动 → Swiper 不滚动），长按 2x 用 `onTouch` + 计时器自实现；滑动换条先调 `PlayerSession.invalidatePendingPlay()` 作废在飞代际，过期源不得提交；feed 条目非响应式，作者/头像要复制到 `@State` 才有 UI 刷新；搜索源必须递归展开货架容器 |
| `auth` | WebView cookie login (`WebViewLoginPage`) + device/QR OAuth (`DeviceQrLoginPage`) |

**播放器交互规则**（`features/player/components/AVPlayer.ets`，改手势前必读）:
- 容器上是一个 `parallelGesture(GestureGroup(Exclusive, 双击, 单击, 滑动, 长按))`；
  **子节点的 `onClick` 与容器的单击手势会同时收到同一次点击**（不同节点的
  手势默认并行识别）。中央播放按钮因此必须自己"去重"：
  `isCenterButtonTap(event)` 用点击坐标判定是否落在按钮上，落在按钮上时
  `onCenterTap` 只重置自动隐藏计时器、**不**切换控件显隐——否则用户点中央
  按钮恢复播放的瞬间，控件反而被单击手势收起来。
- 交互进行中（`activeInteraction !== NONE`：菜单已打开 / 正在拖进度条 /
  正在滑动）时，单击不再处理控件显隐，否则"点开更多菜单"会连带收起控件。
- **画面手势挂在独立图层，不挂容器**（`GestureLayer()`，zIndex `BASE+2.2`）。
  播控层整层是 `HitTestMode.Transparent`，手势若挂在容器（播控层的祖先）上，
  **控件上的每一次点击都会一并落进画面的手势组**：按一下播放键 → 单击手势
  把控件收走（正在操作却 UI 消失）；连点按钮两下 → 双击手势触发 ±15s 跳转。
  独立成层后，控件点击的命中路径里根本没有这一层，泄漏从根上消失。
  层级约束：必须在**字幕拖动层（BASE+2.5）之下**（字幕层用自己的 PanGesture
  拖动，被压住就拖不动），又必须在**缓冲提示层（BASE+2.0）之上**（那个是
  全屏层，压住它画面空白处就点不到了）。
- **单击画面空白处 = 切换控件显隐**（`onCenterTap`）：点一下收起、再点一下
  唤出。收起只发生在「控件可见且用户明确点了空白处」时——按播放键、拖进度条、
  开菜单这些控件上的操作不再连带收起控件。暂停态下 `canAutoHideControls()`
  为 false → 单击只显示不收起，"看清时间码再精确暂停"的形态始终可用。
- **双击在中央播放按钮上不响应**（`isCenterButtonTap` 判定）：那里是"恢复
  播放"的单击目标，双击误触发快进会让人以为画面自己跳了。
- 两个独立开关：
  - `UIConfig.showCenterPlayButton`（默认开）——暂停时画面中央的大播放按钮；
    关闭后画面中央保持干净。
  - `PlaybackConfig.tapToTogglePlayback`（默认关）——单击画面直接播放/暂停，
    控件显隐跟随播放状态（暂停时常驻、恢复后按节奏自动收起）。它是**手势
    方案的参数项**（和双击步长一样）：`enhanced` 预设关、`youtube` / `bilibili`
    预设开，改动它不会把手势方案标成"自定义"。
- 底部播放/暂停键在**缓冲中也必须可点**（缓冲是网络侧问题，不该锁掉用户的
  停止手段）；中央按钮在缓冲中不显示（此时中央已有 LoadingProgress）。
- 播放结束时中央按钮换成"重播"图标（`sys.symbol.arrow_counterclockwise`）。
- `PlayerSession.stopPlayback()`：保存进度 → 停 PiP → 释放媒体（引擎、AVSession、
  连续后台任务随之结束）→ 清空队列。播放器菜单里的「停止播放」用它，并同时
  `actionHub.closePage()`（留在播放页只会看到一个已释放的空壳）。

## 3. Common stores / singletons (`common/`)
Persistent state and shared singletons:
- `PreferencesStore.init(context)` — key/value store; init in `EntryAbility.onCreate`.
- **配置是响应式的，不要 clone**：`UIConfig` / `PlaybackConfig` 都是
  `@Observed` 类、字段全部 `@Track`，存放在 AppStorage 的 `uiConfig` /
  `playbackConfig`。改设置的标准写法是**就地改字段**再落盘：
  ```ts
  this.params.updateUiConfig(cfg => cfg.showCenterPlayButton = val);
  ```
  `Index.updateUiConfig` / `updatePlaybackConfig` 负责 `saveToPreferences`。
  **不要再写 `clone()` + 整体替换**：那份逐字段手抄的拷贝漏一个字段就会
  静默把该配置重置回默认（已经踩过一次），而且整体替换会让整棵子树重渲染、
  开关动画被重启（表现为"打开又关闭"）。ArkTS 禁 `Object.assign` / 按下标取
  属性，想做全量拷贝只能手抄——所以更好的做法是**根本不拷贝**。
  官方依据：class/Object 类型的 `@StorageLink` 可观察到「对象整体赋值和属性变化」。
- **开关组件本地自持状态**：`PlaybackToggleRow` 用 `@State localOn` + `$$` 双向
  绑定持有真实状态，父级只下发意图。原因：ArkUI 的 `Toggle` 在 `isOn` 被
  **程序化**改写时同样会回调 `onChange`，受控写法会形成
  「回写→回调→再回写」的回路并重启动画（用户看到"快速打开然后关闭"）。
  `PlaybackSelectRow` 同理屏蔽了程序化 `onSelect`（`index === selectedIndex`
  时直接返回）。

- `AppState`, `UIConfig`, `PlaybackConfig` — `AppStorage`-backed config models
  (playback quality/cache/GPU, background video-off delay, system AI caption
  (`systemAiCaption` + `systemAiCaptionSource`), **下载超时 `downloadTimeoutMinutes`**,
  **中央播放按钮 `showCenterPlayButton`**,
  **首页维度 `homeFeedMode`**（`long`/`short`，首页长视频/短视频两份列表）,
  **Shorts 三件套 `shortsBallEnabled` / `shortsBallX` / `shortsBallY`**
  （随全屏 Shorts 模式一起停用，字段保留便于恢复）, etc.).
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
  (`AvPlayerController.refreshNetworkProxy`). The same repoint hook also
  fires at the end of every `applyInternal`, so mid-playback proxy config
  changes (kind/host/auth/off) refresh MPV's env without waiting for the
  next load. On fuse-blown the `setFailureListener` hook
  logs an ERROR and toasts `yt_proxy_bridge_unavailable`; no
  auto-restart — a user re-save re-applies and resets the fuse. The WebView
  override has **no** direct-fallback rules — a dead proxy fails visibly.
  HTTP **with username/password** also uses the bridge for ArkWeb and the
  app-level proxy
  (HTTP-upstream mode — `insertProxyRule` accepts no userinfo and the ArkUI
  Image fetcher does not answer proxy 407 challenges, so the bridge injects
  `Proxy-Authorization: Basic` upstream and both point at the loopback
  bridge, whose local side is auth-free); only the
  `HttpProxyOptions` snapshot stays native credentialed, and a bridge start
  failure removes the WebView override and clears the app proxy (fail
  visible, never silent
  direct). Unauthenticated HTTP needs no bridge and talks to the upstream
  natively everywhere.
  **常驻状态**：`NetworkProxyStatus`（`@Observed`，挂在 AppStorage `networkProxyStatus`）记录 enabled / bridgePort / bridgeRunning / bridgeFuseBlown / lastApplyOk / lastTestOk；设置页「网络」顶部常驻状态条 实时显示，熔断或上次应用失败时出现「重新应用并重启」按钮（`restartProxy` → 重新 apply → 复位熔断）。
- `NetworkHandoverService` — network-handover adaptation. Single
  subscription site (`connection` default-network `netAvailable` /
  `netUnavailable` events; the SDK kit set has no NetworkBoostKit
  `netHandover`), started/stopped by `EntryAbility`. On a default-network
  switch or loss (debounced 2s, netId-tracked) it aborts stale in-flight
  connections so playback fails fast instead of stalling on timeouts:
  `LocalMediaProxy.abortAllUpstreamFetches` (local-proxy upstream fetches)
  and `sabrSessionStore.abortAllInFlightPosts` (SABR UMP in-flight POST
  only — sessions stay open, their own retry/backoff paths recover).
- `DownloadManager` — offline download queue + the **download library index**.
  Tasks are memory-resident while downloading; finished entries persist through
  `DownloadTaskStore` (Preferences key `download_tasks_json`, DTO only —
  `StreamInfo`/context are not serializable). Terminal states are written from
  `runTask`'s `finally` via `notifyTasksChanged()`. `restoreTasks()` runs from
  `Index.aboutToAppear` and rebuilds completed entries, dropping any whose
  `outputPath` no longer exists on disk; it then scans `filesDir/downloads/*`
  and revives directories with no index record (`recoverOrphanedDownloads`,
  title taken from the file name, no YouTube id — favorite/share are hidden for
  those), so files can never become unreachable. A finished
  entry **is** the playable video entry: tap plays it in-app, delete removes the
  entry plus its sandbox `filesDir/downloads/<taskId>` directory, and export
  (row menu) writes a second, user-owned copy without deleting the entry
  (`exportedPath` records the correspondence). There is **no** auto-export at
  task end. The whole library goes into the play queue as one list
  (`PlayQueueSourceHint.type === 'downloads'` → `setAdhocQueue`), so tapping an
  entry starts there and autoplay continues through the list.
  `clearAllAppData` keeps completed entries and their files.
  **重试与超时**：失败任务在「本地 → 下载视频」里主按钮是「重试」——重试前
  会**重新提取一次**拿到新鲜流地址（googlevideo 直链带 `expire`，SABR 的
  bootstrap 同样短命），并优先选回原来的 itag（分辨率/音轨不变），
  `DownloadManager.retryTask` 最多接受 `MAX_RETRIES=3` 次重试。
  另有**看门狗**：单个任务超过「下载超时」预算（`UIConfig.downloadTimeoutMinutes`，
  默认 30 分钟，0 = 不超时）即判失败并让出并发槽位，避免卡死任务堵住整个队列。
- **下载**（`common/DownloadManager.ets`）：条目分 **video / audio 两条流**分别下到
  `filesDir/downloads/<taskId>/`，最后合并成一个文件。两条流都是 **10MB 一块的
  Range 请求**（`downloadChunkedStream`，YouTube 直链把区间写进 URL 的 `&range=`）。
  - **断点续传**：失败时**不删分片**，重试从磁盘上已有的字节接着写
    （`computeResumeOffset` → `fs.lseek(fd, offset)` 定位后继续追加）。三个前提：
    ① 流的 itag 与首次尝试一致（`_resumeVideoItag`/`_resumeAudioItag` 只记首次，
    重试换流就拒绝续传）；② 流总长度已知（否则发不出 Range）；③ 服务端认 Range ——
    续传时若回 `200`（整体）而不是 `206`，说明服务端无视了 Range
    （`DOWNLOAD_RANGE_IGNORED_MARKER`），此时丢弃半截文件从头再来。
  - **暂停 / 继续**：下载条目上点一下 = **暂停**（`pauseTask`：停掉在飞请求，
    **保留条目与分片**）；条目变「已暂停」+ 主按钮变「继续」（`resumeTask`：
    重新提取新鲜流 → 从断点接着下）。**停止/删除只在长按菜单里**（`deleteTask`：
    取消在飞请求 + 删条目 + 删分片）。暂停条目会落盘（`DownloadTaskRecord`
    带 `resumeVideoItag`/`resumeAudioItag`），重启后仍能继续 —— 恢复时按
    `taskDir` 判断分片是否还在，并用它算真实进度。
  - 重试会**重新提取**拿新鲜直链（googlevideo 的 URL 会过期），但 itag 优先选回
    原来那条（分辨率/音轨不变）→ 字节可续。
  - **看门狗**：单次尝试超过「下载超时」预算（`UIConfig.downloadTimeoutMinutes`）判失败；
    另有 30s「无进展」看门狗（连接吊住时只滴一个字节的场景）。失败条目**不落盘**，
    重启后从索引里消失（已完成 / 已暂停的条目才持久化，见 `DownloadTaskStore`）。
  - `SABR` / `HLS` 两条路径走各自的下载器（`downloadSabrStreams` /
    `downloadHlsStream`），**不支持断点续传**（整段重来）。
- `DownloadTaskStore` — `PreferencesStore` key `download_tasks_json`; the only
  index that can reach `filesDir/downloads`, so it deliberately survives
  "clear all app data".
- `LocalMediaProgressStore` — `PreferencesStore` key `local_media_progress`;
  per-local-item resume position keyed by the local entry id (`local:<taskId>`).
  Deliberately **separate** from `WatchHistoryStore`, which is keyed by YouTube
  `videoId` and never records per-item progress for local sources. Cleared by
  "clear all app data" together with watch history.
- `LocalMediaStore` — **本地导入库**（`PreferencesStore` key `local_media_json`，
  文件在 `filesDir/local_media/`）。`restore()` 启动对账并丢弃文件缺失的条目；
  `importFromUris()` 从 `DocumentViewPicker` 复制最多 10 个视频进沙箱；
  `delete()` 删文件 + 索引 + `LocalMediaProgressStore`。与下载库刻意分离：
  独立目录/索引/队列来源（`localFiles`），不共享 `DownloadTask` 状态。
  导入文件属于用户媒体，和 `filesDir/downloads` 一样在「清除应用全部数据」时
  **保留**（`persistCurrent()` 在 Preferences 清空后重建索引）。UI 是
  `features/local/LocalMediaPage.ets`（本地 tab 第 3 页）。
- `PlayerSession` — singleton player state for the active `AvPlayerController`.
  Two session-level modes ride here and are published to `AppStorage` for the
  player UI: `isAudioOnlyMode` and `isLocalMode`. A `VideoItem` with
  `localMediaPath` set plays as a local file: `doPlay` branches to
  `doPlayLocal`, which skips `YouTubePlayService`/`beginPrepare` entirely and
  submits one synthetic `LOCAL_FILE` progressive stream; the sandbox path is
  handed to MPV untouched. `isLocalMode` is what gates the player UI down to
  local-only chrome (see §4 and `VideoDetails`/`PlayerInfoPanel`/`AVPlayer`).
  `beginLocalPrepare(video)` must run in `Index.openVideoDetail` before a local
  page opens: it sets `_prepareVideoId` + local mode so the previous player
  page's `aboutToDisappear` sees a newer source and does not
  `closeForNavigation()` the fresh local session (the old race left local
  playback torn down / online detail tabs visible). `play()` also flips local
  mode synchronously before submitting the source.
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
`VideoItemContextMenu` (`common/components/VideoItemContextMenu.ets`) is the single
long-press context menu for video items: info section + standard items (favorite
toggle / view author / audio-only / download / share) + per-surface `extraItems`.
Surfaces trim standard items via `show*` flags — the play queue disables
audio-only (its click already switches in-queue), playlist-sourced history entries
disable the whole video set (delete-record extra only). It resolves `actionHub`
through its own `@Consume` (bindContextMenu content shares the host tree; never
assign a host's `@Consume` into a child's plain property). The download item
routes to `ActionHub.downloadVideo` → `Index.startCardDownload`:
`YouTubePlayService.extractForDownload` (extractChain-serialized, prefetch-cache
aware, awaits the per-video DASH PoToken injection before handing out URLs) →
gates (extract failure / live (`videoInfo.isLive`, never the list badge) / no
downloadable streams → toast) → root-hosted `DownloadDialog`. Task construction is
shared via `buildDownloadTaskFromSelection` (`DownloadDialog.ets`); classification
+ download sorting via `PlayerModel.classifyForDownload` (mediaservice).
`MediaVideoFeed` is the shared video-feed skeleton (loading / error / empty /
grid / wide-strip / single-list branches over Grid|List + LazyForEach); pages
feed it a `FeedDataSource` (`common/model/FeedDataSource.ets`; `setData`
prefix-diffs for paged appends and skips the full reload entirely when the
key sequence is unchanged, firing only per-item `onDataChange`) plus stable
Scroller/callback members, and pass volatile display state as a single
`MediaVideoFeedParams` object-literal `@Prop`. `FeedDataSource` implements `IDataSourcePrefetching`: `MediaVideoFeed`
binds it to a `BasicPrefetcher` and reports the visible range from
`onScrollIndex`; `prefetch(index)` warms the item's first-choice thumbnail via
`ThumbPrefetcher` (`common/model/ThumbPrefetcher.ets` → `cacheDownload`,
LAZY strategy, bounded in-flight, `cancel(index)` aborts), so cards hit the
system image cache when scrolled into view. Grid column counts are centralized in `ListLayoutUtils`
(`getVideoGridColumnCount` / `getWideListColumnCount`); grid mode additionally applies the user's
card-density preference (`UIConfig.homeGridDensity`: `compact` +1 / `cozy` −1 / `auto` 0 — Options →
appearance, persisted `cfg_homeGridDensity`) via `UIConfig.gridDensityOffset` as the second
`getVideoGridColumnCount` argument, clamped to [1,5]. Feed builder / layout rules (hard constraints):
- Builders passed into `MediaVideoFeed`'s `@BuilderParam`s must be
  `@LocalBuilder` — never `@Builder`, never `.bind(this)` (a plain `@Builder`
  passed by reference binds `this` to the call-site component, so builders
  that touch page state break).
- The Grid branch leaves normal cards without `columnStart`/`columnEnd`
  (auto-flow placement) — explicitly positioning every item pins them to
  column 0 and collapses the grid to a single column; only full-width items
  (header/footer/span>1 cards) set `columnStart(0).columnEnd(columns-1)`.
- Never give LazyForEach feed items or header/footer items inside a lazy
  Grid/List an always-on `.transition(isScaleTran(...))` — recycling and
  branch rebuilds replay it, so cards vanish or pop mid-scroll instead of
  scrolling off. Entrance animation is **one-shot gated** (`armEntryAnim` /
  `entryTransitionOf` + `customAnimationUtil.isScaleTranEnter`): only the
  first screen of items after a (re)load **while the list is scrolled to the
  top** may play the insert-only scale/fade-in; mid-scroll full reloads
  (background subscription merges, auth-fallback refetches) do not arm, and
  a key that has played never replays (`entryAnimDone` persists across
  reloads). Symmetric `isScaleTran` is acceptable only on eager `ForEach`
  lists (favorites / local / downloads / comments), which never recycle.
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
`SECTION_CARD_RADIUS`, `TITLE_BAR_HEIGHT`) — media rows/cards (VideoMediaCard,
PlaylistCard, ChannelCard, DownloadTaskRow, history, queue) must consume them,
never literals. Grid-mode `VideoMediaCard` is a top-to-bottom card:
edge-to-edge 16:9 thumbnail clipped by the card radius (thumb radius 0), meta
bar below = title (≤2 lines) + one meta row `作者 · 统计` (stat slot = view
count → publish time → duration, first available) with the action button
pinned at the row's right end; both segments render whenever the data exists
and overflow truncates with ellipsis — the long-press menu carries the full
info.
PlaylistCard/ChannelCard context menus follow the same 220vp + info-section
pattern as `VideoItemContextMenu`; floating-title-bar pages reserve
`safeAreaTop + TITLE_BAR_HEIGHT` at content top and set
`avoidLayoutSafeArea: true` on the title bar.

## 4. AppStorage keys
Key cross-cutting keys (**non-exhaustive** — grep `AppStorage.setOrCreate`
in entry for the full set):
- `context`, `uiContext`, `isAppBackground`, `currentBreakpoint`, `playerLoading`
- `uiConfig` (`UIConfig`), `playbackConfig` (`PlaybackConfig`)
- `networkProxyConfig` (`NetworkProxyConfig`) — set in `AppState.init` / Options Network
- `autoPlayQueue` (boolean) — session-scoped queue auto-play switch; seeded
  from `playbackConfig.autoPlayNext` on every launch and on settings
  save/reset/restore.
- `PlaybackContinuationService.APP_STORAGE_PENDING_KEY` — JSON-serialized
  continuation payload awaiting consumer.
Additional families set at startup / by the player shell: window & safe-area
geometry (`deviceWidth`/`deviceHeight`, `statusBarHeight`, `navBarHeight`,
`cutoutAvoid*` / `systemAvoid*` / `playerControlAvoid*` / `playerGestureSafe*`,
`windowStatus`), theme (`themePrimaryColor`, `currentColorMode` /
`effectiveColorMode`), PiP / window-mode flags (`isPiPActive`,
`isPipHandoffPending`, `isFloatingWindow`, `isSplitScreen`, `isMultiWindow`,
`isAudioOnlyMode`, `isLocalMode`, `playerPageVisible`, `selectedVideo`), and collection
store caches (`favorites`, `playlists`, `subscriptions`, `watchHistory`,
`localQueues`, `downloadTasks`, `localMedia`, `authStatus`). Shorts internals:
`shortsSurfaceId`（Shorts 常驻 surface，controller 重建后据此重绑）、
`shortsPageVisible`。

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
  `tv_samsung` guest (pot-free TVHTML5 direct adaptiveFormats URLs; `visionos`
  GAPIS stays selectable); **tv_downgraded** (token-free direct URLs) stays
  selectable in Options → 播放端点 for the signed-in state — a deliberate
  divergence from upstream PipePipe, which restricts a signed-in session to
  `mweb` only. Endpoint changes go through
  `AuthStateHelper.applyPlayerClientConfig` (config + identity/pot reset);
  `EntryAbility.onCreate` pushes the persisted values via
  `YoutubePlayerClientConfig.setConfiguredClients` before reconcile.
- **Endpoint visibility on failure**: the player error panel shows the endpoint
  that was in effect (`ErrorInfo.endpoint` ← the endpoint of the extraction
  that failed, falling back to `YoutubePlayerClientConfig.getYoutubePlayerClient()`,
  rendered as `yt_error_endpoint_hint`) so a failed playback can be attributed
  to a client before the user switches it (PipePipe `ErrorActivity.getEndpoint`
  parity).
- **Endpoint auto-fallback** (`YouTubePlayService.extractWithEndpointFallback`):
  when the SABR endpoint (`mweb`) yields no playable stream — the extraction
  throws or returns without a stream — the extraction is retried **once**
  through `tv_downgraded` (token-free TVHTML5 direct URLs, no PoToken, no UMP
  session). The retry uses `YoutubePlayerClientConfig.setExtractionClientOverride`
  (one-shot; the configured client and the explicit pin are untouched) and
  clears it in a `finally`. `prefetch` and `extractForDownload` go through
  `play()` and therefore inherit the fallback. The failure reason stays in the
  log (`endpoint fallback mweb→tv_downgraded …`).
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
     cache, consumed via `takePrefetched`). The prefetch caches (results,
     in-flight tasks, per-video DASH-pot injections) are **partitioned by the
     effective playback-auth state** (`guest` | `auth`, via
     `isAuthEnabledForPlayback`): entries are keyed `${partition}|${videoId}`
     with the mode captured at extraction time and are only read/deduped inside
     their own partition. Toggling 登录态用于播放 (or the master auth switch /
     login / logout) switches which partition serves — the other side is kept,
     never deleted (each side owns its own cache). Playback-endpoint config
     changes and restore-defaults still clear BOTH partitions via
     `clearPrefetchCache` (the extracted URL shape changes for that state).
     Extraction is serialized through a mutex — the extractor is a stateful
     singleton; prefetch must never run concurrently with real playback
     extraction.
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
- **Binding follows the home page experiment flags** (PipePipe parity):
  content binding mints per identifier (videoId for /player + UMP pots),
  session binding mints once against the DataSync ID (signed-in) or the
  bootstrap visitorData (anonymous) and every mint returns that session token.
  DASH `pot=` has its own short-TTL cache. All are cleared together on
  identity invalidation.
- **Attestation bootstrap** (PipePipe `YoutubePageAttestationBootstrap`):
  the BotGuard challenge is parsed from the
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
- **`$r('app.string.x', 参数)` 返回的是「带格式化参数的 Resource」，不是已格式化的
  字符串**（官方 `Resource` 定义：包含"资源 ID、资源类型和格式化参数"）。`Text(...)`
  渲染 Resource 时会套用参数，但 **ArkUI 的 `Select` 解析 Resource 走的是
  `getStringSync(id)`（不带参数）→ 选项里原样显示 "%d 分钟"**。
  凡是把带参数字符串放进 **非 Text 组件**（`Select` 选项、存进对象的 `ResourceStr`），
  一律改成 `resourceManager.getStringSync($r('app.string.x').id, 参数)` —— 直接拿到
  已格式化的字符串。仓库里的既有写法（收藏页/订阅页/搜索页）都是这个模式。
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
  an auth rejection raises the `yt_home_auth_expired_notice` banner, and a
  non-auth recommended failure raises `yt_home_recommended_error`, both via
  `homeModeNoticeMessage` in `features/home/HomeTabContent.ets`. The
  recommended/live selector is only interactive when
  `AuthAccountStatus.canPersonalizedHome` is true (otherwise it renders a
  “sign in first” hint), because signed-out users always get the live kiosk.
  Home feed loads carry a generation counter so a late kiosk response cannot
  overwrite a newer recommended result.

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
  behavior, and ask the user for the path if one is missing. Relevant Android
  sources include
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
