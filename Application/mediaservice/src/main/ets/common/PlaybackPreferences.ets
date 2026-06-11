/*
 * 引擎层使用的偏好设置接口。
 *
 * 目的：解耦 mediaservice 与 entry 层的 AppStorage('uiConfig'/'playbackConfig')。
 * UI 层在启动时通过 PlaybackPreferences.setProvider() 注入读取实现，
 * 引擎/控制器只通过 PlaybackPreferences.snapshot() 拿到当前偏好。
 */

export interface PlaybackPreferencesSnapshot {
  /** UI 偏好语言，用于字幕语言匹配，例如 "en-GB"。 */
  searchLanguage: string;
  /** 默认清晰度上限：'best' | '1080p' | '720p' | '480p' | '360p' | '240p' | '144p' */
  defaultQuality: string;
  /** 直播 / 受限场景下的清晰度上限。 */
  mobileQuality: string;
  /** 是否允许 1080p 以上分辨率（关闭则在 1080p 处截顶）。 */
  showHighResolutions: boolean;
}

export type PlaybackPreferencesProvider = () => PlaybackPreferencesSnapshot;

const DEFAULT_SNAPSHOT: PlaybackPreferencesSnapshot = {
  searchLanguage: 'en-GB',
  defaultQuality: 'best',
  mobileQuality: '480p',
  showHighResolutions: false,
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
