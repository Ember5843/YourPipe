import { AppLog } from './AppLog';
import { PreferencesStore } from './PreferencesStore';
import { PlaybackConfig } from './PlaybackConfig';
import { NetworkProxyConfig } from './NetworkProxyConfig';
import { ThemeManager } from './ThemeManager';

const logger = AppLog.getInstance('Persistence');

export enum YourtubeDarkMode {
  SYSTEM = 'system',
  LIGHT = 'light',
  DARK = 'dark'
}

export class UIConfig {
  darkMode: YourtubeDarkMode = YourtubeDarkMode.SYSTEM;
  userLanguage: string = 'default';
  systemLanguage: string = 'en-Latn';
  searchLanguage: string = 'default';
  searchCountry: string = 'default';
  /** Comment translation target: 'default' follows the app UI language. */
  translationLanguage: string = 'default';
  /** tlang 自动翻译字幕目标语言：'default' 跟随翻译语言设置（translationLanguage）。 */
  subtitleTranslateLanguage: string = 'default';
  colorPreset: string = 'default';
  isVibrate: boolean = true;
  isAnimation: boolean = true;
  animationSpeed: number = 300;
  enableLogger: boolean = false;
  homeLayoutMode: string = 'list';
  /** 网格卡片密度：'compact'(+1 列) | 'auto'(随宽度阈值) | 'cozy'(-1 列)。 */
  homeGridDensity: string = 'auto';
  /** After login: 'recommended' | 'kiosk'. Signed-out always uses kiosk. */
  homeFeedStyle: string = 'recommended';
  /** When signed in: pull cloud history + subscription list on app launch (one-way). */
  syncUserLibraryOnLaunch: boolean = true;
  maxConcurrentDownloads: number = 1;
  constructor() {
  }

  clone(): UIConfig {
    const next = new UIConfig();
    next.darkMode = this.darkMode;
    next.userLanguage = this.userLanguage;
    next.systemLanguage = this.systemLanguage;
    next.searchLanguage = this.searchLanguage;
    next.searchCountry = this.searchCountry;
    next.translationLanguage = this.translationLanguage;
    next.subtitleTranslateLanguage = this.subtitleTranslateLanguage;
    next.colorPreset = this.colorPreset;
    next.isVibrate = this.isVibrate;
    next.isAnimation = this.isAnimation;
    next.animationSpeed = this.animationSpeed;
    next.enableLogger = this.enableLogger;
    next.homeLayoutMode = this.homeLayoutMode;
    next.homeGridDensity = this.homeGridDensity;
    next.homeFeedStyle = this.homeFeedStyle;
    next.syncUserLibraryOnLaunch = this.syncUserLibraryOnLaunch;
    next.maxConcurrentDownloads = this.maxConcurrentDownloads;
    return next;
  }

  static normalizeHomeFeedStyle(value: string): string {
    if (value === 'kiosk') {
      return 'kiosk';
    }
    return 'recommended';
  }

  static normalizeHomeGridDensity(value: string): string {
    if (value === 'compact' || value === 'cozy') {
      return value;
    }
    return 'auto';
  }

  /** 密度档位 → 网格列数偏移（getVideoGridColumnCount 的第二参数）。 */
  static gridDensityOffset(density: string): number {
    if (density === 'compact') {
      return 1;
    }
    if (density === 'cozy') {
      return -1;
    }
    return 0;
  }

  /** 从 PreferencesStore 加载持久化的字段 */
  static loadFromPreferences(): UIConfig {
    const config = new UIConfig();
    config.darkMode = PreferencesStore.getString('cfg_darkMode', YourtubeDarkMode.SYSTEM) as YourtubeDarkMode;
    config.userLanguage = PreferencesStore.getString('cfg_userLanguage', 'default');
    config.searchLanguage = PreferencesStore.getString('cfg_searchLanguage', 'default');
    config.searchCountry = PreferencesStore.getString('cfg_searchCountry', 'default');
    config.translationLanguage = PreferencesStore.getString('cfg_translationLanguage', 'default');
    config.subtitleTranslateLanguage = PreferencesStore.getString('cfg_subtitleTranslateLanguage', 'default');
    config.colorPreset = PreferencesStore.getString('cfg_colorPreset', 'default');
    config.enableLogger = PreferencesStore.getString('cfg_enableLogger', 'false') === 'true';
    config.homeLayoutMode = PreferencesStore.getString('cfg_homeLayoutMode', 'list');
    config.homeGridDensity = UIConfig.normalizeHomeGridDensity(
      PreferencesStore.getString('cfg_homeGridDensity', 'auto')
    );
    config.homeFeedStyle = UIConfig.normalizeHomeFeedStyle(
      PreferencesStore.getString('cfg_homeFeedStyle', 'recommended')
    );
    config.syncUserLibraryOnLaunch =
      PreferencesStore.getString('cfg_syncUserLibraryOnLaunch', 'true') !== 'false';
    const maxConcurrentDownloads = parseInt(PreferencesStore.getString('cfg_maxConcurrentDownloads', '1'), 10);
    config.maxConcurrentDownloads = Number.isFinite(maxConcurrentDownloads)
      ? Math.max(1, Math.min(4, maxConcurrentDownloads))
      : 1;
    logger.info(`Loaded UIConfig from Preferences: ${JSON.stringify(config)}`);
    return config;
  }

  /** 将需要持久化的字段写入 PreferencesStore */
  static saveToPreferences(config: UIConfig): void {
    logger.info(`Saving UIConfig to Preferences: ${JSON.stringify(config)}`);
    PreferencesStore.setString('cfg_darkMode', config.darkMode);
    PreferencesStore.setString('cfg_userLanguage', config.userLanguage);
    PreferencesStore.setString('cfg_searchLanguage', config.searchLanguage);
    PreferencesStore.setString('cfg_searchCountry', config.searchCountry);
    PreferencesStore.setString('cfg_translationLanguage', config.translationLanguage);
    PreferencesStore.setString('cfg_subtitleTranslateLanguage', config.subtitleTranslateLanguage);
    PreferencesStore.setString('cfg_colorPreset', config.colorPreset);
    PreferencesStore.setString('cfg_enableLogger', config.enableLogger ? 'true' : 'false');
    PreferencesStore.setString('cfg_homeLayoutMode', config.homeLayoutMode);
    PreferencesStore.setString('cfg_homeGridDensity', UIConfig.normalizeHomeGridDensity(config.homeGridDensity));
    PreferencesStore.setString('cfg_homeFeedStyle', UIConfig.normalizeHomeFeedStyle(config.homeFeedStyle));
    PreferencesStore.setString(
      'cfg_syncUserLibraryOnLaunch',
      config.syncUserLibraryOnLaunch !== false ? 'true' : 'false'
    );
    PreferencesStore.setString('cfg_maxConcurrentDownloads', `${Math.max(1, Math.min(4, Math.round(config.maxConcurrentDownloads || 1)))}`);
  }
}

@Observed
export class AppState {
  static init(): void {
    // 先从 Preferences 加载（如果 PreferencesStore 已经初始化）
    const config = UIConfig.loadFromPreferences();
    AppStorage.setOrCreate('uiConfig', config);
    // 初始化播放设置
    const playbackConfig = PlaybackConfig.loadFromPreferences();
    AppStorage.setOrCreate('playbackConfig', playbackConfig);
    // 会话级队列自动播放开关，每次启动用设置中的默认值初始化
    AppStorage.setOrCreate('autoPlayQueue', playbackConfig.autoPlayNext);
    const networkProxyConfig = NetworkProxyConfig.load();
    AppStorage.setOrCreate('networkProxyConfig', networkProxyConfig);
    // socks5 模式需等 loopback 桥异步 listen 完成；promise 由 NetworkProxyConfig 内部保存，
    // 首页加载等首个网络动作经 NetworkProxyConfig.awaitReady() 等待，避免启动窗口内静默直连。
    NetworkProxyConfig.applySystemAndProviders(networkProxyConfig)
      .catch((e: Error) => logger.warn(`apply proxy at init failed: ${e.message}`));
    ThemeManager.initFromConfig(config.colorPreset);
  }
}
