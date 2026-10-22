import { AppLog } from '../AppLog';
import { PreferencesStore } from '../PreferencesStore';

const logger = AppLog.getInstance('ExperimentalConfig');

/** 单个 JSON 键：整份配置一起落盘，cfg_ 前缀会自动进入设置备份。 */
const PREF_KEY: string = 'cfg_experimental_json';

export const EXP_CATEGORY_SPONSOR: string = 'sponsor';
export const EXP_CATEGORY_SELF_PROMO: string = 'selfpromo';
export const EXP_CATEGORY_INTERACTION: string = 'interaction';
export const EXP_CATEGORY_INTRO: string = 'intro';
export const EXP_CATEGORY_OUTRO: string = 'outro';
export const EXP_CATEGORY_PREVIEW: string = 'preview';
export const EXP_CATEGORY_MUSIC_OFF_TOPIC: string = 'music_offtopic';
export const EXP_CATEGORY_FILLER: string = 'filler';
export const EXP_CATEGORY_HIGHLIGHT: string = 'poi_highlight';

/** 顺序即设置页展示顺序。 */
export const EXP_SPONSOR_CATEGORIES: string[] = [
  EXP_CATEGORY_SPONSOR,
  EXP_CATEGORY_SELF_PROMO,
  EXP_CATEGORY_INTERACTION,
  EXP_CATEGORY_INTRO,
  EXP_CATEGORY_OUTRO,
  EXP_CATEGORY_PREVIEW,
  EXP_CATEGORY_MUSIC_OFF_TOPIC,
  EXP_CATEGORY_FILLER,
  EXP_CATEGORY_HIGHLIGHT
];

const DEFAULT_CATEGORIES: string = `${EXP_CATEGORY_SPONSOR},${EXP_CATEGORY_SELF_PROMO}`;
const DEFAULT_SERVER: string = 'https://sponsor.ajay.app';

export const EXP_SB_BEHAVIOR_TOAST: string = 'toast';
export const EXP_SB_BEHAVIOR_SILENT: string = 'silent';
export const EXP_SB_BEHAVIOR_MANUAL: string = 'manual';
export const EXP_SB_BEHAVIORS: string[] = [
  EXP_SB_BEHAVIOR_TOAST,
  EXP_SB_BEHAVIOR_SILENT,
  EXP_SB_BEHAVIOR_MANUAL
];

export const EXP_UNSKIP_SECONDS_VALUES: number[] = [3, 5, 10];
export const EXP_DEARROW_LIMIT_VALUES: number[] = [10, 20, 40];
export const EXP_DEARROW_CONCURRENCY_VALUES: number[] = [2, 4, 6];
export const EXP_AILIST_SYNC_DAYS_VALUES: number[] = [1, 7, 0];
export const EXP_AILIST_MODE_MARK: string = 'mark';
export const EXP_AILIST_MODE_HIDE: string = 'hide';

interface ExperimentalConfigData {
  sponsorBlockEnabled?: boolean;
  sponsorCategories?: string;
  sponsorBehavior?: string;
  sponsorUnskipSeconds?: number;
  sponsorPrivacyMode?: boolean;
  sponsorServer?: string;
  sponsorWhitelist?: string;
  deArrowEnabled?: boolean;
  deArrowTitles?: boolean;
  deArrowThumbnails?: boolean;
  deArrowLimit?: number;
  deArrowConcurrency?: number;
  aiListEnabled?: boolean;
  aiListMode?: string;
  aiListWarnList?: boolean;
  aiListSyncDays?: number;
  aiListLastSyncMs?: number;
}

/**
 * 实验性功能配置。与 UIConfig / PlaybackConfig 一样是 @Observed 响应式对象，
 * 放在 AppStorage('experimentalConfig')，修改必须**就地改字段**再落盘（不要 clone）。
 */
@Observed
export class ExperimentalConfig {
  @Track sponsorBlockEnabled: boolean = false;
  /** 逗号分隔的类别名，避免 ArkTS 集合序列化问题。 */
  @Track sponsorCategories: string = DEFAULT_CATEGORIES;
  @Track sponsorBehavior: string = EXP_SB_BEHAVIOR_TOAST;
  @Track sponsorUnskipSeconds: number = 5;
  @Track sponsorPrivacyMode: boolean = true;
  @Track sponsorServer: string = DEFAULT_SERVER;
  /** 逗号分隔的 channelId 白名单。 */
  @Track sponsorWhitelist: string = '';

  @Track deArrowEnabled: boolean = false;
  @Track deArrowTitles: boolean = true;
  @Track deArrowThumbnails: boolean = false;
  @Track deArrowLimit: number = 20;
  @Track deArrowConcurrency: number = 4;

  @Track aiListEnabled: boolean = false;
  @Track aiListMode: string = EXP_AILIST_MODE_MARK;
  @Track aiListWarnList: boolean = true;
  /** 0 = 仅手动。 */
  @Track aiListSyncDays: number = 1;
  @Track aiListLastSyncMs: number = 0;

  static loadFromPreferences(): ExperimentalConfig {
    const config = new ExperimentalConfig();
    const raw = PreferencesStore.getString(PREF_KEY, '');
    if (raw.length === 0) {
      return config;
    }
    try {
      const data = JSON.parse(raw) as ExperimentalConfigData;
      config.sponsorBlockEnabled = data.sponsorBlockEnabled === true;
      config.sponsorCategories = ExperimentalConfig.normalizeCategories(data.sponsorCategories);
      config.sponsorBehavior = ExperimentalConfig.normalizeBehavior(data.sponsorBehavior);
      config.sponsorUnskipSeconds = ExperimentalConfig.normalizeNumber(data.sponsorUnskipSeconds, EXP_UNSKIP_SECONDS_VALUES, 5);
      config.sponsorPrivacyMode = data.sponsorPrivacyMode !== false;
      const server = (data.sponsorServer || '').trim();
      config.sponsorServer = server.length > 0 ? server : DEFAULT_SERVER;
      config.sponsorWhitelist = (data.sponsorWhitelist || '').trim();
      config.deArrowEnabled = data.deArrowEnabled === true;
      config.deArrowTitles = data.deArrowTitles !== false;
      config.deArrowThumbnails = data.deArrowThumbnails === true;
      config.deArrowLimit = ExperimentalConfig.normalizeNumber(data.deArrowLimit, EXP_DEARROW_LIMIT_VALUES, 20);
      config.deArrowConcurrency = ExperimentalConfig.normalizeNumber(data.deArrowConcurrency, EXP_DEARROW_CONCURRENCY_VALUES, 4);
      config.aiListEnabled = data.aiListEnabled === true;
      config.aiListMode = data.aiListMode === EXP_AILIST_MODE_HIDE ? EXP_AILIST_MODE_HIDE : EXP_AILIST_MODE_MARK;
      config.aiListWarnList = data.aiListWarnList !== false;
      config.aiListSyncDays = ExperimentalConfig.normalizeNumber(data.aiListSyncDays, EXP_AILIST_SYNC_DAYS_VALUES, 1);
      config.aiListLastSyncMs = typeof data.aiListLastSyncMs === 'number' ? data.aiListLastSyncMs : 0;
    } catch (e) {
      logger.error(`load experimental config failed: ${(e as Error).message}`);
    }
    logger.info(`experimental config loaded sb=${config.sponsorBlockEnabled} `
      + `categories=${config.sponsorCategories} dearow=${config.deArrowEnabled} ailist=${config.aiListEnabled}`);
    return config;
  }

  saveToPreferences(): void {
    const data: ExperimentalConfigData = {
      sponsorBlockEnabled: this.sponsorBlockEnabled,
      sponsorCategories: this.sponsorCategories,
      sponsorBehavior: this.sponsorBehavior,
      sponsorUnskipSeconds: this.sponsorUnskipSeconds,
      sponsorPrivacyMode: this.sponsorPrivacyMode,
      sponsorServer: this.sponsorServer,
      sponsorWhitelist: this.sponsorWhitelist,
      deArrowEnabled: this.deArrowEnabled,
      deArrowTitles: this.deArrowTitles,
      deArrowThumbnails: this.deArrowThumbnails,
      deArrowLimit: this.deArrowLimit,
      deArrowConcurrency: this.deArrowConcurrency,
      aiListEnabled: this.aiListEnabled,
      aiListMode: this.aiListMode,
      aiListWarnList: this.aiListWarnList,
      aiListSyncDays: this.aiListSyncDays,
      aiListLastSyncMs: this.aiListLastSyncMs
    };
    PreferencesStore.setString(PREF_KEY, JSON.stringify(data));
    logger.info(`experimental config saved sb=${this.sponsorBlockEnabled} dearow=${this.deArrowEnabled} `
      + `ailist=${this.aiListEnabled}`);
  }

  /** 恢复默认：关闭全部实验性功能。 */
  reset(): void {
    const defaults = new ExperimentalConfig();
    this.sponsorBlockEnabled = defaults.sponsorBlockEnabled;
    this.sponsorCategories = defaults.sponsorCategories;
    this.sponsorBehavior = defaults.sponsorBehavior;
    this.sponsorUnskipSeconds = defaults.sponsorUnskipSeconds;
    this.sponsorPrivacyMode = defaults.sponsorPrivacyMode;
    this.sponsorServer = defaults.sponsorServer;
    this.sponsorWhitelist = defaults.sponsorWhitelist;
    this.deArrowEnabled = defaults.deArrowEnabled;
    this.deArrowTitles = defaults.deArrowTitles;
    this.deArrowThumbnails = defaults.deArrowThumbnails;
    this.deArrowLimit = defaults.deArrowLimit;
    this.deArrowConcurrency = defaults.deArrowConcurrency;
    this.aiListEnabled = defaults.aiListEnabled;
    this.aiListMode = defaults.aiListMode;
    this.aiListWarnList = defaults.aiListWarnList;
    this.aiListSyncDays = defaults.aiListSyncDays;
    this.aiListLastSyncMs = defaults.aiListLastSyncMs;
    this.saveToPreferences();
  }

  isSponsorCategoryEnabled(category: string): boolean {
    return this.categoryList().indexOf(category) >= 0;
  }

  setSponsorCategoryEnabled(category: string, enabled: boolean): void {
    const list = this.categoryList().filter((item: string) => item !== category);
    if (enabled) {
      list.push(category);
    }
    this.sponsorCategories = list.join(',');
  }

  enabledSponsorCategories(): string[] {
    return this.categoryList();
  }

  isChannelWhitelisted(channelId: string): boolean {
    const id = (channelId || '').trim();
    if (id.length === 0 || this.sponsorWhitelist.length === 0) {
      return false;
    }
    return this.sponsorWhitelist.split(',').map((item: string) => item.trim()).indexOf(id) >= 0;
  }

  private categoryList(): string[] {
    if (this.sponsorCategories.length === 0) {
      return [];
    }
    return this.sponsorCategories.split(',').filter((item: string) => item.length > 0);
  }

  private static normalizeCategories(raw: string | undefined): string {
    const valid: string[] = [];
    const input = (raw || '').split(',');
    for (const item of input) {
      const category = item.trim();
      if (category.length > 0 && EXP_SPONSOR_CATEGORIES.indexOf(category) >= 0
        && valid.indexOf(category) < 0) {
        valid.push(category);
      }
    }
    return valid.join(',');
  }

  private static normalizeBehavior(raw: string | undefined): string {
    if (!raw || EXP_SB_BEHAVIORS.indexOf(raw) < 0) {
      return EXP_SB_BEHAVIOR_TOAST;
    }
    return raw;
  }

  private static normalizeNumber(raw: number | undefined, allowed: number[], defaultValue: number): number {
    if (typeof raw !== 'number' || !Number.isFinite(raw)) {
      return defaultValue;
    }
    return allowed.indexOf(raw) >= 0 ? raw : defaultValue;
  }
}

