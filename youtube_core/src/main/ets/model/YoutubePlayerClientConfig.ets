/**
 * PipePipe-aligned single stream player client selection.
 * Keys match PipePipe NewPipe.setYoutubePlayerClient allow-list.
 *
 * Product default (PipePipe reconcileYoutubePlayerClient): guest is pinned to
 * visionos (token-free adaptiveFormats direct URLs) and signed-in to
 * tv_downgraded (token-free direct URLs). android_vr stays selectable; mweb
 * (SABR) remains available as an opt-in/debug selection via
 * setYoutubePlayerClient.
 */
export type YoutubePlayerClientKey = 'mweb' | 'web_safari' | 'visionos' | 'android_vr' | 'tv_downgraded';

export class YoutubePlayerClientConfig {
  private static selected: YoutubePlayerClientKey = 'visionos';

  private constructor() {}

  static setYoutubePlayerClient(client: string): void {
    if (client === 'mweb' || client === 'web_safari' || client === 'visionos'
      || client === 'android_vr' || client === 'tv_downgraded') {
      YoutubePlayerClientConfig.selected = client;
      return;
    }
    YoutubePlayerClientConfig.selected = 'visionos';
  }

  static getYoutubePlayerClient(): YoutubePlayerClientKey {
    return YoutubePlayerClientConfig.selected;
  }

  /**
   * Product default (PipePipe): signed-in → tv_downgraded, guest → visionos.
   * Both resolve to token-free direct adaptiveFormats URLs; mweb/SABR is
   * opt-in only.
   */
  static applyAuthDefault(hasYouTubeLogin: boolean, _oauthOnly?: boolean): void {
    YoutubePlayerClientConfig.selected = hasYouTubeLogin ? 'tv_downgraded' : 'visionos';
  }

  /** Reset to the product default for the given auth state. */
  static resetToAuthDefault(hasYouTubeLogin: boolean, _oauthOnly?: boolean): void {
    YoutubePlayerClientConfig.selected = hasYouTubeLogin ? 'tv_downgraded' : 'visionos';
  }

  static allowedClients(hasYouTubeLogin: boolean): YoutubePlayerClientKey[] {
    // Product default first; mweb (SABR) stays selectable for debugging.
    if (hasYouTubeLogin) {
      return ['tv_downgraded', 'mweb'];
    }
    return ['visionos', 'android_vr', 'mweb', 'web_safari'];
  }
}
