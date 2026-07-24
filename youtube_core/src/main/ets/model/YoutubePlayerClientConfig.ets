/**
 * PipePipe-aligned single stream player client selection.
 * Keys match PipePipe NewPipe.setYoutubePlayerClient allow-list.
 *
 * Product experiment (YourPipe / yt-lab SABR path): always prefer mweb so
 * VOD can use serverAbrStreamingUrl + SABR. Login no longer switches to
 * tv_downgraded by default.
 */
export type YoutubePlayerClientKey = 'mweb' | 'web_safari' | 'android_vr' | 'tv_downgraded';

export class YoutubePlayerClientConfig {
  private static selected: YoutubePlayerClientKey = 'mweb';
  /** When false (default for experiment), auth state never forces tv_downgraded. */
  private static autoByAuth: boolean = false;

  private constructor() {}

  /**
   * Legacy PipePipe switch: signed-in → tv_downgraded, guest → mweb.
   * Experiment keeps this off so playback stays on mweb.
   */
  static setAutoByAuth(enabled: boolean): void {
    YoutubePlayerClientConfig.autoByAuth = enabled;
  }

  static isAutoByAuth(): boolean {
    return YoutubePlayerClientConfig.autoByAuth;
  }

  static setYoutubePlayerClient(client: string): void {
    if (client === 'mweb' || client === 'web_safari'
      || client === 'android_vr' || client === 'tv_downgraded') {
      YoutubePlayerClientConfig.selected = client;
      return;
    }
    YoutubePlayerClientConfig.selected = 'mweb';
  }

  static getYoutubePlayerClient(): YoutubePlayerClientKey {
    return YoutubePlayerClientConfig.selected;
  }

  /**
   * Product default: always pin mweb (SABR path) for guest, Cookie, and OAuth.
   * OAuth must NOT force tv_downgraded on every video — that breaks switch-stream
   * vs cookie/guest. Restricted content may retry tv_downgraded+Bearer at call site.
   * Legacy autoByAuth keeps PipePipe login→tv/mweb selection when enabled.
   */
  static applyAuthDefault(hasYouTubeLogin: boolean, _oauthOnly?: boolean): void {
    if (!YoutubePlayerClientConfig.autoByAuth) {
      YoutubePlayerClientConfig.selected = 'mweb';
      return;
    }
    const current = YoutubePlayerClientConfig.selected;
    if (hasYouTubeLogin) {
      if (current !== 'tv_downgraded' && current !== 'mweb') {
        YoutubePlayerClientConfig.selected = 'mweb';
      }
    } else if (current === 'tv_downgraded') {
      YoutubePlayerClientConfig.selected = 'mweb';
    }
  }

  /** Reset to product default mweb (all login modes). */
  static resetToAuthDefault(_hasYouTubeLogin: boolean, _oauthOnly?: boolean): void {
    YoutubePlayerClientConfig.selected = 'mweb';
  }

  static allowedClients(hasYouTubeLogin: boolean): YoutubePlayerClientKey[] {
    // Keep tv_downgraded selectable for debugging when signed in; product default is mweb.
    if (hasYouTubeLogin) {
      return ['mweb', 'tv_downgraded'];
    }
    return ['mweb', 'web_safari', 'android_vr'];
  }
}
