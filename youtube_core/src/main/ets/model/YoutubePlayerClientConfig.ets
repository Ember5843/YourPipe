/**
 * PipePipe-aligned single stream player client selection.
 * Keys match PipePipe NewPipe.setYoutubePlayerClient allow-list
 * (HEAD: mweb | visionos | tv_downgraded | tv_samsung).
 *
 * Per-state defaults are configurable (entry Options → setConfiguredClients):
 * guest defaults to tv_samsung (token-free TVHTML5 direct adaptiveFormats
 * URLs, PipePipe 61b077779 logged-out default) and signed-in to mweb (SABR);
 * tv_downgraded (token-free direct URLs) remains selectable when signed in.
 * visionos (token-free GAPIS direct URLs) stays selectable for guests.
 */
// 'web_safari' and 'android_vr' are unused endpoints (no UI, unreachable in
// product; android_vr was dropped upstream by PipePipe v5.3.0) — kept for
// reference only.
export type YoutubePlayerClientKey = 'mweb' | 'web_safari' | 'visionos' | 'android_vr'
  | 'tv_downgraded' | 'tv_samsung';

export class YoutubePlayerClientConfig {
  private static selected: YoutubePlayerClientKey = 'tv_samsung';
  // Per-state configured clients, pushed by entry from PlaybackConfig.
  private static guestClient: YoutubePlayerClientKey = 'tv_samsung';
  private static authClient: YoutubePlayerClientKey = 'mweb';
  // True once setYoutubePlayerClient pins a client explicitly; applyAuthDefault
  // must not clobber a manual selection on every extraction attempt.
  private static explicitOverride: boolean = false;
  // One-shot extraction override (SABR → token-free direct fallback). It does
  // NOT touch `explicitOverride`: the user's configured client stays the truth
  // and the override is cleared as soon as the fallback attempt finished.
  private static extractionOverride?: YoutubePlayerClientKey;

  private constructor() {}

  // DORMANT: 全仓零调用（端点选择已改为 per-state 配置 setConfiguredClients，
  // 手动 pin 机制不再接线）；保留仅供调试时临时强制锁定某一端点。
  static setYoutubePlayerClient(client: string): void {
    if (client === 'mweb' || client === 'web_safari' || client === 'visionos'
      || client === 'android_vr' || client === 'tv_downgraded'
      || client === 'tv_samsung') {
      YoutubePlayerClientConfig.selected = client;
      YoutubePlayerClientConfig.explicitOverride = true;
      return;
    }
    YoutubePlayerClientConfig.selected = 'tv_samsung';
    YoutubePlayerClientConfig.explicitOverride = true;
  }

  static getYoutubePlayerClient(): YoutubePlayerClientKey {
    return YoutubePlayerClientConfig.extractionOverride ?? YoutubePlayerClientConfig.selected;
  }

  /**
   * One-shot extraction override (entry's SABR → tv_downgraded endpoint
   * fallback). The override applies to the next extraction only and never
   * changes the configured per-state client, so the user's setting stays the
   * source of truth.
   */
  static setExtractionClientOverride(client: YoutubePlayerClientKey): void {
    YoutubePlayerClientConfig.extractionOverride = client;
  }

  static clearExtractionClientOverride(): void {
    YoutubePlayerClientConfig.extractionOverride = undefined;
  }

  /**
   * Entry injection point for the two Options settings. Per-state allow-lists
   * mirror PipePipe HEAD: guest → tv_samsung|visionos|mweb (default
   * tv_samsung), signed-in → tv_downgraded|mweb (default mweb);
   * out-of-list values fall back to that state's product default.
   */
  static setConfiguredClients(guest: string, auth: string): void {
    YoutubePlayerClientConfig.guestClient =
      guest === 'mweb' ? 'mweb'
        : guest === 'visionos' ? 'visionos' : 'tv_samsung';
    YoutubePlayerClientConfig.authClient =
      auth === 'mweb' ? 'mweb' : 'tv_downgraded';
  }

  /**
   * Select the configured client for the current auth state (guest default
   * tv_samsung, signed-in default mweb). No-op when a client was
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
    return ['tv_samsung', 'visionos', 'mweb'];
  }
}
