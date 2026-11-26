import { sabrSessionStore } from 'mediaservice';
import { AuthAccountStatus, AuthStage } from 'youtube_core';

/**
 * PipePipe-style SABR server backoff live countdown ("YouTube forces us to wait N seconds..."),
 * rendered directly below the loading spinner while mounted. Polls at 250ms ONLY while the
 * parent loading/buffering spinner is mounted, so steady-state playback pays zero timer cost.
 */
@Component
export struct SabrBackoffNotice {
  @Prop videoId: string = '';
  @StorageLink('authStatus') authStatus: AuthAccountStatus = new AuthAccountStatus();
  onOpenPlaybackAuthSettings?: () => void;

  @State private remainingSeconds: number = 0;
  private tickerId: number = -1;

  aboutToAppear(): void {
    this.syncRemaining();
    this.tickerId = setInterval(() => {
      this.syncRemaining();
    }, 250);
  }

  aboutToDisappear(): void {
    if (this.tickerId >= 0) {
      clearInterval(this.tickerId);
      this.tickerId = -1;
    }
  }

  private syncRemaining(): void {
    const ms = sabrSessionStore.getPlaybackBackoffRemainingMs(this.videoId);
    const secs = ms > 0 ? Math.max(1, Math.ceil(ms / 1000)) : 0;
    if (secs !== this.remainingSeconds) {
      this.remainingSeconds = secs;
    }
  }

  private isPlaybackAuthActive(): boolean {
    const hasCred = this.authStatus.hasCredential
      || this.authStatus.hasCookieCredential
      || this.authStatus.hasRefreshToken
      || this.authStatus.stage === AuthStage.SIGNED_IN;
    return hasCred && this.authStatus.authEnabled !== false && this.authStatus.useAuthForPlayback !== false;
  }

  build() {
    if (this.remainingSeconds > 0) {
      Column({ space: 6 }) {
        Text($r('app.string.yt_sabr_backoff_countdown', this.remainingSeconds))
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#F2FFFFFF')
          .textAlign(TextAlign.Center)
          .padding({ left: 20, right: 20 })

        if (this.isPlaybackAuthActive()) {
          Row({ space: 8 }) {
            Text($r('app.string.yt_sabr_backoff_non_premium_hint'))
              .fontSize(11)
              .fontColor('#B3FFFFFF')

            if (this.onOpenPlaybackAuthSettings) {
              Text($r('app.string.yt_sabr_backoff_switch_fast'))
                .fontSize(11)
                .fontWeight(FontWeight.Medium)
                .fontColor('#FFFFFFFF')
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .backgroundColor('#33FFFFFF')
                .borderRadius(10)
                .onClick(() => {
                  if (this.onOpenPlaybackAuthSettings) {
                    this.onOpenPlaybackAuthSettings();
                  }
                })
            }
          }
          .justifyContent(FlexAlign.Center)
        }
      }
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor('#80000000')
      .borderRadius(14)
      .margin({ top: 12 })
    }
  }
}
