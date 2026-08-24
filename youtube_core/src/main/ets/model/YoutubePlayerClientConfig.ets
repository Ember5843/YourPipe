/**
 * PipePipe-aligned single stream player client selection.
 * Keys match PipePipe NewPipe.setYoutubePlayerClient allow-list.
 *
 * Per-state defaults are configurable (entry Options → setConfiguredClients):
 * guest defaults to visionos (token-free adaptiveFormats direct URLs) and
 * signed-in to mweb (SABR); tv_downgraded (token-free direct URLs) remains
 * selectable when signed in.
 */
// 'web_safari' and 'android_vr' are unused endpoints (no UI, unreachable in
// product; android_vr was dropped upstream by PipePipe v5.3.0) — kept for
// reference only.
export type YoutubePlayerClientKey = 'mweb' | 'web_safari' | 'visionos' | 'android_vr' | 'tv_downgraded';

export class YoutubePlayerClientConfig {
  private static selected: YoutubePlayerClientKey = 'visionos';
  // Per-state configured clients, pushed by entry from PlaybackConfig.
  private static guestClient: YoutubePlayerClientKey = 'visionos';
  private static authClient: YoutubePlayerClientKey = 'mweb';
  // True once setYoutubePlayerClient pins a client explicitly; applyAuthDefault
  // must not clobber a manual selection on every extraction attempt.
  private static explicitOverride: boolean = false;

  private constructor() {}

  // DORMANT: 全仓零调用（端点选择已改为 per-state 配置 setConfiguredClients，
  // 手动 pin 机制不再接线）；保留仅供调试时临时强制锁定某一端点。
  static setYoutubePlayerClient(client: string): void {
    if (client === 'mweb' || client === 'web_safari' || client === 'visionos'
      || client === 'android_vr' || client === 'tv_downgraded') {
      YoutubePlayerClientConfig.selected = client;
      YoutubePlayerClientConfig.explicitOverride = true;
      return;
    }
    YoutubePlayerClientConfig.selected = 'visionos';
    YoutubePlayerClientConfig.explicitOverride = true;
  }

  static getYoutubePlayerClient(): YoutubePlayerClientKey {
    return YoutubePlayerClientConfig.selected;
  }

  /**
   * Entry injection point for the two Options settings. Per-state allow-lists
   * mirror PipePipe: guest → visionos|mweb, signed-in → tv_downgraded|mweb;
   * out-of-list values fall back to that state's product default.
   */
  static setConfiguredClients(guest: string, auth: string): void {
    YoutubePlayerClientConfig.guestClient =
      guest === 'mweb' ? 'mweb' : 'visionos';
    YoutubePlayerClientConfig.authClient =
      auth === 'mweb' ? 'mweb' : 'tv_downgraded';
  }

  /**
   * Select the configured client for the current auth state (guest default
   * visionos, signed-in default mweb). No-op when a client was
   * explicitly pinned via setYoutubePlayerClient.
   */
  static applyAuthDefault(hasYouTubeLogin: boolean, _oauthOnly?: boolean): void {
    if (YoutubePlayerClientConfig.explicitOverride) {
      return;
    }
    YoutubePlayerClientConfig.selected = hasYouTubeLogin
      ? YoutubePlayerClientConfig.authClient
      : YoutubePlayerClientConfig.guestClient;
  }

  /** Reset to the configured client for the given auth state (clears any explicit pin). */
  static resetToAuthDefault(hasYouTubeLogin: boolean, _oauthOnly?: boolean): void {
    YoutubePlayerClientConfig.explicitOverride = false;
    YoutubePlayerClientConfig.selected = hasYouTubeLogin
      ? YoutubePlayerClientConfig.authClient
      : YoutubePlayerClientConfig.guestClient;
  }

  // DORMANT: 全仓零调用（设置页 UI 在 entry 侧自行维护两个固定选项列表，
  // 未消费此 API）；'android_vr'/'web_safari' 为不可达的未使用端点，仅作参考保留。
  static allowedClients(hasYouTubeLogin: boolean): YoutubePlayerClientKey[] {
    // Product default first; mweb (SABR) stays selectable for debugging.
    if (hasYouTubeLogin) {
      return ['tv_downgraded', 'mweb'];
    }
    return ['visionos', 'android_vr', 'mweb', 'web_safari'];
  }
}
