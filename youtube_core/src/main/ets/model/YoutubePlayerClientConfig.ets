/**
 * PipePipe-aligned single stream player client selection.
 * Keys match PipePipe NewPipe.setYoutubePlayerClient allow-list.
 */
export type YoutubePlayerClientKey = 'mweb' | 'web_safari' | 'android_vr' | 'tv_downgraded';

export class YoutubePlayerClientConfig {
  private static selected: YoutubePlayerClientKey = 'mweb';
  private static autoByAuth: boolean = true;

  private constructor() {}

  /** When true (default), signed-in → tv_downgraded, guest → mweb (PipePipe App.java). */
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
    YoutubePlayerClientConfig.selected = 'web_safari';
  }

  static getYoutubePlayerClient(): YoutubePlayerClientKey {
    return YoutubePlayerClientConfig.selected;
  }

  /**
   * Apply PipePipe login policy when autoByAuth is on:
   * - login: only tv_downgraded / mweb allowed; default tv_downgraded
   * - guest: tv_downgraded forced to mweb
   */
  static applyAuthDefault(hasYouTubeLogin: boolean): void {
    if (!YoutubePlayerClientConfig.autoByAuth) {
      return;
    }
    const current = YoutubePlayerClientConfig.selected;
    if (hasYouTubeLogin) {
      if (current !== 'tv_downgraded' && current !== 'mweb') {
        YoutubePlayerClientConfig.selected = 'tv_downgraded';
      }
    } else if (current === 'tv_downgraded') {
      YoutubePlayerClientConfig.selected = 'mweb';
    }
  }

  /** Force PipePipe defaults: login → tv_downgraded, guest → mweb. */
  static resetToAuthDefault(hasYouTubeLogin: boolean): void {
    YoutubePlayerClientConfig.selected = hasYouTubeLogin ? 'tv_downgraded' : 'mweb';
  }

  static allowedClients(hasYouTubeLogin: boolean): YoutubePlayerClientKey[] {
    if (hasYouTubeLogin) {
      return ['tv_downgraded', 'mweb'];
    }
    return ['mweb', 'web_safari', 'android_vr'];
  }
}
