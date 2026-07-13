import { AppLog } from '../common/AppLog';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { i18n } from '@kit.LocalizationKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd, preferences } from '@kit.ArkData';
import { fileIo as fs } from '@kit.CoreFileKit';
import type { BusinessError } from '@kit.BasicServicesKit';
import { ActionHub, ActionHubEvent } from '../common/ActionHub';
import { AuthSessionManager, SearchChannelItem, SearchPlaylistItem } from 'youtube_core';
import { VideoItem } from 'youtube_core';
import { SubscriptionUser } from '../common/SubscriptionModel';
import { LocalStore } from '../common/LocalStore';
import { PreferencesStore } from '../common/PreferencesStore';
import { PlaylistItem, StoredLocalQueue } from '../common/PlaylistModel';
import { WatchHistoryItem, WatchHistoryStore } from '../common/WatchHistoryStore';
import { DownloadManager, DownloadTask } from '../common/DownloadManager';
import { SearchHistoryStore } from '../common/SearchHistoryStore';
import { AppLogStore } from '../common/AppLogStore';
import { VideoSearchResult } from '../features/home/SearchService';
import { LocalMediaProxy, PlayerState } from 'mediaservice';
import { KioskPageResult } from '../features/home/HomeFeedService';
import { ChannelInfoService } from '../features/user/ChannelInfoService';
import { VideoCard } from '../common/components/VideoCard';
import { VideoCardGrid } from '../common/components/VideoCardGrid';
import { HomeRecommendSwiper } from '../features/home/components/HomeRecommendSwiper';
import { ErrorPage } from '../common/components/ErrorPage';
import { SearchPage } from '../features/search/SearchPage';
import { SubscriptionManagePage } from '../features/subscription/SubscriptionManagePage';
import { FavoritesPage } from '../features/favorites/FavoritesPage';
import { LocalPage } from '../features/local/LocalPage';
import { UserPage } from '../features/user/UserPage';
import { PlaylistDetailPage } from '../features/playlist/PlaylistDetailPage';
import { VideoDetailPage } from '../features/player/VideoDetailPage';
import { VideoPlayerPage } from '../features/player/PlayerPage';
import { PlayerPresentation } from '../common/PlayerPresentation';
import { OptionsGoogleAccountPage } from '../features/auth/OptionsGoogleAccountPage';
import { WebViewLoginPage } from '../features/auth/WebViewLoginPage';
import { AuthStateHelper } from '../common/AuthStateHelper';
import { customAnimationUtil } from '../common/AnimationUtil';
import { LanguageManager } from '../common/LanguageManager';
import { SearchLocaleManager } from '../common/SearchLocaleManager';
import { FeedServiceProvider } from '../common/FeedServiceProvider';
import { YoutubeData } from '../common/model/SupportedCountry';
import { OptionItem } from '../common/components/OptionItem';
import { PlaybackSelectRow } from '../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../common/components/PlaybackToggleRow';
import { PlaybackSectionTitle } from '../common/components/PlaybackSectionTitle';
import { OptionsMainPage } from '../features/options/OptionsMainPage';
import { OptionsAppearancePage } from '../features/options/OptionsAppearancePage';
import { COLOR_PRESETS } from '../common/ThemeManager';
import { OptionsPlaybackPage } from '../features/options/OptionsPlaybackPage';
import { OptionsLanguageAndRegionPage } from '../features/options/OptionsLanguageAndRegionPage';
import { OptionsRecoveryPage } from '../features/options/OptionsRecoveryPage';
import { OptionsDataAccountPage } from '../features/options/OptionsDataAccountPage';
import { LanguagePickerDialog, LanguagePickerItem } from '../common/components/LanguagePickerDialog';
import { LanguagePickerPage } from '../common/components/LanguagePickerPage';
import {
  BlurStrategy,
  HdsNavigation,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  HdsTabs,
  HdsTabsController,
  HdsTabsFloatingStyle,
  hdsMaterial,
  HdsNavigationTitleMode,
  SystemMaterialParams
} from '@kit.UIDesignKit';
import { curves } from '@kit.ArkUI';
import { UIConfig, YourtubeDarkMode } from '../common/AppState';
import { ColorModeManager } from '../common/ColorModeManager';
import { LogPage } from '../common/components/LogPage';
import { AboutPage } from '../common/components/AboutPage';
import { buildTitleMenu, buildYourTubeTitleBar, buildSheetTitleBar } from '../common/components/HdsTitleBar';
import { MaterialUtil } from '../common/utils/MaterialUtil';
import {
  PlaybackConfig,
  VideoQualityCap, VIDEO_QUALITY_CAP_LABELS, VIDEO_QUALITY_CAP_DISPLAY,
  CacheSecs, CACHE_SECS_LABELS, CACHE_SECS_DISPLAY,
  DemuxerReadahead, DEMUXER_READAHEAD_LABELS, DEMUXER_READAHEAD_DISPLAY,
  DemuxerMaxBytes, DEMUXER_MAX_BYTES_LABELS, DEMUXER_MAX_BYTES_DISPLAY,
  GpuApi, GPU_API_LABELS, GPU_API_DISPLAY,
} from '../common/PlaybackConfig';
import { PlayerSession } from '../common/PlayerSession';
import { PiPManager } from '../features/player/pip/PiPManager';
import { PlayQueueManager, QueueSourceType, PlayQueueSourceHint } from '../features/player/PlayQueueManager';
import {
  PlaybackContinuationRestoreRequest,
  PlaybackContinuationService
} from '../features/player/PlaybackContinuationService';

const logger = AppLog.getInstance('Index');
const APP_VERSION = '0.5.1';
const DOWNLOAD_CONCURRENCY_VALUES: number[] = [1, 2, 3, 4];


@Entry
@Component
@Preview
struct Index {
  @State videoList: VideoItem[] = [];
  @Provide('safeAreaTop') safeAreaTop: number = 0;
  @Provide('safeAreaBottom') safeAreaBottom: number = 0;
  @State topSafeHeight: number = 0;
  @State bottomSafeHeight: number = 0;
  @State naviIndicatorHeight: number = 0;
  @State activeTabIndex: number = 0;
  @State navPathStack: NavPathStack = new NavPathStack();
  private tabsController: HdsTabsController = new HdsTabsController();
  private homeGridScroller: Scroller = new Scroller();
  private homeListScroller: Scroller = new Scroller();
  @State selectedVideo: VideoItem | null = null;
  @State selectedChannel: SearchChannelItem | null = null;
  @State selectedPlaylist: SearchPlaylistItem | null = null;
  @StorageLink('favorites') favorites: VideoItem[] = [];
  @StorageLink('subscriptions') subscriptions: SubscriptionUser[] = [];
  @StorageLink('playlists') playlists: PlaylistItem[] = [];
  @StorageLink('localQueues') localQueues: StoredLocalQueue[] = [];
  @StorageLink('watchHistory') watchHistory: WatchHistoryItem[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('playbackConfig') playbackConfig: PlaybackConfig = new PlaybackConfig();
  @StorageLink('deviceWidth') deviceWidth: number = 0;
  @StorageLink('pendingPlaybackContinuation') @Watch('onPendingContinuationChanged') pendingPlaybackContinuation: string = '';
  @Provide('actionHub') actionHub: ActionHub = new ActionHub();
  @State showOptions: boolean = false;
  @State isLoadingMore: boolean = false;
  @State isInitialLoading: boolean = false;
  @State homeErrorMessage: string = '';
  @State homeModeNoticeMessage: string = '';
  @State nextPageToken: string | null = null;
  @State kioskNextPageToken: string | null = null;
  @State kioskVisitorData: string = '';
  @State homeFeedSource: string = 'kiosk';
  @State homeMode: string = 'kiosk';
  @State currentQuery: string = "";
  @State lastLoadedQuery: string = '';
  @State currentOptionPage: string = 'main';
  @State optionsNavStack: NavPathStack = new NavPathStack();
  @State optionsDepth: number = 0;
  @State selectedLanguageCode: string = LanguageManager.DEFAULT_LANGUAGE;
  @State systemLanguageCode: string = LanguageManager.LANGUAGE_EN_LATN;
  private webViewLoginBackHandler: (() => boolean) | null = null;

  @StorageProp('themePrimaryColor') themePrimary: string = COLOR_PRESETS[0].primary;
  // 沉浸光感材质效果（首页标题栏 + HdsTabs 底栏共用）。
  // 在 aboutToAppear 里通过 MaterialUtil 检测设备能力后注入；
  // 不支持的设备为 undefined，调用方走降级路径。
  @State immersiveMaterialEffect: SystemMaterialParams | undefined = undefined;
  private readonly GRID_SIDE_PADDING: number = 12;
  // 视频播放器状态
  @State isPlayerFullLandscapeScreen: boolean = false;
  @State isRepliesOpen: boolean = false;

  // 语言与地区选项数据
  @State private appLangItems: LanguagePickerItem[] = [];
  @State private contentLangItems: LanguagePickerItem[] = [];
  @State private contentCountryItems: LanguagePickerItem[] = [];

  // 三个 picker 的对话框控制器
  private appLangDialogCtrl: CustomDialogController | null = null;
  private contentLangDialogCtrl: CustomDialogController | null = null;
  private contentCountryDialogCtrl: CustomDialogController | null = null;

  private buildPickerItems(): void {
    const followSystem = getContext().resourceManager.getStringSync($r('app.string.yt_lang_follow_system').id);

    // App UI 语言 - 使用固定的原生名称，不依赖当前 UI 语言进行翻译
    const appCodes = ['default', 'zh-Hans', 'zh-HK', 'zh-TW', 'en-Latn', 'ru', 'de', 'fr', 'es', 'ar'];
    this.appLangItems = appCodes.map((code: string): LanguagePickerItem => {
      if (code === 'default') {
        return new LanguagePickerItem('default', followSystem, followSystem);
      }
      let native = code;
      // 使用语言自己的原生名称，而不是翻译成当前 UI 语言
      if (code === 'zh-Hans') {
        native = '简体中文';
      } else if (code === 'zh-HK') {
        native = '繁體中文（香港）';
      } else if (code === 'zh-TW') {
        native = '繁體中文（台灣）';
      } else if (code === 'en-Latn') {
        native = 'English';
      } else if (code === 'ru') {
        native = 'Русский';
      } else if (code === 'de') {
        native = 'Deutsch';
      } else if (code === 'fr') {
        native = 'Français';
      } else if (code === 'es') {
        native = 'Español';
      } else if (code === 'ar') {
        native = 'العربية';
      } else {
        try { native = i18n.System.getDisplayLanguage(code, code.split('-')[0]); } catch (_e) {}
      }
      // localized 和 native 使用相同的值，避免依赖当前语言重新翻译
      return new LanguagePickerItem(code, native, native);
    });

    // 内容语言（YouTube SUPPORTED_LANGUAGES）- 使用固定名称
    const defaultLangItem: LanguagePickerItem = new LanguagePickerItem('default', followSystem, followSystem);
    const langMapped: LanguagePickerItem[] = YoutubeData.SUPPORTED_LANGUAGES.map((l): LanguagePickerItem => {
      const code = l.getLanguageCode();
      let native = code;
      // 使用固定的语言名称，避免翻译
      if (code === 'zh-CN') {
        native = '简体中文';
      } else if (code === 'zh-HK') {
        native = '繁體中文（香港）';
      } else if (code === 'zh-TW') {
        native = '繁體中文（台灣）';
      } else {
        // 使用语言自己的原生名称
        try { native = i18n.System.getDisplayLanguage(code, code.split('-')[0]); } catch (_e) {}
      }
      return new LanguagePickerItem(code, native, native);
    });
    this.contentLangItems = [defaultLangItem].concat(langMapped);

    // 内容地区（YouTube SUPPORTED_COUNTRIES）- 使用英文名称
    const defaultCountryItem: LanguagePickerItem = new LanguagePickerItem('default', followSystem, followSystem);
    const countryMapped: LanguagePickerItem[] = YoutubeData.SUPPORTED_COUNTRIES.map((c): LanguagePickerItem => {
      const code = c.getCountryCode();
      let native = code;
      // 使用英文的国家名称，避免依赖当前语言翻译
      try { native = i18n.System.getDisplayCountry(code, 'en'); } catch (_e) {}
      return new LanguagePickerItem(code, native, native);
    });
    this.contentCountryItems = [defaultCountryItem].concat(countryMapped);
  }

  private getItemDisplay(items: LanguagePickerItem[], code: string): string {
    const found = items.find((it: LanguagePickerItem): boolean => it.code === code);
    return found ? found.localizedName : getContext().resourceManager.getStringSync($r('app.string.yt_lang_follow_system').id);
  }

  private getAppLanguageSubtitle(): string {
    return this.getItemDisplay(this.appLangItems, this.uiConfig.userLanguage);
  }

  /** 克隆 UIConfig 并直接赋值给 @StorageLink 属性，确保响应式重绘和持久化同时生效 */
  private updateUiConfig(mutator: (cfg: UIConfig) => void): void {
    const next = this.uiConfig.clone();
    mutator(next);
    this.applyAndSaveConfig(next);
  }

  private updatePlaybackConfig(mutator: (cfg: PlaybackConfig) => void): void {
    const next = this.playbackConfig.clone();
    mutator(next);
    this.savePlaybackConfig(next);
  }

  /** 赋值新配置并持久化到 Preferences */
  private applyAndSaveConfig(next: UIConfig): void {
    this.uiConfig = next;
    UIConfig.saveToPreferences(next);
    DownloadManager.getInstance().refreshTaskPool();
  }

  /** 恢复所有配置为默认值 */
  private resetAllConfigs(): void {
    // 1. 重置 UIConfig 为默认值
    const defaultUiConfig = new UIConfig();
    this.uiConfig = defaultUiConfig;
    UIConfig.saveToPreferences(defaultUiConfig);

    // 2. 重置 PlaybackConfig 为默认值
    const defaultPlaybackConfig = new PlaybackConfig();
    this.playbackConfig = defaultPlaybackConfig;
    PlaybackConfig.saveToPreferences(defaultPlaybackConfig);

    // 3. 应用深色模式
    Promise.resolve().then(() => {
      const colorMode = ColorModeManager.resolveMode(defaultUiConfig.darkMode);
      AppStorage.setOrCreate('currentColorMode', colorMode);
      const uiContext = this.getUIContext();
      const hostContext = uiContext?.getHostContext() as common.UIAbilityContext;
      if (hostContext) {
        hostContext.getApplicationContext().setColorMode(colorMode);
      }
    });

    // 4. 提示用户
    this.getUIContext().getPromptAction().showToast({
      message: $r('app.string.yt_toast_reset_settings_done'),
      duration: 2000
    });
    logger.info('All configs reset to default');
  }

  /** 清除应用全部数据 */
  private clearAllAppData(): void {
    // 1. 停止本地媒体代理服务器
    LocalMediaProxy.stopAll();

    // 2. 清除登录状态（独立的 Preferences 数据库）
    AuthSessionManager.getInstance()?.signOut();
    AuthStateHelper.refresh();
    this.refreshHomeAfterAuthChange();

    // 3. 清除所有 Preferences 数据库
    PreferencesStore.clearAll();
    const hostContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (hostContext) {
      try {
        const cookiePrefs = preferences.getPreferencesSync(hostContext, { name: 'youtube_cookies' });
        cookiePrefs.clearSync();
        cookiePrefs.flush();
      } catch (e) {
        logger.warn('Failed to clear cookie preferences:', JSON.stringify(e));
      }
    }

    // 4. 清理下载临时文件
    if (hostContext) {
      try {
        const tempDir = hostContext.tempDir;
        if (tempDir && fs.accessSync(tempDir)) {
          const files = fs.listFileSync(tempDir);
          for (const f of files) {
            const filePath = tempDir + '/' + f;
            try {
              if (fs.accessSync(filePath)) {
                fs.unlinkSync(filePath);
              }
            } catch (_e) {
              // 忽略单个文件删除错误
            }
          }
        }
      } catch (e) {
        logger.warn('Failed to clean temp dir:', JSON.stringify(e));
      }
    }

    // 5. 重置内存中的状态为默认值
    const defaultUiConfig = new UIConfig();
    this.uiConfig = defaultUiConfig;
    const defaultPlaybackConfig = new PlaybackConfig();
    this.playbackConfig = defaultPlaybackConfig;

    // 6. 清空各业务数据
    this.subscriptions = [];
    AppStorage.setOrCreate('subscriptions', []);
    this.favorites = [];
    AppStorage.setOrCreate('favorites', []);
    this.playlists = [];
    AppStorage.setOrCreate('playlists', []);
    WatchHistoryStore.clear();
    this.watchHistory = [];
    AppStorage.setOrCreate('downloadTasks', []);
    SearchHistoryStore.clearSearchHistory();
    AppLogStore.clear();

    // 7. 应用深色模式（恢复默认）
    Promise.resolve().then(() => {
      const colorMode = ColorModeManager.resolveMode(defaultUiConfig.darkMode);
      AppStorage.setOrCreate('currentColorMode', colorMode);
      if (hostContext) {
        hostContext.getApplicationContext().setColorMode(colorMode);
      }
    });

    // 8. 提示用户
    this.getUIContext().getPromptAction().showToast({
      message: $r('app.string.yt_toast_clear_all_data_done'),
      duration: 2000
    });
    logger.info('All app data cleared');

    // 9. 延迟 3 秒后退出应用
    setTimeout(() => {
      const uiContext = this.getUIContext();
      const ctx = uiContext?.getHostContext() as common.UIAbilityContext;
      if (ctx) {
        ctx.terminateSelf();
      }
    }, 3000);
  }

  //@Provider backPressedDispatcher: BackPressedDispatcher = new BackPressedDispatcher()

  aboutToAppear() {
    this.ensureStores();
    this.buildPickerItems();
    this.initLanguageSettings();
    this.bindActionHub();
    // 沉浸光感能力检测：支持则注入 ADAPTIVE/ADAPTIVE，不支持则 undefined（让 HdsTabs / titleBar 走默认渲染）
    this.immersiveMaterialEffect = MaterialUtil.getSystemMaterialEffect();
    // PiP 恢复：不手动 push 播放页。系统经 navigationId 自动还原出一个播放页，
    // 新页面 XComponent onLoad 会把新 surfaceId 透传给引擎，由 native 运行时把 mpv
    // 重定向到新 surface（见 player_napi SetVideoSurfaceId 的 surface-redirect 分支）。
    // 之前这里再 pushPath 一个 PlayerPage，与系统还原的那个叠加 => 栈里出现两个播放页
    // （上层黑屏、返回后露出下层），故移除。
    PiPManager.getInstance().onPipRestore = () => {
      logger.info('onPipRestore: rely on system navigationId restore, no manual push');
    };
    const uiContext = this.getUIContext();
    const hostContext = uiContext?.getHostContext() as common.UIAbilityContext;
    if (!hostContext) {
      return;
    }
    window.getLastWindow(hostContext).then((windowClass) => {
      try {
        windowClass.setWindowLayoutFullScreen(true);
        const currentColorMode = AppStorage.get<ConfigurationConstant.ColorMode>('currentColorMode');
        const isDarkMode = currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
        windowClass.setWindowSystemBarProperties({
          statusBarContentColor: '#FFFFFF',
          navigationBarColor: '#00000000',
          navigationBarContentColor: isDarkMode ? '#FFFFFF' : '#000000'
        });

        const type = window.AvoidAreaType.TYPE_SYSTEM;
        const avoidArea = windowClass.getWindowAvoidArea(type);
        this.topSafeHeight = this.getUIContext().px2vp(avoidArea.topRect.height);
        this.safeAreaTop = this.topSafeHeight;
        this.bottomSafeHeight = this.getUIContext().px2vp(avoidArea.bottomRect.height);
        this.safeAreaBottom = this.bottomSafeHeight;

        const naviArea = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        this.naviIndicatorHeight = this.getUIContext().px2vp(naviArea.bottomRect.height);

        windowClass.on('avoidAreaChange', (data) => {
          if (data.type === window.AvoidAreaType.TYPE_SYSTEM) {
            this.topSafeHeight = this.getUIContext().px2vp(data.area.topRect.height);
            this.safeAreaTop = this.topSafeHeight;
            this.bottomSafeHeight = this.getUIContext().px2vp(data.area.bottomRect.height);
            this.safeAreaBottom = this.bottomSafeHeight;
          } else if (data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
            this.naviIndicatorHeight = this.getUIContext().px2vp(data.area.bottomRect.height);
          }
        });
      } catch (exception) {
        logger.error('Failed to set the window layout to full-screen. Cause: ' + JSON.stringify(exception));
      }
    });

    this.homeMode = 'kiosk';
    this.kioskNextPageToken = null;
    this.kioskVisitorData = '';
    this.homeFeedSource = 'kiosk';
    this.homeErrorMessage = '';
    this.homeModeNoticeMessage = '';
    this.loadLiveVideos(true);
    this.consumePendingPlaybackContinuation();
  }

  private refreshHomeAfterAuthChange(): void {
    this.homeMode = 'kiosk';
    this.kioskNextPageToken = null;
    this.kioskVisitorData = '';
    this.homeFeedSource = 'kiosk';
    this.nextPageToken = null;
    this.lastLoadedQuery = '';
    this.homeErrorMessage = '';
    this.homeModeNoticeMessage = '';
    this.videoList = [];
    this.loadLiveVideos(true);
  }

  private onPendingContinuationChanged(): void {
    this.consumePendingPlaybackContinuation();
  }

  private ensureStores(): void {
    if (!AppStorage.get<SubscriptionUser[]>('subscriptions')) {
      AppStorage.setOrCreate('subscriptions', []);
    }
    if (!AppStorage.get<VideoItem[]>('favorites')) {
      AppStorage.setOrCreate('favorites', []);
    }
    if (!AppStorage.get<PlaylistItem[]>('playlists')) {
      AppStorage.setOrCreate('playlists', []);
    }
    if (!AppStorage.get<WatchHistoryItem[]>('watchHistory')) {
      AppStorage.setOrCreate('watchHistory', []);
    }
    if (!AppStorage.get<DownloadTask[]>('downloadTasks')) {
      AppStorage.setOrCreate('downloadTasks', []);
    }
    if (!AppStorage.get<StoredLocalQueue[]>('localQueues')) {
      AppStorage.setOrCreate('localQueues', []);
    }
    this.loadSubscriptionsFromStorage();
    this.loadFavoritesFromStorage();
    this.loadPlaylistsFromStorage();
    this.loadLocalQueuesFromStorage();
    this.loadWatchHistoryFromStorage();
  }

  private loadSubscriptionsFromStorage(): void {
    const stored = PreferencesStore.getString('subscriptionsJson', '[]');
    this.subscriptions = LocalStore.loadSubscriptions(stored);
  }

  private syncSubscriptionsToStorage(): void {
    PreferencesStore.setString('subscriptionsJson', LocalStore.saveSubscriptions(this.subscriptions));
  }

  private loadFavoritesFromStorage(): void {
    const stored = PreferencesStore.getString('favoritesJson', '[]');
    this.favorites = LocalStore.loadFavorites(stored);
  }

  private syncFavoritesToStorage(): void {
    PreferencesStore.setString('favoritesJson', LocalStore.saveFavorites(this.favorites));
  }

  private loadPlaylistsFromStorage(): void {
    const stored = PreferencesStore.getString('playlistsJson', '[]');
    this.playlists = LocalStore.loadPlaylists(stored);
  }

  private syncPlaylistsToStorage(): void {
    PreferencesStore.setString('playlistsJson', LocalStore.savePlaylists(this.playlists));
  }

  private loadLocalQueuesFromStorage(): void {
    const stored = PreferencesStore.getString('localQueuesJson', '[]');
    this.localQueues = LocalStore.loadLocalQueues(stored);
  }

  private syncLocalQueuesToStorage(): void {
    PreferencesStore.setString('localQueuesJson', LocalStore.saveLocalQueues(this.localQueues));
  }

  /** Save the current play queue as a local playlist */
  private saveCurrentQueueAsLocal(name: string): void {
    const qm = PlayQueueManager.getInstance();
    const entry = qm.saveAsLocal(name);
    this.localQueues = [...this.localQueues, entry];
    this.syncLocalQueuesToStorage();
  }

  /** Delete a locally saved queue by id */
  private deleteLocalQueue(id: string): void {
    this.localQueues = this.localQueues.filter(q => q.id !== id);
    this.syncLocalQueuesToStorage();
  }

  /** Generate a local queue id with the `local_` prefix used to distinguish local lists. */
  private generateLocalQueueId(): string {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    let id = 'local_';
    for (let i = 0; i < 16; i++) {
      id += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return id;
  }

  /** Create a new local playlist seeded with a single video. */
  private createLocalQueueWithVideo(name: string, video: VideoItem): void {
    const entry: StoredLocalQueue = {
      id: this.generateLocalQueueId(),
      name: name,
      videos: [video],
      createdAt: Date.now(),
    };
    this.localQueues = [...this.localQueues, entry];
    this.syncLocalQueuesToStorage();
  }

  /** Add a video to an existing local playlist (deduplicated by videoId). */
  private addVideoToLocalQueue(queueId: string, video: VideoItem): void {
    this.localQueues = this.localQueues.map((q) => {
      if (q.id !== queueId) {
        return q;
      }
      if (q.videos.some((v) => v.videoId === video.videoId)) {
        return q;
      }
      const updated: StoredLocalQueue = {
        id: q.id,
        name: q.name,
        videos: [...q.videos, video],
        createdAt: q.createdAt,
      };
      return updated;
    });
    this.syncLocalQueuesToStorage();
  }

  /** Remove a video from a local playlist by videoId. */
  private removeVideoFromLocalQueue(queueId: string, videoId: string): void {
    this.localQueues = this.localQueues.map((q) => {
      if (q.id !== queueId) {
        return q;
      }
      const updated: StoredLocalQueue = {
        id: q.id,
        name: q.name,
        videos: q.videos.filter((v) => v.videoId !== videoId),
        createdAt: q.createdAt,
      };
      return updated;
    });
    this.syncLocalQueuesToStorage();
  }

  private loadWatchHistoryFromStorage(): void {
    WatchHistoryStore.loadToAppStorage();
    this.watchHistory = WatchHistoryStore.getAll();
  }

  private bindActionHub(): void {
    this.actionHub.openSearch = () => {
      this.openSearchPage();
    };
    this.actionHub.openVideo = async (video: VideoItem, sourceHint?: PlayQueueSourceHint) => {
      await this.openVideoDetail(video, sourceHint);
    };
    this.actionHub.openChannel = async (channel: SearchChannelItem) => {
      this.openUserPage(channel);
    };
    this.actionHub.openChannelById = async (channelId: string, channelName: string, channelAvatarUrl: string, channelHandle: string) => {
      await this.openChannelById(channelId, channelName, channelAvatarUrl, channelHandle);
    };
    this.actionHub.openPlaylist = (playlist: SearchPlaylistItem) => {
      this.openPlaylistPage(playlist);
    };
    this.actionHub.closePage = () => {
      this.closeCurrentPage();
    };
    this.actionHub.addFavorite = (video: VideoItem) => {
      this.addFavorite(video);
    };
    this.actionHub.removeFavorite = (videoId: string) => {
      this.removeFavorite(videoId);
    };
    this.actionHub.addSubscription = (channel: SearchChannelItem) => {
      this.addSubscription(channel);
    };
    this.actionHub.removeSubscription = (channelId: string) => {
      this.removeSubscription(channelId);
    };
    this.actionHub.addPlaylist = (playlist: SearchPlaylistItem) => {
      this.addPlaylist(playlist);
    };
    this.actionHub.removePlaylist = (playlistId: string) => {
      this.removePlaylist(playlistId);
    };
    this.actionHub.saveCurrentQueueAsLocal = (name: string) => {
      this.saveCurrentQueueAsLocal(name);
    };
    this.actionHub.deleteLocalQueue = (id: string) => {
      this.deleteLocalQueue(id);
    };
    this.actionHub.createLocalQueueWithVideo = (name: string, video: VideoItem) => {
      this.createLocalQueueWithVideo(name, video);
    };
    this.actionHub.addVideoToLocalQueue = (queueId: string, video: VideoItem) => {
      this.addVideoToLocalQueue(queueId, video);
    };
    this.actionHub.removeVideoFromLocalQueue = (queueId: string, videoId: string) => {
      this.removeVideoFromLocalQueue(queueId, videoId);
    };
    this.actionHub.loadLocalQueue = (queueId: string, startVideoId?: string) => {
      const queue = this.localQueues.find(q => q.id === queueId);
      if (queue && queue.videos.length > 0) {
        const startVid = startVideoId
          ? queue.videos.find(v => v.videoId === startVideoId)
          : queue.videos[0];
        if (startVid) {
          const hint: PlayQueueSourceHint = {
            type: 'local',
            playlistId: queue.id,
            playlistName: queue.name,
          };
          this.openVideoDetail(startVid, hint);
        }
      }
    };
    this.actionHub.shareVideo = (video: VideoItem) => {
      this.shareVideo(video);
    };
    this.actionHub.shareChannel = (channel: SearchChannelItem) => {
      this.shareChannel(channel);
    };
    this.actionHub.sharePlaylist = (playlist: SearchPlaylistItem) => {
      this.sharePlaylist(playlist);
    };
    this.actionHub.setSearchLanguage = (languageCode: string) => {
      SearchLocaleManager.setSearchLanguage(languageCode);
      this.reloadHomeForSearchLocaleChange();
    };
    this.actionHub.setSearchCountry = (countryCode: string) => {
      SearchLocaleManager.setSearchCountry(countryCode);
      this.reloadHomeForSearchLocaleChange();
    };
    this.actionHub.setSearchLocale = (languageCode: string, countryCode: string) => {
      SearchLocaleManager.setSearchLocale(languageCode, countryCode);
      this.reloadHomeForSearchLocaleChange();
    };
    this.actionHub.resetSearchLocale = () => {
      SearchLocaleManager.resetSearchLocale();
      this.reloadHomeForSearchLocaleChange();
    };
    this.actionHub.on(ActionHubEvent.IS_REPLIES_OPEN_CHANGE, (isOpen: boolean) => {
      this.isRepliesOpen = isOpen;
    });

  }

  private isSubscribed(channelId: string): boolean {
    const trimmed = (channelId || '').trim();
    if (!trimmed) {
      return false;
    }
    return this.subscriptions.some((item) => item.channelId === trimmed);
  }

  private addSubscription(channel: SearchChannelItem): void {
    const channelId = (channel.channelId || '').trim();
    if (!channelId) {
      return;
    }
    if (this.isSubscribed(channelId)) {
      return;
    }
    const displayName = channel.name && channel.name.length > 0 ? channel.name : channelId;
    this.subscriptions = [...this.subscriptions, new SubscriptionUser(
      channelId,
      displayName,
      channel.avatarUrl || '',
      channel.subscriberText || '',
      channel.videoCountText || '',
      channel.description || '',
      channel.thumbnailColor || ''
    )];
    this.syncSubscriptionsToStorage();
  }

  private removeSubscription(channelId: string): void {
    const trimmed = (channelId || '').trim();
    if (!trimmed) {
      return;
    }
    this.subscriptions = this.subscriptions.filter((item) => item.channelId !== trimmed);
    this.syncSubscriptionsToStorage();
  }

  startNewQuery(query: string) {
    this.homeMode = 'search';
    this.homeModeNoticeMessage = '';
    this.homeErrorMessage = '';
    this.currentQuery = query;
    this.nextPageToken = null;
    this.lastLoadedQuery = '';
    this.kioskNextPageToken = null;
    this.kioskVisitorData = '';
    this.homeFeedSource = 'kiosk';
    this.videoList = [];
    if (!this.currentQuery || this.currentQuery.trim().length === 0) {
      this.currentQuery = this.getRefreshQuery();
    }
    this.loadLiveVideos(true);
  }

  private getRefreshQuery(): string {
    const seeds: string[] = [
      getContext().resourceManager.getStringSync($r('app.string.yt_feed_popular').id),
      getContext().resourceManager.getStringSync($r('app.string.yt_feed_recommended').id),
      getContext().resourceManager.getStringSync($r('app.string.yt_feed_featured').id),
      getContext().resourceManager.getStringSync($r('app.string.yt_feed_trending').id),
      getContext().resourceManager.getStringSync($r('app.string.yt_feed_latest').id),
      getContext().resourceManager.getStringSync($r('app.string.yt_feed_topics').id),
    ];
    const suffixes: string[] = [
      getContext().resourceManager.getStringSync($r('app.string.yt_suffix_videos').id),
      getContext().resourceManager.getStringSync($r('app.string.yt_suffix_shorts').id),
      getContext().resourceManager.getStringSync($r('app.string.yt_suffix_collections').id),
      getContext().resourceManager.getStringSync($r('app.string.yt_suffix_live').id),
      getContext().resourceManager.getStringSync($r('app.string.yt_suffix_music').id),
      getContext().resourceManager.getStringSync($r('app.string.yt_suffix_movies').id),
    ];
    const seed = seeds[Math.floor(Math.random() * seeds.length)];
    const suffix = suffixes[Math.floor(Math.random() * suffixes.length)];
    const stamp = new Date().getMinutes().toString();
    return `${seed}${suffix} ${stamp}`;
  }

  private async fetchInitialWithTimeout(query: string, startId: number, timeoutMs: number): Promise<VideoSearchResult> {
    const service = FeedServiceProvider.getInstance().getSearchService();
    return await Promise.race([
      service.fetchInitial(query, startId),
      new Promise<VideoSearchResult>((_resolve: (value: VideoSearchResult) => void, reject: (reason: Error) => void) => {
        setTimeout(() => {
          reject(new Error('fetchInitial timeout'));
        }, timeoutMs);
      })
    ]);
  }

  private reloadHomeForSearchLocaleChange(): void {
    FeedServiceProvider.getInstance().invalidate();
    this.kioskNextPageToken = null;
    this.kioskVisitorData = '';
    this.homeFeedSource = 'kiosk';
    this.nextPageToken = null;
    this.lastLoadedQuery = '';
    this.homeMode = 'kiosk';
    this.homeModeNoticeMessage = '';
    this.homeErrorMessage = '';
    this.videoList = [];
    if (this.activeTabIndex === 0) {
      this.loadLiveVideos(true);
    }
  }

  private async loadLiveVideos(reset: boolean = false) {
    if (reset) {
      this.isLoadingMore = false;
      this.isInitialLoading = this.videoList.length === 0;
      this.homeErrorMessage = '';
    } else {
      if (this.isLoadingMore) {
        return;
      }
    }

    const startId = reset ? 1 : (this.videoList.length + 1);
    try {
      if (this.homeMode === 'kiosk') {
        if (!reset) {
          if (!this.kioskNextPageToken) {
            return;
          }
          this.isLoadingMore = true;
        }
        const homeService = FeedServiceProvider.getInstance().getHomeFeedService();
        const useAuthContinuation = this.homeFeedSource === 'recommended';
        const feedStyle = UIConfig.normalizeHomeFeedStyle(this.uiConfig.homeFeedStyle);
        const kioskResult = reset
          ? await homeService.fetchHomeKioskInitial(startId, feedStyle)
          : await homeService.fetchHomeKioskNext(
            this.kioskNextPageToken ?? '',
            this.kioskVisitorData,
            startId,
            useAuthContinuation
          );
        if (reset) {
          this.videoList = kioskResult.items;
          this.homeFeedSource = kioskResult.source || 'kiosk';
        } else {
          this.videoList = this.videoList.concat(kioskResult.items);
        }
        this.kioskNextPageToken = kioskResult.nextPageToken;
        if (kioskResult.visitorData && kioskResult.visitorData.length > 0) {
          this.kioskVisitorData = kioskResult.visitorData;
        }
        this.homeErrorMessage = '';
        this.homeModeNoticeMessage = '';
        return;
      }

      const refreshToken = reset ? this.nextPageToken : null;
      const canUseContinuation = reset && !!refreshToken && this.currentQuery === this.lastLoadedQuery;
      if (!reset) {
        if (!this.nextPageToken) {
          return;
        }
        this.isLoadingMore = true;
      }
      if (!this.currentQuery || this.currentQuery.trim().length === 0) {
        this.currentQuery = this.getRefreshQuery();
      }
      const searchService = FeedServiceProvider.getInstance().getSearchService();
      let pageResult = reset
        ? (canUseContinuation
          ? await searchService.fetchNext(refreshToken ?? '', startId)
          : await this.fetchInitialWithTimeout(this.currentQuery, startId, 12000))
        : await searchService.fetchNext(this.nextPageToken ?? '', startId);
      if (reset && canUseContinuation && pageResult.items.length === 0) {
        pageResult = await this.fetchInitialWithTimeout(this.currentQuery, startId, 12000);
      }
      if (reset) {
        this.videoList = pageResult.items;
      } else {
        this.videoList = this.videoList.concat(pageResult.items);
      }
      this.nextPageToken = pageResult.nextPageToken;
      this.lastLoadedQuery = this.currentQuery;
      if (reset && this.homeModeNoticeMessage.length > 0 && pageResult.items.length === 0) {
        this.homeErrorMessage = '[SEARCH_EMPTY] ' + getContext().resourceManager.getStringSync($r('app.string.yt_home_search_empty').id);
      } else {
        this.homeErrorMessage = '';
      }
    } catch (err) {
      logger.error('fetchSearchPage failed:', JSON.stringify(err));
      if (reset && this.homeMode === 'kiosk') {
        const wantedRecommended = UIConfig.normalizeHomeFeedStyle(this.uiConfig.homeFeedStyle) === 'recommended'
          && AuthSessionManager.getInstance()?.isSignedIn() === true;
        const fallbackRes = wantedRecommended
          ? $r('app.string.yt_home_recommended_error')
          : $r('app.string.yt_home_kiosk_error');
        this.homeErrorMessage = this.formatHomeRequestError(
          err as Object,
          getContext().resourceManager.getStringSync(fallbackRes.id)
        );
        if (wantedRecommended) {
          this.homeFeedSource = 'recommended';
        }
      } else {
        this.homeErrorMessage = this.formatHomeRequestError(err as Object, getContext().resourceManager.getStringSync($r('app.string.yt_home_load_error').id));
      }
      // 保留已有列表，避免加载失败时清空
    } finally {
      this.isLoadingMore = false;
      if (reset) {
        this.isInitialLoading = false;
      }
    }
  }

  private formatHomeRequestError(err: Object, fallback: string): string {
    let code = '';
    let message = '';
    if (err && typeof err === 'object') {
      const anyErr = err as Record<string, Object>;
      const errorCode = anyErr['code'];
      const errorMessage = anyErr['message'];
      if (typeof errorCode === 'number' || typeof errorCode === 'string') {
        code = String(errorCode);
      }
      if (typeof errorMessage === 'string') {
        message = errorMessage;
      }
    }
    if (!message || message.length === 0) {
      message = fallback;
    }
    return code.length > 0 ? `[${code}] ${message}` : message;
  }

  private openSearchPage(): void {
    this.showOptions = false;
    this.navPathStack.pushPath({ name: 'SearchPage' });
  }

  private async openVideoDetail(video: VideoItem, sourceHint?: PlayQueueSourceHint, preserveQueue: boolean = false): Promise<void> {
    const queueManager = PlayQueueManager.getInstance();
    logger.info(`openVideoDetail: video=${video.videoId} source=${sourceHint ? sourceHint.type : 'adhoc'} queueType=${queueManager.sourceType}`);

    // 冷启动：从列表/作者页点视频进入播放页时，彻底重置上一次的播放状态，等价于"应用首次播放"，
    // 杜绝关闭 PiP 等残留影响本次。队列内切换走 session.play()、PiP 恢复走 onPipRestore，
    // 均不经此路径，故不受影响。preserveQueue=true 为跨设备续播恢复，保留其会话快照，不冷重置。
    if (!preserveQueue) {
      PiPManager.getInstance().destroy();
      PlayerSession.getInstance().forceReset();
    }

    // If a source hint is provided, pre-load the queue from that source.
    // Fire-and-forget: do NOT await — the player page must open immediately.
    // PlayQueueList will update reactively when the queue loads in the background.
    if (sourceHint && sourceHint.type === 'local') {
      const queue = this.localQueues.find(q => q.id === sourceHint.playlistId);
      if (queue && queue.videos.length > 0) {
        queueManager.setLocalQueue(queue.videos, queue.name, queue.id, video.videoId);
      } else if (queueManager.sourceType !== QueueSourceType.ADHOC
        || queueManager.getCurrent()?.videoId !== video.videoId) {
        queueManager.setAdhocQueue([video], 0);
      }
    } else if (sourceHint && sourceHint.type === 'playlist') {
      if (sourceHint.loadedItems && sourceHint.loadedItems.length > 0) {
        queueManager.setRemotePlaylistSnapshot(
          sourceHint.playlistId,
          sourceHint.loadedItems,
          video.videoId,
          sourceHint.playlistName,
          sourceHint.startIndex ?? -1,
          sourceHint.nextPageToken ?? null,
          sourceHint.visitorData || ''
        );
      } else if (queueManager.sourceType !== QueueSourceType.REMOTE || queueManager.sourceId !== sourceHint.playlistId) {
        logger.info(`openVideoDetail: start remote playlist load playlist=${sourceHint.playlistId} start=${video.videoId}`);
        queueManager.loadFromRemotePlaylist(sourceHint.playlistId, video.videoId, sourceHint.playlistName);
      } else {
        const index = queueManager.queue.findIndex((item) => item.videoId === video.videoId);
        if (index >= 0 && index !== queueManager.currentIndex) {
          queueManager.moveTo(index);
        }
      }
    }

    // External video opens create a fresh generated queue. Queue-internal switches use moveTo().
    if (!sourceHint && !preserveQueue) {
      const currentQueueVideo = queueManager.getCurrent();
      if (queueManager.sourceType !== QueueSourceType.ADHOC || currentQueueVideo?.videoId !== video.videoId) {
        queueManager.setAdhocQueue([video], 0);
      }
    }

    const session = PlayerSession.getInstance();

    this.selectedVideo = video;
    this.showOptions = false;
    AppStorage.setOrCreate('selectedVideo', video);

    const movedIndex = this.navPathStack.moveToTop('PlayerPage');
    if (movedIndex === -1) {
      this.navPathStack.pushPath({ name: 'PlayerPage' });
    } else {
      logger.info('PlayerPage moved to top or already at top, only switching source');
    }
  }

  private consumePendingPlaybackContinuation(): void {
    const raw = this.pendingPlaybackContinuation
      || AppStorage.get<string>(PlaybackContinuationService.APP_STORAGE_PENDING_KEY);
    if (!raw) {
      return;
    }
    this.pendingPlaybackContinuation = '';
    AppStorage.setOrCreate(PlaybackContinuationService.APP_STORAGE_PENDING_KEY, '');
    const payload = PlaybackContinuationService.parsePayload(raw);
    if (!payload) {
      logger.warn('Pending continuation payload is invalid');
      return;
    }
    const restoreRequest = PlaybackContinuationService.toRestoreRequest(payload);
    if (!restoreRequest) {
      logger.warn('Pending continuation restore request is invalid');
      return;
    }
    setTimeout(() => {
      this.restorePlaybackContinuation(restoreRequest);
    }, 0);
  }

  private async restorePlaybackContinuation(request: PlaybackContinuationRestoreRequest): Promise<void> {
    const qm = PlayQueueManager.getInstance();
    qm.restoreSnapshot({
      items: request.queue.items,
      currentIndex: request.queue.currentIndex,
      sourceType: request.queue.sourceType,
      sourceId: request.queue.sourceId,
      sourceName: request.queue.sourceName
    });
    PlayerSession.getInstance().setContinuationRestoreOptions(request.progressSec, request.wasPlaying);
    await this.openVideoDetail(request.video, undefined, true);
    logger.info(`Restored playback continuation video=${request.video.videoId} progress=${request.progressSec}`);
  }

  private async openUserPage(channel: SearchChannelItem): Promise<void> {
    this.showOptions = false;
    this.selectedChannel = channel;
    this.navPathStack.pushPath({ name: 'UserPage' });
  }

  private async openChannelById(channelId: string, channelName: string, channelAvatarUrl: string, channelHandle: string): Promise<void> {
    this.showOptions = false;
    // 只创建基本的频道对象，只填写ID和名称，其他信息由UserPage后期填充
    const channel = new SearchChannelItem(0, channelId, channelName, '', '', channelAvatarUrl, '', '#CCCCCC', channelHandle);

    this.selectedChannel = channel;
    this.navPathStack.pushPath({ name: 'UserPage' });
  }

  private openPlaylistPage(playlist: SearchPlaylistItem): void {
    this.showOptions = false;
    this.selectedPlaylist = playlist;
    this.navPathStack.pushPath({ name: 'PlaylistDetailPage' });
  }

  private closeCurrentPage(): void {
    this.navPathStack.pop();
  }

  private getVideoGridColumnCount(): number {
    const widthPx = this.deviceWidth > 0 ? this.deviceWidth : this.getUIContext().vp2px(360);
    const contentWidth = Math.max(320, this.getUIContext().px2vp(widthPx) - this.GRID_SIDE_PADDING * 2);
    if (contentWidth >= 1440) {
      return 5;
    }
    if (contentWidth >= 1080) {
      return 4;
    }
    if (contentWidth >= 760) {
      return 3;
    }
    if (contentWidth >= 520) {
      return 2;
    }
    return 1;
  }

  private pushOptionsPath(name: string): void {
    this.optionsNavStack.pushPathByName(name, null);
    this.optionsDepth = this.optionsNavStack.size();
  }

  private popOptionsPath(): void {
    this.optionsNavStack.pop();
    this.optionsDepth = Math.max(0, this.optionsDepth - 1);
  }

  private clearOptionsPath(): void {
    this.optionsNavStack.clear();
    this.optionsDepth = 0;
  }

  private addFavorite(video: VideoItem): void {
    const exists = this.favorites.some((item) => item.videoId === video.videoId);
    if (exists) {
      return;
    }
    this.favorites = [...this.favorites, video];
    this.syncFavoritesToStorage();
  }

  private removeFavorite(videoId: string): void {
    this.favorites = this.favorites.filter((item) => item.videoId !== videoId);
    this.syncFavoritesToStorage();
  }

  private addPlaylist(playlist: SearchPlaylistItem): void {
    const playlistId = (playlist.playlistId || '').trim();
    if (!playlistId) {
      return;
    }
    const exists = this.playlists.some((item) => item.playlistId === playlistId);
    if (exists) {
      return;
    }
    const next = new PlaylistItem(
      playlistId,
      playlist.name || playlistId,
      playlist.coverUrl || ''
    );
    this.playlists = [...this.playlists, next];
    this.syncPlaylistsToStorage();
  }

  private removePlaylist(playlistId: string): void {
    const trimmed = (playlistId || '').trim();
    if (!trimmed) {
      return;
    }
    this.playlists = this.playlists.filter((item) => item.playlistId !== trimmed);
    this.syncPlaylistsToStorage();
  }

  private shareVideo(video: VideoItem): void {
    try {
      const videoId = (video.videoId || '').trim();
      const title = video.title || getContext().resourceManager.getStringSync($r('app.string.yt_filter_videos').id);
      const url = videoId ? `https://www.youtube.com/watch?v=${videoId}` : '';
      const content = url ? `${title}\n${url}` : title;
      const data: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.PLAIN_TEXT,
        content
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      const uiContext: UIContext = this.getUIContext();
      const context: common.UIAbilityContext = uiContext.getHostContext() as common.UIAbilityContext;
      controller.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE
      });
    } catch (err) {
      logger.error('share video failed:', JSON.stringify(err));
    }
  }

  private shareChannel(channel: SearchChannelItem): void {
    try {
      const channelId = (channel.channelId || '').trim();
      const name = channel.name || getContext().resourceManager.getStringSync($r('app.string.yt_label_user').id);
      const url = channelId ? `https://www.youtube.com/channel/${channelId}` : '';
      const content = url ? `${name}\n${url}` : name;
      const data: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.PLAIN_TEXT,
        content
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      const uiContext: UIContext = this.getUIContext();
      const context: common.UIAbilityContext = uiContext.getHostContext() as common.UIAbilityContext;
      controller.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE
      });
    } catch (err) {
      logger.error('share channel failed:', JSON.stringify(err));
    }
  }

  private sharePlaylist(playlist: SearchPlaylistItem): void {
    try {
      const playlistId = (playlist.playlistId || '').trim();
      const name = playlist.name || getContext().resourceManager.getStringSync($r('app.string.yt_filter_playlists').id);
      const url = playlistId ? `https://www.youtube.com/playlist?list=${playlistId}` : '';
      const content = url ? `${name}\n${url}` : name;
      const data: systemShare.SharedData = new systemShare.SharedData({
        utd: utd.UniformDataType.PLAIN_TEXT,
        content
      });
      const controller: systemShare.ShareController = new systemShare.ShareController(data);
      const uiContext: UIContext = this.getUIContext();
      const context: common.UIAbilityContext = uiContext.getHostContext() as common.UIAbilityContext;
      controller.show(context, {
        selectionMode: systemShare.SelectionMode.SINGLE
      });
    } catch (err) {
      logger.error('share playlist failed:', JSON.stringify(err));
    }
  }

  private initLanguageSettings(): void {
    const sysLang = LanguageManager.normalizeLanguageCode(i18n.System.getSystemLanguage());
    this.systemLanguageCode = sysLang;
    this.selectedLanguageCode = this.uiConfig.userLanguage || LanguageManager.DEFAULT_LANGUAGE;
    const appliedLanguage = this.selectedLanguageCode === LanguageManager.DEFAULT_LANGUAGE
      ? sysLang
      : this.selectedLanguageCode;
    i18n.System.setAppPreferredLanguage(appliedLanguage);
  }

  private applyLanguageSelection(languageCode: string): void {
    const sysLang = LanguageManager.normalizeLanguageCode(i18n.System.getSystemLanguage());
    this.systemLanguageCode = sysLang;
    this.selectedLanguageCode = languageCode;
    this.updateUiConfig(cfg => { cfg.userLanguage = languageCode; cfg.systemLanguage = sysLang; });
    const appliedLanguage = languageCode === LanguageManager.DEFAULT_LANGUAGE
      ? sysLang
      : languageCode;
    i18n.System.setAppPreferredLanguage(appliedLanguage);
    // 不需要重新构建 pickerItems：
    // 1. 语言名称已使用固定的原生名称，不依赖当前 UI 语言
    // 2. 用户在 LanguagePickerPage 选完返回后，该页面已不在渲染树中
    // 3. setAppPreferredLanguage 触发的 onConfigurationUpdate 不会重复调用此方法
  }



  private getTabLabel(index: number): ResourceStr {
    switch (index) {
      case 0:
        return $r('app.string.yt_tab_home');
      case 1:
        return $r('app.string.yt_tab_subscriptions');
      case 2:
        return $r('app.string.yt_tab_favorites');
      case 3:
        return $r('app.string.yt_tab_local');
      default:
        return $r('app.string.yt_tab_home');
    }
  }

  private switchRootTab(index: number): void {
    this.tabsController.changeIndex(index);
    this.activeTabIndex = index;
  }

  private buildHdsTabsFloatingStyle(): HdsTabsFloatingStyle {
    const base: HdsTabsFloatingStyle = {
      barBottomMargin: this.naviIndicatorHeight > 0 ? this.naviIndicatorHeight :
        $r('sys.float.padding_level8'),
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.IMMERSIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    };
    return base;
  }

  build() {
    HdsNavigation(this.navPathStack) {
      Stack({ alignContent: Alignment.TopStart }) {
        HdsTabs({ controller: this.tabsController }) {
          TabContent() { this.TabContentSection(0) }
            .tabBar(this.TabBarBuilder($r('sys.symbol.house_fill'), $r('app.string.yt_tab_home'), 0))

          TabContent() { this.TabContentSection(1) }
            .tabBar(this.TabBarBuilder($r('sys.symbol.person_2_fill'), $r('app.string.yt_tab_subscriptions'), 1))

          TabContent() { this.TabContentSection(2) }
            .tabBar(this.TabBarBuilder($r('sys.symbol.heart_fill'), $r('app.string.yt_tab_favorites'), 2))

          TabContent() { this.TabContentSection(3) }
            .tabBar(this.TabBarBuilder($r('sys.symbol.folder_fill'), $r('app.string.yt_tab_local'), 3))
        }
        .barPosition(BarPosition.End)
        .vertical(false)
        .scrollable(true)
        .barOverlap(true)
        .blurStrategy(BlurStrategy.ADAPTIVE)
        .barFloatingStyle(this.buildHdsTabsFloatingStyle())
        .width('100%')
        .height('100%')
        .onChange((index: number) => {
          this.getUIContext()?.animateTo({
            duration: 350,
            curve: curves.springMotion(0.4, 0.8)
          }, () => {
            this.activeTabIndex = index;
          });
        })

      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.yourtube_bg_page'))

    }
    .id('mainNavigation')
    .mode(NavigationMode.Stack)
    .navDestination(this.PageMap)
    .titleMode(HdsNavigationTitleMode.MINI)
    .titleBar(buildYourTubeTitleBar({
      title: this.getTabLabel(this.activeTabIndex),
      onBack: () => {
        this.showOptions = true;
      },
      backIcon: $r('sys.symbol.gearshape_fill'),
      backLabel: $r('app.string.yt_option_title'),
      materialEffect: this.immersiveMaterialEffect,
      avoidLayoutSafeArea: true,
      menus: [
        buildTitleMenu($r('sys.symbol.magnifyingglass'), $r('app.string.yt_placeholder_search'), () => {
          this.openSearchPage();
        })
      ]
    }))
    .bindToScrollable([this.homeGridScroller, this.homeListScroller])
    .bindSheet($$this.showOptions, this.OptionsPanel(this.optionsDepth), {
      detents: [SheetSize.LARGE],
      dragBar: false,
      backgroundColor: $r('sys.color.ohos_id_color_dialog_bg'),
      preferType: SheetType.CENTER,
      showClose: false,
      scrollSizeMode: ScrollSizeMode.CONTINUOUS,
      onDisappear: () => {
        this.clearOptionsPath();
      }
    })
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }

  @Builder
  PageMap(name: string) {
    if (name === 'SearchPage') {
      SearchPage()
    } else if (name === 'VideoDetailPage') {
      VideoDetailPage({
        video: this.selectedVideo
      })
    } else if (name === 'PlayerPage') {
      HdsNavDestination() {
        VideoPlayerPage({
          onFullScreenChange: (isFullScreen: boolean) => {
            this.isPlayerFullLandscapeScreen = isFullScreen;
          }
        })
      }
      .hideTitleBar(true)
      .onShown(() => {
        AppStorage.setOrCreate('playerPageVisible', true);
      })
      .onHidden(() => {
        AppStorage.setOrCreate('playerPageVisible', false);
      })
      .onDisAppear(() => {
        this.isRepliesOpen = false;
        this.showOptions = false;
      })
      .onBackPressed(() => {
        if (this.isRepliesOpen) {
          this.actionHub.emit(ActionHubEvent.EXIT_COMMENT_REPLIES);
          return true;
        } else if (this.isPlayerFullLandscapeScreen) {
          this.actionHub.emit(ActionHubEvent.EXIT_FULLSCREEN);
          return true;
        } else {
          const session = PlayerSession.getInstance();
          const pip = PiPManager.getInstance();
          // 返回键进入画中画：pipOnReturn 且设备支持且 PiP 已初始化且未激活且播放器处于可播状态
          const canEnterPiP = this.playbackConfig.pipOnReturn
            && pip.isPiPSupported()
            && pip.isReady
            && !session.isPiPActive
            && (session.playerState === PlayerState.PLAYING
              || session.playerState === PlayerState.PAUSED
              || session.playerState === PlayerState.BUFFERING
              || session.playerState === PlayerState.READY);
          logger.info(`onBackPressed canEnterPiP=${canEnterPiP} | pipOnReturn=${this.playbackConfig.pipOnReturn} supported=${pip.isPiPSupported()} isReady=${pip.isReady} isPiPActive=${session.isPiPActive} state=${session.playerState}`);
          if (canEnterPiP) {
            // 返回 = 弹 PiP：先锁定 PIP 呈现态（视频保持 ON），再 startPiP + pop。
            PlayerPresentation.onPipStarted();
            pip.startPiP().catch((e: Error) => {
              logger.warn(`startPiP on back failed: ${e.message}`);
            });
            this.navPathStack.pop();
            return true;
          }
          session.release();
          this.navPathStack.pop();
          return true;
        }
      })
    } else if (name === 'UserPage') {
      UserPage({
        channel: this.selectedChannel ?? new SearchChannelItem(0, '', 'Unknown', '', '', '', '', '#CCCCCC')
      })
    } else if (name === 'PlaylistDetailPage') {
      PlaylistDetailPage({
        playlist: this.selectedPlaylist ?? new SearchPlaylistItem(0, '', 'Untitled', '', '', '', '', '#CCCCCC')
      })
    }
  }

  @Builder TabContentSection(index: number) {
    if (index === 0) {
      Stack() {
        if (this.homeErrorMessage.length > 0 && this.videoList.length === 0) {
          // 显示完整页面的错误页面
          ErrorPage({
            errorMessage: this.homeErrorMessage,
            onRetry: () => {
              this.loadLiveVideos(true);
            }
          })
        } else {
          Column() {
            if (this.homeModeNoticeMessage.length > 0) {
              Text(this.homeModeNoticeMessage)
                .fontSize(12)
                .fontColor(this.themePrimary)
                .margin({ top: 8, left: 16, right: 16 })
            }

            if (this.uiConfig.homeLayoutMode === 'grid') {
              Scroll(this.homeGridScroller) {
                Column({ space: 12 }) {
                  Column().width('100%').height(this.topSafeHeight + 56)
                  if (this.shouldShowHomeRecommendBanner()) {
                    HomeRecommendSwiper({
                      videos: this.getHomeBannerVideos()
                    })
                  }
                  GridRow({
                    columns: this.getVideoGridColumnCount(),
                    gutter: { x: 8, y: 8 }
                  }) {
                    ForEach(this.getHomeListVideos(), (item: VideoItem) => {
                      GridCol({ span: 1 }) {
                        VideoCardGrid({
                          video: item,
                          actionLabel: $r('app.string.yt_action_favorite'),
                          actionType: 'favorite',
                          useFavoriteToggle: true
                        })
                      }
                      .transition(customAnimationUtil.isScaleTran(item.id.toString(), this.uiConfig))
                    }, (item: VideoItem) => item.id.toString())
                  }
                  .width('100%')
                  Column().width('100%').height(this.bottomSafeHeight + 72)
                }
                .width('100%')
                .padding({ left: 12, right: 12 })
              }
              .width('100%')
              .layoutWeight(1)
              .clip(false)
              .backgroundColor($r('app.color.yourtube_bg_page'))
              .edgeEffect(EdgeEffect.Spring)
              .onReachEnd(() => {
                this.loadLiveVideos(false);
              })
            } else {
              List({ scroller: this.homeListScroller, space: 4 }) {
                if (this.shouldShowHomeRecommendBanner()) {
                  ListItem() {
                    HomeRecommendSwiper({
                      videos: this.getHomeBannerVideos()
                    })
                  }
                  .padding({ left: 12, right: 12, bottom: 8 })
                }
                ForEach(this.getHomeListVideos(), (item: VideoItem) => {
                  ListItem() {
                    VideoCard({
                      video: item,
                      actionLabel: $r('app.string.yt_action_favorite'),
                      actionType: 'favorite',
                      useFavoriteToggle: true
                    })
                  }
                  .padding({ left: 12, right: 12 })
                  .transition(customAnimationUtil.isScaleTran(item.id.toString(), this.uiConfig))
                }, (item: VideoItem) => item.id.toString())
                if (this.isLoadingMore) {
                  ListItem() {
                    Row() {
                      this.LoadingBuilder()
                    }
                    .width('100%')
                    .justifyContent(FlexAlign.Center)
                  }
                }
              }
              .width('100%')
              .layoutWeight(1)
              .clip(false)
              .backgroundColor($r('app.color.yourtube_bg_page'))
              .contentStartOffset(this.topSafeHeight + 56)
              .contentEndOffset(this.bottomSafeHeight + 72)
              .edgeEffect(EdgeEffect.Spring)
              .onReachEnd(() => {
                this.loadLiveVideos(false);
              })
            }
          }
          .width('100%')
          .layoutWeight(1)
        }

        if (this.isInitialLoading) {
          Column() {
            this.LoadingBuilder()
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .backgroundColor($r('app.color.yourtube_bg_overlay'))
        }
      }
    }
    else if (index === 1) {
      SubscriptionManagePage()
    } else if (index === 2) {
      FavoritesPage()
    } else if (index === 3) {
      LocalPage({
        onSwitchOuterTab: (targetIndex: number) => {
          this.switchRootTab(targetIndex);
        }
      })
    }
  }

  @Builder OptionsPanel(depth: number) {
    HdsNavigation(this.optionsNavStack) {
      Column() {
        Row() {
          Rect()
            .width(42)
            .height(4)
            .fill($r('app.color.yourtube_divider'))
            .radius(2)
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .margin({ top: 8, bottom: 6 })

        OptionsMainPage({
            params: {
              clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
              appLangItems: this.appLangItems,
              contentLangItems: this.contentLangItems,
              contentCountryItems: this.contentCountryItems,
              onDataAccountClick: () => { this.pushOptionsPath('data_account'); },
              onLanguageClick: () => { this.pushOptionsPath('language'); },
              onPlaybackClick: () => { this.pushOptionsPath('playback'); },
              onAppearanceClick: () => { this.pushOptionsPath('appearance'); },
              onLogClick: () => { this.pushOptionsPath('log_page'); },
              onRecoveryClick: () => { this.pushOptionsPath('recovery'); },
              onAboutClick: () => { this.pushOptionsPath('about_page'); }
            }
          })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .borderRadius({ topLeft: 20, topRight: 20 })
    }
    .mode(NavigationMode.Stack)
    .navDestination(this.OptionsPageMap)
    .titleMode(HdsNavigationTitleMode.MINI)
    .titleBar(buildSheetTitleBar({
      title: $r('app.string.yt_option_title'),
      onBack: depth > 0 ? () => {
        this.popOptionsPath();
      } : undefined
    }))
    .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
  }



  @Builder
  OptionsPageMap(name: string) {
    if (name === 'language') {
      HdsNavDestination() {
          OptionsLanguageAndRegionPage({
            params: {
              appLangItems: this.appLangItems,
              contentLangItems: this.contentLangItems,
              contentCountryItems: this.contentCountryItems,
              themeColor: this.themePrimary,
              clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
              updateUiConfig: this.updateUiConfig.bind(this),
              reloadHomeForSearchLocaleChange: this.reloadHomeForSearchLocaleChange.bind(this),
              applyLanguageSelection: this.applyLanguageSelection.bind(this)
            }
          })
      }
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .titleBar(buildSheetTitleBar({
        title: $r('app.string.yt_section_language_region'),
        onBack: () => {
          this.popOptionsPath();
        }
      }))
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .onBackPressed(() => {
        this.popOptionsPath();
        return true;
      })
    } else if (name === 'data_account') {
      HdsNavDestination() {
        OptionsDataAccountPage({
          params: {
            onLoginClick: () => { this.pushOptionsPath('webview_login'); },
            updateUiConfig: this.updateUiConfig.bind(this),
            onHomeFeedStyleChanged: () => { this.refreshHomeAfterAuthChange(); },
            onAuthChanged: () => { this.refreshHomeAfterAuthChange(); }
          }
        })
      }
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .titleBar(buildSheetTitleBar({
        title: $r('app.string.yt_option_data_account'),
        onBack: () => {
          this.popOptionsPath();
        }
      }))
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .onBackPressed(() => {
        this.popOptionsPath();
        return true;
      })
    } else if (name === 'google_account') {
      HdsNavDestination() {
        OptionsGoogleAccountPage({
          onBack: () => { this.popOptionsPath(); },
          pushLoginPage: () => { this.pushOptionsPath('webview_login'); },
          onAuthChanged: () => { this.refreshHomeAfterAuthChange(); }
        })
      }
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .titleBar(buildSheetTitleBar({
        title: 'Google 登录',
        onBack: () => {
          this.popOptionsPath();
        }
      }))
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .onBackPressed(() => {
        this.popOptionsPath();
        return true;
      })
    } else if (name === 'webview_login') {
      HdsNavDestination() {
        WebViewLoginPage({
          onSuccess: () => {
            AuthStateHelper.refresh();
            this.refreshHomeAfterAuthChange();
            this.popOptionsPath();
          },
          onCancel: () => { this.popOptionsPath(); },
          onRegisterBackHandler: (handler: () => boolean) => {
            this.webViewLoginBackHandler = handler;
          }
        })
      }
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .titleBar(buildSheetTitleBar({
        title: 'YouTube 登录',
        onBack: () => {
          if (this.webViewLoginBackHandler && this.webViewLoginBackHandler()) {
            return;
          }
          this.webViewLoginBackHandler = null;
          this.popOptionsPath();
        }
      }))
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .onBackPressed(() => {
        if (this.webViewLoginBackHandler && this.webViewLoginBackHandler()) {
          return true;
        }
        this.webViewLoginBackHandler = null;
        this.popOptionsPath();
        return true;
      })
    } else if (name === 'appearance') {
      HdsNavDestination() {
          OptionsAppearancePage({
            params: {
              themeColor: this.themePrimary,
              applyDarkModeSelection: this.applyDarkModeSelection.bind(this),
              updateUiConfig: this.updateUiConfig.bind(this)
            }
          })
      }
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .titleBar(buildSheetTitleBar({
        title: $r('app.string.yt_option_appearance'),
        onBack: () => {
          this.popOptionsPath();
        }
      }))
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .onBackPressed(() => {
        this.popOptionsPath();
        return true;
      })
    } else if (name === 'app_lang') {
      LanguagePickerPage({
        title: $r('app.string.yt_setting_ui_language'),
        items: this.appLangItems,
        selectedCode: this.uiConfig.userLanguage,
        onSelect: (code: string) => { this.applyLanguageSelection(code); },
        onBack: () => { this.popOptionsPath(); }
      })
    } else if (name === 'content_lang') {
      LanguagePickerPage({
        title: $r('app.string.yt_setting_content_language'),
        items: this.contentLangItems,
        selectedCode: this.uiConfig.searchLanguage,
        onSelect: (code: string) => {
          this.updateUiConfig(cfg => cfg.searchLanguage = code === 'default' ? 'default' : code);
          this.reloadHomeForSearchLocaleChange();
        },
        onBack: () => { this.popOptionsPath(); }
      })
    } else if (name === 'content_country') {
      LanguagePickerPage({
        title: $r('app.string.yt_setting_content_region'),
        items: this.contentCountryItems,
        selectedCode: this.uiConfig.searchCountry,
        onSelect: (code: string) => {
          this.updateUiConfig(cfg => cfg.searchCountry = code === 'default' ? 'default' : code.toUpperCase());
          this.reloadHomeForSearchLocaleChange();
        },
        onBack: () => { this.popOptionsPath(); }
      })
    } else if (name === 'log_page') {
      HdsNavDestination() {
        LogPage({
          onBack: () => { this.popOptionsPath(); }
        })
      }
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .titleBar(buildSheetTitleBar({
        title: $r('app.string.yt_log_title'),
        onBack: () => {
          this.popOptionsPath();
        }
      }))
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .onBackPressed(() => {
        this.popOptionsPath();
        return true;
      })
    } else if (name === 'about_page') {
      HdsNavDestination() {
        AboutPage({
          onBack: () => { this.popOptionsPath(); }
        })
      }
      .hideTitleBar(true)
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .onBackPressed(() => {
        this.popOptionsPath();
        return true;
      })
    } else if (name === 'playback') {
      HdsNavDestination() {
          OptionsPlaybackPage({
            params: {
              themeColor: this.themePrimary,
              updatePlaybackConfig: this.updatePlaybackConfig.bind(this),
              updateUiConfig: this.updateUiConfig.bind(this),
              getQualityDisplay: this.getQualityDisplay.bind(this)
            }
          })
      }
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .titleBar(buildSheetTitleBar({
        title: $r('app.string.yt_section_playback'),
        onBack: () => {
          this.popOptionsPath();
        }
      }))
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .onBackPressed(() => {
        this.popOptionsPath();
        return true;
      })
    } else if (name === 'recovery') {
      HdsNavDestination() {
          OptionsRecoveryPage({
            params: {
              onResetSettingsClick: () => { this.showResetSettingsConfirmDialog(); },
              onClearAllDataClick: () => { this.showClearAllDataConfirmDialog(); }
            }
          })
      }
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .titleBar(buildSheetTitleBar({
        title: $r('app.string.yt_option_recovery'),
        onBack: () => {
          this.popOptionsPath();
        }
      }))
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .onBackPressed(() => {
        this.popOptionsPath();
        return true;
      })
    }
  }

  private applyDarkModeSelection(mode: YourtubeDarkMode): void {
    this.updateUiConfig(cfg => cfg.darkMode = mode);

    // 延迟设置颜色模式，避免干扰 Select 组件的当前帧更新
    Promise.resolve().then(() => {
      const colorMode = ColorModeManager.resolveMode(mode);
      AppStorage.setOrCreate('currentColorMode', colorMode);
      const uiContext = this.getUIContext();
      const hostContext = uiContext?.getHostContext() as common.UIAbilityContext;
      if (hostContext) {
        hostContext.getApplicationContext().setColorMode(colorMode);
      }
    });
  }

  @Builder TabBarBuilder(iconRes: Resource, label: ResourceStr, index: number) {
    Column({ space: 3 }) {
      SymbolGlyph(iconRes)
        .fontSize(this.activeTabIndex === index ? 23 : 21)
        .fontColor([this.activeTabIndex === index ? this.themePrimary : $r('app.color.yourtube_text_primary')])
        .symbolEffect(customAnimationUtil.isIconEffect(this.uiConfig), this.activeTabIndex === index)

      Text(label)
        .fontSize(10)
        .fontColor(this.activeTabIndex === index ? this.themePrimary : $r('app.color.yourtube_text_primary'))
        .fontWeight(this.activeTabIndex === index ? FontWeight.Bold : FontWeight.Medium)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width(70)
    .height(54)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(18)
    .backgroundColor(Color.Transparent)
    .scale({ x: this.activeTabIndex === index ? 1.0 : 0.94, y: this.activeTabIndex === index ? 1.0 : 0.94 })
  }

  @Builder LoadingBuilder() {
    LoadingProgress()
      .color(this.themePrimary)
      .width(40)
      .height(40)
      .margin({ bottom: 15 })
  }

  private homeBannerMax: number = 6;

  private shouldShowHomeRecommendBanner(): boolean {
    return this.homeMode === 'kiosk'
      && this.homeFeedSource === 'recommended'
      && this.videoList.length > 0;
  }

  private getHomeBannerVideos(): VideoItem[] {
    if (!this.shouldShowHomeRecommendBanner()) {
      return [];
    }
    const limit = Math.min(this.homeBannerMax, this.videoList.length);
    return this.videoList.slice(0, limit);
  }

  private getHomeListVideos(): VideoItem[] {
    if (!this.shouldShowHomeRecommendBanner()) {
      return this.videoList;
    }
    const bannerIds: string[] = [];
    const banners = this.getHomeBannerVideos();
    for (let i = 0; i < banners.length; i++) {
      const id = (banners[i].videoId || banners[i].id.toString()).trim();
      if (id.length > 0) {
        bannerIds.push(id);
      }
    }
    return this.videoList.filter((item: VideoItem) => {
      const id = (item.videoId || item.id.toString()).trim();
      return bannerIds.indexOf(id) < 0;
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // 播放设置页面辅助方法
  // ─────────────────────────────────────────────────────────────────────────

  private resourceToString(res: ResourceStr): string {
    if (typeof res === 'string') return res;
    try {
      return getContext().resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  private getQualityDisplay(quality: VideoQualityCap): ResourceStr {
    switch (quality) {
      case 'best': return $r('app.string.yt_quality_best');
      default: return quality;
    }
  }



  private savePlaybackConfig(next: PlaybackConfig): void {
    this.playbackConfig = next;
    PlaybackConfig.saveToPreferences(next);
  }

  private showResetSettingsConfirmDialog(): void {
    const uiContext: UIContext = this.getUIContext();
    uiContext.showAlertDialog({
      title: $r('app.string.yt_option_reset_settings'),
      message: $r('app.string.yt_confirm_reset_settings'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      offset: { dx: 0, dy: -20 },
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.yt_action_cancel'),
          action: () => {}
        },
        {
          value: $r('app.string.yt_action_confirm'),
          action: () => {
            this.resetAllConfigs();
          }
        }
      ],
      cancel: () => {},
      onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
        if (dismissDialogAction.reason === DismissReason.PRESS_BACK) {
          dismissDialogAction.dismiss();
        }
        if (dismissDialogAction.reason === DismissReason.TOUCH_OUTSIDE) {
          dismissDialogAction.dismiss();
        }
      }
    });
  }

  private showClearAllDataConfirmDialog(): void {
    const uiContext: UIContext = this.getUIContext();
    uiContext.showAlertDialog({
      title: $r('app.string.yt_option_clear_all_data'),
      message: $r('app.string.yt_confirm_clear_all_data'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      offset: { dx: 0, dy: -20 },
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.yt_action_cancel'),
          action: () => {}
        },
        {
          value: $r('app.string.yt_action_clear'),
          fontColor: $r('app.color.yourtube_text_warning'),
          action: () => {
            this.clearAllAppData();
            try {
              uiContext.getPromptAction().showToast({
                message: $r('app.string.yt_toast_clear_all_data_done'),
                duration: 1500
              });
            } catch (err) {
              const error: BusinessError = err as BusinessError;
              logger.error(`Show toast error: ${error.message}`);
            }
          }
        }
      ],
      cancel: () => {},
      onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
        if (dismissDialogAction.reason === DismissReason.PRESS_BACK) {
          dismissDialogAction.dismiss();
        }
        if (dismissDialogAction.reason === DismissReason.TOUCH_OUTSIDE) {
          dismissDialogAction.dismiss();
        }
      }
    });
  }

}
