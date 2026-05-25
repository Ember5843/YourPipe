import { AppLog } from './AppLog';
import { PreferencesStore } from './PreferencesStore';
import { PlaybackConfig } from './PlaybackConfig';

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
  colorPreset: string = 'default';
  isVibrate: boolean = true;
  isAnimation: boolean = true;
  animationSpeed: number = 300;
  enableLogger: boolean = false;
  homeLayoutMode: string = 'grid';
  constructor() {
  }

  clone(): UIConfig {
    const next = new UIConfig();
    next.darkMode = this.darkMode;
    next.userLanguage = this.userLanguage;
    next.systemLanguage = this.systemLanguage;
    next.searchLanguage = this.searchLanguage;
    next.searchCountry = this.searchCountry;
    next.colorPreset = this.colorPreset;
    next.isVibrate = this.isVibrate;
    next.isAnimation = this.isAnimation;
    next.animationSpeed = this.animationSpeed;
    next.enableLogger = this.enableLogger;
    next.homeLayoutMode = this.homeLayoutMode;
    return next;
  }

  /** 从 PreferencesStore 加载持久化的字段 */
  static loadFromPreferences(): UIConfig {
    const config = new UIConfig();
    config.darkMode = PreferencesStore.getString('cfg_darkMode', YourtubeDarkMode.SYSTEM) as YourtubeDarkMode;
    config.userLanguage = PreferencesStore.getString('cfg_userLanguage', 'default');
    config.searchLanguage = PreferencesStore.getString('cfg_searchLanguage', 'default');
    config.searchCountry = PreferencesStore.getString('cfg_searchCountry', 'default');
    config.colorPreset = PreferencesStore.getString('cfg_colorPreset', 'default');
    config.enableLogger = PreferencesStore.getString('cfg_enableLogger', 'false') === 'true';
    config.homeLayoutMode = PreferencesStore.getString('cfg_homeLayoutMode', 'grid');
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
    PreferencesStore.setString('cfg_colorPreset', config.colorPreset);
    PreferencesStore.setString('cfg_enableLogger', config.enableLogger ? 'true' : 'false');
    PreferencesStore.setString('cfg_homeLayoutMode', config.homeLayoutMode);
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
  }
}
