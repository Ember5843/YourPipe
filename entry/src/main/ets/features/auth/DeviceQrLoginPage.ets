import {
  AuthAccountStatus,
  AuthSessionManager,
  AuthStage
} from 'youtube_core';
import { AppLog } from '../../common/AppLog';
import { AuthStateHelper } from '../../common/AuthStateHelper';

const logger = AppLog.getInstance('DeviceQrLoginPage');

@Component
export struct DeviceQrLoginPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  onSuccess?: () => void;
  onCancel?: () => void;

  @State private status: AuthAccountStatus = new AuthAccountStatus();
  @State private busy: boolean = false;
  private pollUiTimer: number = -1;
  private session: AuthSessionManager | null = AuthSessionManager.getInstance();

  aboutToAppear(): void {
    this.beginLogin();
  }

  aboutToDisappear(): void {
    this.stopUiTimer();
    // Leaving the page cancels in-flight device flow unless already signed in.
    if (this.status.stage !== AuthStage.SIGNED_IN) {
      this.session?.cancelDeviceLogin();
      AuthStateHelper.refresh();
    }
  }

  private beginLogin(): void {
    if (!this.session) {
      this.status.stage = AuthStage.FAILED;
      this.status.lastError = 'Auth session unavailable';
      return;
    }
    this.busy = true;
    this.session.startDeviceLogin().then((st: AuthAccountStatus) => {
      this.status = st;
      this.busy = false;
      AuthStateHelper.refresh();
      if (st.stage === AuthStage.WAITING_FOR_USER || st.stage === AuthStage.POLLING_TOKEN) {
        this.startUiTimer();
      }
    }).catch((e: Error) => {
      this.busy = false;
      this.status.stage = AuthStage.FAILED;
      this.status.lastError = e.message || 'failed';
      logger.error(`startDeviceLogin failed: ${e.message || e}`);
    });
  }

  private startUiTimer(): void {
    this.stopUiTimer();
    this.pollUiTimer = setInterval(() => {
      this.refreshFromSession();
    }, 1000) as number;
  }

  private stopUiTimer(): void {
    if (this.pollUiTimer >= 0) {
      clearInterval(this.pollUiTimer);
      this.pollUiTimer = -1;
    }
  }

  private refreshFromSession(): void {
    if (!this.session) {
      return;
    }
    const st = this.session.getStatus();
    this.status = st;
    AuthStateHelper.refresh();
    if (st.stage === AuthStage.SIGNED_IN && st.hasRefreshToken) {
      this.stopUiTimer();
      logger.info('Device QR login success');
      this.onSuccess?.();
      return;
    }
    if (st.stage === AuthStage.FAILED || st.stage === AuthStage.SIGNED_OUT) {
      this.stopUiTimer();
    }
  }

  private qrPayload(): string {
    const code = (this.status.userCode || '').trim();
    if (code.length === 0) {
      // Fallback: human page without prefilled code.
      return (this.status.verificationUrl || 'https://yt.be/activate').trim();
    }
    // SmartTube: QR_SIGN_IN_URL + userCode with spaces → '-'.
    // Wrong: google.com/device?user_code=… → phone often sees "Bad Request".
    const normalized = code.replace(/\s+/g, '-');
    return `https://youtube.com/qr/activate/${normalized}`;
  }

  private remainingSec(): number {
    if (this.status.expiresAt <= 0) {
      return 0;
    }
    return Math.max(0, Math.floor((this.status.expiresAt - Date.now()) / 1000));
  }

  private stageLabel(): ResourceStr {
    switch (this.status.stage) {
      case AuthStage.REQUESTING_CODE:
        return $r('app.string.yt_device_login_requesting');
      case AuthStage.WAITING_FOR_USER:
      case AuthStage.POLLING_TOKEN:
        return $r('app.string.yt_device_login_waiting');
      case AuthStage.SIGNED_IN:
        return $r('app.string.yt_device_login_success');
      case AuthStage.FAILED:
        return $r('app.string.yt_device_login_failed');
      default:
        return $r('app.string.yt_device_login_requesting');
    }
  }

  build() {
    Column({ space: 16 }) {
      Text($r('app.string.yt_device_login_help'))
        .fontSize(14)
        .fontColor($r('app.color.yourtube_text_secondary'))
        .width('100%')
        .textAlign(TextAlign.Start)

      if (this.busy || this.status.stage === AuthStage.REQUESTING_CODE) {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(this.themePrimary)
          Text(this.stageLabel())
            .fontSize(14)
            .fontColor($r('app.color.yourtube_text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.status.stage === AuthStage.FAILED) {
        Column({ space: 12 }) {
          Text(this.stageLabel())
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.themePrimary)
          if (this.status.lastError.length > 0) {
            Text(this.status.lastError)
              .fontSize(13)
              .fontColor($r('app.color.yourtube_text_secondary'))
              .textAlign(TextAlign.Center)
          }
          Button($r('app.string.yt_device_login_retry'))
            .height(44)
            .width('80%')
            .backgroundColor(this.themePrimary)
            .fontColor(Color.White)
            .onClick(() => {
              this.beginLogin();
            })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Column({ space: 16 }) {
          // Always light QR for scannability (system dark mode).
          Column() {
            QRCode(this.qrPayload())
              .width(200)
              .height(200)
              .color(Color.Black)
              .backgroundColor(Color.White)
          }
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(16)

          Text(this.status.userCode)
            .fontSize(28)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.yourtube_text_primary'))
            .letterSpacing(2)

          Text(this.status.verificationUrl || 'https://yt.be/activate')
            .fontSize(13)
            .fontColor(this.themePrimary)
            .textAlign(TextAlign.Center)

          Text(this.stageLabel())
            .fontSize(13)
            .fontColor($r('app.color.yourtube_text_secondary'))

          if (this.remainingSec() > 0) {
            Text(`${this.remainingSec()}s`)
              .fontSize(12)
              .fontColor($r('app.color.yourtube_text_quaternary'))
          }

          Row({ space: 8 }) {
            LoadingProgress()
              .width(18)
              .height(18)
              .color(this.themePrimary)
            Text($r('app.string.yt_device_login_polling'))
              .fontSize(13)
              .fontColor($r('app.color.yourtube_text_secondary'))
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      Button($r('app.string.yt_action_cancel'))
        .width('100%')
        .height(44)
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .fontColor($r('app.color.yourtube_text_primary'))
        .onClick(() => {
          this.session?.cancelDeviceLogin();
          AuthStateHelper.refresh();
          this.onCancel?.();
        })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 16, bottom: 24 })
  }
}
