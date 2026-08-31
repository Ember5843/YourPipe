/*
 * 引擎层使用的偏好设置接口。
 *
 * 目的：解耦 mediaservice 与 entry 层的 AppStorage('uiConfig'/'playbackConfig')。
 * UI 层在启动时通过 PlaybackPreferences.setProvider() 注入读取实现，
 * 引擎/控制器只通过 PlaybackPreferences.snapshot() 拿到当前偏好。
 */

export interface PlaybackPreferencesSnapshot {
  /**
   * Preferred audio language for track ranking (also used lightly for subtitle hints).
   * PipePipe default is "original"; explicit content languages use codes like "zh" / "en".
   */
  searchLanguage: string;
  /** 默认清晰度上限：'best' | '1080p' | '720p' | '480p' | '360p' | '240p' | '144p' */
  defaultQuality: string;
  /** 直播 / 受限场景下的清晰度上限。 */
  mobileQuality: string;
  /** 字幕延迟（毫秒，正值 = 延后显示）；覆盖层字幕查找时从播放位置中减去。 */
  subtitleOffsetMs: number;
}

export type PlaybackPreferencesProvider = () => PlaybackPreferencesSnapshot;

const DEFAULT_SNAPSHOT: PlaybackPreferencesSnapshot = {
  searchLanguage: 'original',
  defaultQuality: 'best',
  mobileQuality: '480p',
  subtitleOffsetMs: 0,
};

export class PlaybackPreferences {
  private static provider: PlaybackPreferencesProvider | undefined = undefined;

  /** 由 entry 层在启动时调用，注入读取偏好的函数。 */
  public static setProvider(provider: PlaybackPreferencesProvider | undefined): void {
    PlaybackPreferences.provider = provider;
  }

  /** 由引擎层调用，拿到当前偏好的快照。未注入时返回默认值。 */
  public static snapshot(): PlaybackPreferencesSnapshot {
    const provider = PlaybackPreferences.provider;
    if (!provider) {
      return DEFAULT_SNAPSHOT;
    }
    try {
      return provider();
    } catch {
      return DEFAULT_SNAPSHOT;
    }
  }
}
