import { AuthAccountStatus, AuthSessionManager, AuthStage } from 'youtube_core';
import { AuthStateHelper } from '../../common/AuthStateHelper';

@Component
export struct OptionsGoogleAccountPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  onBack?: () => void;
  pushLoginPage?: () => void;

  @StorageLink('authStatus') authStatus: AuthAccountStatus = new AuthAccountStatus();

  private startLogin(): void {
    const uiContext = this.getUIContext();
    uiContext.showAlertDialog({
      title: '登录须知',
      message: '欢迎使用我们的应用，登录功能仍在完善，目前暂不支持获取Youtube账号数据，仅供需要解锁会员内容或者被机器人拦截情况下登录，登录状态下，分辨率将最高限制至1080P',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      offset: { dx: 0, dy: -20 },
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: '取消',
          action: () => {}
        },
        {
          value: '继续登录',
          fontColor: this.themePrimary,
          action: () => {
            if (this.pushLoginPage) {
              this.pushLoginPage();
            }
          }
        }
      ],
      onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
        if (dismissDialogAction.reason === DismissReason.PRESS_BACK
          || dismissDialogAction.reason === DismissReason.TOUCH_OUTSIDE) {
          dismissDialogAction.dismiss();
        }
      }
    });
  }

  private signOut(): void {
    AuthSessionManager.getInstance()?.signOut();
    AuthStateHelper.refresh();
  }

  private getStatusText(): string {
    if (this.authStatus.stage === AuthStage.SIGNED_IN) {
      if (this.authStatus.authMode === 'cookie') {
        return '已登录 (Cookie)';
      }
      return '已登录';
    }
    return '未登录';
  }

  @Builder StatusPill() {
    Row({ space: 8 }) {
      SymbolGlyph(this.authStatus.stage === AuthStage.SIGNED_IN ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.info_circle'))
        .fontSize(22)
        .fontColor([this.authStatus.stage === AuthStage.SIGNED_IN ? this.themePrimary : $r('app.color.yourtube_text_quaternary')])
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
      .backgroundColor(this.themePrimary)
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
      if (this.authStatus.authMode === 'cookie') {
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

          if (this.authStatus.stage === AuthStage.SIGNED_IN) {
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
