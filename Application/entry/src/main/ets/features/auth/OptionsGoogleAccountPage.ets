import { AuthAccountStatus, AuthSessionManager, AuthStage } from 'youtube_core';
import { AppLog } from '../../common/AppLog';

const logger = AppLog.getInstance('OptionsGoogleAccountPage');

@Component
export struct OptionsGoogleAccountPage {
  onBack?: () => void;
  pushLoginPage?: () => void;
  private authSession: AuthSessionManager | null = AuthSessionManager.getInstance();

  @State private status: AuthAccountStatus = new AuthAccountStatus();

  aboutToAppear() {
    this.syncStatus();
  }

  private syncStatus(): void {
    if (this.authSession) {
      this.status = this.authSession.getStatus();
    }
  }

  private startLogin(): void {
    if (this.pushLoginPage) {
      this.pushLoginPage();
    }
  }

  private signOut(): void {
    if (this.authSession) {
      this.status = this.authSession.signOut();
    } else {
      this.status = new AuthAccountStatus();
    }
  }

  private getStatusText(): string {
    if (this.status.stage === AuthStage.SIGNED_IN) {
      if (this.status.authMode === 'cookie') {
        return '已登录 (Cookie)';
      }
      return '已登录';
    }
    return '未登录';
  }

  @Builder StatusPill() {
    Row({ space: 8 }) {
      SymbolGlyph(this.status.stage === AuthStage.SIGNED_IN ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.info_circle'))
        .fontSize(22)
        .fontColor([this.status.stage === AuthStage.SIGNED_IN ? $r('app.color.yourtube_theme_primary') : $r('app.color.yourtube_text_quaternary')])
      Text(this.getStatusText())
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.yourtube_text_primary'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .borderRadius(16)
    .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
  }

  @Builder PrimaryButton(label: string, action: () => void) {
    Button(label)
      .height(44)
      .width('100%')
      .fontSize(15)
      .fontWeight(FontWeight.Medium)
      .backgroundColor($r('app.color.yourtube_theme_primary'))
      .fontColor(Color.White)
      .onClick(action)
  }

  @Builder SecondaryButton(label: string, action: () => void) {
    Button(label)
      .height(42)
      .width('100%')
      .fontSize(15)
      .fontColor($r('app.color.yourtube_text_primary'))
      .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
      .onClick(action)
  }

  @Builder SignedOutView() {
    Column({ space: 12 }) {
      Text('登录 YouTube 以获取个性化推荐和订阅内容')
        .fontSize(14)
        .fontColor($r('app.color.yourtube_text_quaternary'))
        .width('100%')

      this.PrimaryButton('开始登录', () => { this.startLogin(); })
    }
    .width('100%')
  }

  @Builder SignedInView() {
    Column({ space: 12 }) {
      if (this.status.authMode === 'cookie') {
        Text('已通过 Cookie 方式登录')
          .fontSize(14)
          .fontColor($r('app.color.yourtube_text_quaternary'))
          .width('100%')
      } else {
        Text('已通过 OAuth 方式登录')
          .fontSize(14)
          .fontColor($r('app.color.yourtube_text_quaternary'))
          .width('100%')
      }

      this.SecondaryButton('退出登录', () => { this.signOut(); })
    }
    .width('100%')
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 16 }) {
          this.StatusPill()

          if (this.status.stage === AuthStage.SIGNED_IN) {
            this.SignedInView()
          } else {
            this.SignedOutView()
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 24 })
      }
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
  }
}
