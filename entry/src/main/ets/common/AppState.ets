import { AppLog } from './AppLog';
import { PreferencesStore } from './PreferencesStore';
import { ExperimentalConfig } from './experimental/ExperimentalConfig';
import { PlaybackConfig } from './PlaybackConfig';
import { NetworkProxyConfig } from './NetworkProxyConfig';
import { ThemeManager } from './ThemeManager';

const logger = AppLog.getInstance('Persistence');

export enum YourtubeDarkMode {
  SYSTEM = 'system',
  LIGHT = 'light',
  DARK = 'dark'
}

@Observed
export class UIConfig {
  @Track darkMode: YourtubeDarkMode = YourtubeDarkMode.SYSTEM;
  @Track userLanguage: string = 'default';
  @Track systemLanguage: string = 'en-Latn';
  @Track searchLanguage: string = 'default';
  @Track searchCountry: string = 'default';
  /** Comment translation target: 'default' follows the app UI language. */
  @Track translationLanguage: string = 'default';
  /** tlang 自动翻译字幕目标语言：'default' 跟随翻译语言设置（translationLanguage）。 */
  @Track subtitleTranslateLanguage: string = 'default';
  @Track colorPreset: string = 'default';
  @Track isVibrate: boolean = true;
  @Track isAnimation: boolean = true;
  @Track animationSpeed: number = 300;
  @Track enableLogger: boolean = false;
  @Track homeLayoutMode: string = 'list';
  /** 网格卡片密度：'compact'(+1 列) | 'auto'(随宽度阈值) | 'cozy'(-1 列)。 */
  @Track homeGridDensity: string = 'auto';
  /** After login: 'recommended' | 'kiosk'. Signed-out always uses kiosk. */
  @Track homeFeedStyle: string = 'recommended';
  /** When signed in: pull cloud history + subscription list on app launch (one-way). */
  @Track syncUserLibraryOnLaunch: boolean = true;
  @Track maxConcurrentDownloads: number = 1;
  /**
   * Download task wall-clock budget in minutes. 0 = no timeout.
   * A task that exceeds it is failed so a stuck transfer cannot hold a
   * concurrency slot forever.
   */
  @Track downloadTimeoutMinutes: number = 30;
  /**
   * 暂停时画面中央的大播放按钮。关掉后只靠"点画面"切换播放/暂停，
   * 画面中央保持干净（适合已经习惯点按操作的用户）。
   */
  @Track showCenterPlayButton: boolean = true;
  /** 主页 Shorts 悬浮球开关（默认开）。**全屏 Shorts 模式已停用**（代码保留，
   *  入口改为首页的长/短视频切换），此开关随入口一起停用。 */
  @Track shortsBallEnabled: boolean = true;
  /** 悬浮球位置（归一化 0..1，按内容区左上角计）；-1 = 使用默认左下位置。 */
  @Track shortsBallX: number = -1;
  @Track shortsBallY: number = -1;
  /**
   * 首页信息流维度：'long' 只显示长视频，'short' 只显示短视频。
   * 首页同时维护两个列表（同一份 feed 按 isShort 拆开），切换只换显示的列表，
   * 不重新请求。
   */
  @Track homeFeedMode: string = 'long';
  constructor() {
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
    config.isAnimation = PreferencesStore.getString('cfg_isAnimation', 'true') !== 'false';
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
    const downloadTimeoutMinutes = parseInt(PreferencesStore.getString('cfg_downloadTimeoutMinutes', '30'), 10);
    config.downloadTimeoutMinutes = Number.isFinite(downloadTimeoutMinutes)
      ? Math.max(0, Math.min(240, downloadTimeoutMinutes))
      : 30;
    config.showCenterPlayButton =
      PreferencesStore.getString('cfg_showCenterPlayButton', 'true') !== 'false';
    config.shortsBallEnabled =
      PreferencesStore.getString('cfg_shortsBallEnabled', 'true') !== 'false';
    config.shortsBallX = UIConfig.parseNormalizedCoord(
      PreferencesStore.getString('cfg_shortsBallX', '-1'), -1);
    config.shortsBallY = UIConfig.parseNormalizedCoord(
      PreferencesStore.getString('cfg_shortsBallY', '-1'), -1);
    config.homeFeedMode = UIConfig.normalizeHomeFeedMode(
      PreferencesStore.getString('cfg_homeFeedMode', 'long'));
    logger.info(`Loaded UIConfig from Preferences: ${JSON.stringify(config)}`);
    return config;
  }

  /** 归一化球坐标：非法/缺失回退到 fallback（-1 = 默认位置）。 */
  static parseNormalizedCoord(raw: string, fallback: number): number {
    const value = parseFloat(raw);
    if (!Number.isFinite(value) || value < 0 || value > 1) {
      return fallback;
    }
    return value;
  }

  /** 首页维度：'long' | 'short'，非法值回退 'long'。 */
  static normalizeHomeFeedMode(value: string): string {
    return value === 'short' ? 'short' : 'long';
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
    PreferencesStore.setString('cfg_isAnimation', config.isAnimation !== false ? 'true' : 'false');
    PreferencesStore.setString('cfg_homeLayoutMode', config.homeLayoutMode);
    PreferencesStore.setString('cfg_homeGridDensity', UIConfig.normalizeHomeGridDensity(config.homeGridDensity));
    PreferencesStore.setString('cfg_homeFeedStyle', UIConfig.normalizeHomeFeedStyle(config.homeFeedStyle));
    PreferencesStore.setString(
      'cfg_syncUserLibraryOnLaunch',
      config.syncUserLibraryOnLaunch !== false ? 'true' : 'false'
    );
    PreferencesStore.setString('cfg_maxConcurrentDownloads', `${Math.max(1, Math.min(4, Math.round(config.maxConcurrentDownloads || 1)))}`);
    PreferencesStore.setString('cfg_downloadTimeoutMinutes', `${Math.max(0, Math.min(240, Math.round(config.downloadTimeoutMinutes ?? 30)))}`);
    PreferencesStore.setString('cfg_showCenterPlayButton', config.showCenterPlayButton !== false ? 'true' : 'false');
    PreferencesStore.setString('cfg_shortsBallEnabled', config.shortsBallEnabled !== false ? 'true' : 'false');
    PreferencesStore.setString('cfg_shortsBallX',
      Number.isFinite(config.shortsBallX) && config.shortsBallX >= 0 ? `${config.shortsBallX}` : '-1');
    PreferencesStore.setString('cfg_shortsBallY',
      Number.isFinite(config.shortsBallY) && config.shortsBallY >= 0 ? `${config.shortsBallY}` : '-1');
    PreferencesStore.setString('cfg_homeFeedMode', UIConfig.normalizeHomeFeedMode(config.homeFeedMode));
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
    // 实验性功能（内置插件）配置
    const experimentalConfig = ExperimentalConfig.loadFromPreferences();
    AppStorage.setOrCreate('experimentalConfig', experimentalConfig);
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
