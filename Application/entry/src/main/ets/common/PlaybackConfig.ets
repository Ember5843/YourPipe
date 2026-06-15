import { PreferencesStore } from './PreferencesStore';
import { AppLog } from './AppLog';

const logger = AppLog.getInstance('PlaybackConfig');

export type VideoQualityCap = 'best' | '1080p' | '720p' | '480p' | '360p' | '240p' | '144p';

export const VIDEO_QUALITY_CAP_HEIGHT: Record<VideoQualityCap, number> = {
  'best': 9999,
  '1080p': 1080,
  '720p': 720,
  '480p': 480,
  '360p': 360,
  '240p': 240,
  '144p': 144,
};

export const VIDEO_QUALITY_CAP_LABELS: VideoQualityCap[] = [
  'best', '1080p', '720p', '480p', '360p', '240p', '144p'
];

export const VIDEO_QUALITY_CAP_DISPLAY: Record<VideoQualityCap, string> = {
  'best': 'best',
  '1080p': '1080p',
  '720p': '720p',
  '480p': '480p',
  '360p': '360p',
  '240p': '240p',
  '144p': '144p',
};

function normalizeQuality(value: string, fallback: VideoQualityCap): VideoQualityCap {
  return VIDEO_QUALITY_CAP_LABELS.includes(value as VideoQualityCap) ? value as VideoQualityCap : fallback;
}

export type CacheDiskSize = '256' | '512' | '1024' | '2048';
export type CacheMaxAge = '2' | '6' | '12' | '24';

export const CACHE_DISK_SIZE_LABELS: CacheDiskSize[] = ['256', '512', '1024', '2048'];
export const CACHE_DISK_SIZE_DISPLAY: Record<CacheDiskSize, string> = {
  '256': '256 MB', '512': '512 MB', '1024': '1 GB', '2048': '2 GB'
};

export const CACHE_MAX_AGE_LABELS: CacheMaxAge[] = ['2', '6', '12', '24'];
export const CACHE_MAX_AGE_DISPLAY: Record<CacheMaxAge, string> = {
  '2': '2 小时', '6': '6 小时', '12': '12 小时', '24': '24 小时'
};

export class PlaybackConfig {
  defaultQuality: VideoQualityCap = 'best';
  mobileQuality: VideoQualityCap = '480p';
  showHighResolutions: boolean = false;
  cacheDiskSize: CacheDiskSize = '512';
  cacheMaxAge: CacheMaxAge = '6';

  constructor() {}

  clone(): PlaybackConfig {
    const next = new PlaybackConfig();
    next.defaultQuality = this.defaultQuality;
    next.mobileQuality = this.mobileQuality;
    next.showHighResolutions = this.showHighResolutions;
    next.cacheDiskSize = this.cacheDiskSize;
    next.cacheMaxAge = this.cacheMaxAge;
    return next;
  }

  static loadFromPreferences(): PlaybackConfig {
    const cfg = new PlaybackConfig();
    cfg.defaultQuality = normalizeQuality(PreferencesStore.getString('cfg_pb_defaultQuality', 'best'), 'best');
    cfg.mobileQuality = normalizeQuality(PreferencesStore.getString('cfg_pb_mobileQuality', '480p'), '480p');
    cfg.showHighResolutions = PreferencesStore.getString('cfg_pb_showHighRes', 'false') === 'true';
    const diskSize = PreferencesStore.getString('cfg_pb_cacheDiskSize', '512');
    cfg.cacheDiskSize = CACHE_DISK_SIZE_LABELS.includes(diskSize as CacheDiskSize) ? diskSize as CacheDiskSize : '512';
    const maxAge = PreferencesStore.getString('cfg_pb_cacheMaxAge', '6');
    cfg.cacheMaxAge = CACHE_MAX_AGE_LABELS.includes(maxAge as CacheMaxAge) ? maxAge as CacheMaxAge : '6';
    logger.info(`Loaded PlaybackConfig: ${JSON.stringify(cfg)}`);
    return cfg;
  }

  static saveToPreferences(cfg: PlaybackConfig): void {
    PreferencesStore.setString('cfg_pb_defaultQuality', cfg.defaultQuality);
    PreferencesStore.setString('cfg_pb_mobileQuality', cfg.mobileQuality);
    PreferencesStore.setString('cfg_pb_showHighRes', cfg.showHighResolutions ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_cacheDiskSize', cfg.cacheDiskSize);
    PreferencesStore.setString('cfg_pb_cacheMaxAge', cfg.cacheMaxAge);
    logger.info('Saved PlaybackConfig');
  }
}
