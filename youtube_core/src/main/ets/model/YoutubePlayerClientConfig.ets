/**
 * PipePipe-aligned single stream player client selection.
 * Keys match PipePipe NewPipe.setYoutubePlayerClient allow-list.
 *
 * Product default (PipePipe reconcileYoutubePlayerClient): guest is pinned to
 * visionos (token-free adaptiveFormats direct URLs) and signed-in to
 * tv_downgraded (token-free direct URLs).
 */
export type YoutubePlayerClientKey = 'mweb' | 'web_safari' | 'visionos' | 'android_vr' | 'tv_downgraded';

export class YoutubePlayerClientConfig {
  private static selected: YoutubePlayerClientKey = 'visionos';
  // True once setYoutubePlayerClient pins a client explicitly; applyAuthDefault
  // must not clobber a manual selection on every extraction attempt.
  private static explicitOverride: boolean = false;

  private constructor() {}

  // DORMANT: 全仓零调用（产品锁双默认，无 UI 入口）；启用条件：debug/设置页提供
  // 手动客户端选择（mweb(SABR)/web_safari/android_vr）时由此接线。
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
   * Product default (PipePipe): signed-in → tv_downgraded, guest → visionos.
   * Both resolve to token-free direct adaptiveFormats URLs; mweb/SABR is
   * opt-in only. No-op when a client was explicitly pinned via
   * setYoutubePlayerClient.
   */
  static applyAuthDefault(hasYouTubeLogin: boolean, _oauthOnly?: boolean): void {
    if (YoutubePlayerClientConfig.explicitOverride) {
      return;
    }
    YoutubePlayerClientConfig.selected = hasYouTubeLogin ? 'tv_downgraded' : 'visionos';
  }

  /** Reset to the product default for the given auth state (clears any explicit pin). */
  static resetToAuthDefault(hasYouTubeLogin: boolean, _oauthOnly?: boolean): void {
    YoutubePlayerClientConfig.explicitOverride = false;
    YoutubePlayerClientConfig.selected = hasYouTubeLogin ? 'tv_downgraded' : 'visionos';
  }

  // DORMANT: 全仓零调用（无客户端选择 UI）；启用条件：与 setYoutubePlayerClient
  // 一起接入 debug/设置页，用于列出可选客户端。
  static allowedClients(hasYouTubeLogin: boolean): YoutubePlayerClientKey[] {
    // Product default first; mweb (SABR) stays selectable for debugging.
    if (hasYouTubeLogin) {
      return ['tv_downgraded', 'mweb'];
    }
    return ['visionos', 'android_vr', 'mweb', 'web_safari'];
  }
}
