import web_webview from '@ohos.web.webview';
import { AuthSessionManager, CookieAuthCredential } from 'youtube_core';
import { AppLog } from '../../common/AppLog';
import { AuthStateHelper } from '../../common/AuthStateHelper';

const logger = AppLog.getInstance('WebViewLoginPage');

enum LoginState {
  LOADING,
  EXTRACTING_POT,
  SUCCESS,
  FAILED
}

@Component
export struct WebViewLoginPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  onSuccess?: () => void;
  onCancel?: () => void;
  onRegisterBackHandler?: (handler: () => boolean) => void;
  private webController: web_webview.WebviewController = new web_webview.WebviewController();
  private authSession: AuthSessionManager | null = AuthSessionManager.getInstance();
  private extractedCookies: string = '';

  @State private state: LoginState = LoginState.LOADING;
  @State private progress: number = 0;
  @State private errorMessage: string = '';
  private hasDetectedLogin: boolean = false;
  private hasExtractedPot: boolean = false;

  aboutToAppear(): void {
    if (this.onRegisterBackHandler) {
      this.onRegisterBackHandler((): boolean => this.handleBack());
    }
  }

  aboutToDisappear(): void {
    if (this.onRegisterBackHandler) {
      this.onRegisterBackHandler((): boolean => false);
    }
  }

  private handleBack(): boolean {
    if (this.state !== LoginState.LOADING && this.state !== LoginState.EXTRACTING_POT) {
      return false;
    }
    try {
      if (this.webController.accessBackward()) {
        this.webController.backward();
        return true;
      }
    } catch (e) {
      logger.warn('WebView backward failed');
    }
    return false;
  }

  private static readonly LOGIN_URL: string =
    'https://accounts.google.com/ServiceLogin?service=youtube&continue=https://www.youtube.com/';
  private static readonly MUSIC_VIDEO_URL: string =
    'https://music.youtube.com/watch?v=09839DpTctU';

  private checkLoginCookies(): void {
    if (this.hasDetectedLogin) {
      return;
    }
    try {
      const cookies = web_webview.WebCookieManager.fetchCookieSync('https://www.youtube.com');
      if (cookies && CookieAuthCredential.hasSid(cookies)) {
        this.hasDetectedLogin = true;
        this.extractedCookies = cookies;
        logger.info('Login detected, extracting pot token');
        this.state = LoginState.EXTRACTING_POT;
        this.webController.loadUrl(WebViewLoginPage.MUSIC_VIDEO_URL);
      }
    } catch (e) {
      logger.error('Failed to fetch cookies');
    }
  }

  private handleVideoPlaybackIntercepted(url: string): void {
    if (this.hasExtractedPot) {
      return;
    }
    this.hasExtractedPot = true;

    let potToken = '';
    try {
      const potMatch = url.match(/[?&]pot=([^&]+)/);
      if (potMatch && potMatch[1]) {
        potToken = decodeURIComponent(potMatch[1]);
      }
    } catch (e) {
      logger.warn('Failed to parse pot from URL');
    }

    const allCookies = this.getAllYouTubeCookies();
    const credential = CookieAuthCredential.fromCookies(allCookies, potToken);

    if (credential.sapiSid.length === 0) {
      this.state = LoginState.FAILED;
      this.errorMessage = getContext().resourceManager.getStringSync($r('app.string.yt_login_sapisid_failed').id);
      return;
    }

    if (this.authSession) {
      this.authSession.saveCookieCredential(credential);
    }
    AuthStateHelper.reconcilePlaybackClient();
    logger.info('Login complete');
    this.state = LoginState.SUCCESS;
    if (this.onSuccess) {
      this.onSuccess();
    }
  }

  private getAllYouTubeCookies(): string {
    // Fetch several origins — OHOS WebCookieManager is URL-scoped; missing one
    // host drops SAPISID/SID and recommended home never authenticates.
    const urls: string[] = [
      'https://www.youtube.com',
      'https://youtube.com',
      'https://m.youtube.com',
      'https://music.youtube.com',
      'https://accounts.google.com',
      'https://accounts.youtube.com'
    ];
    try {
      let merged = this.extractedCookies || '';
      for (let i = 0; i < urls.length; i++) {
        try {
          const part = web_webview.WebCookieManager.fetchCookieSync(urls[i]);
          if (part && part.length > 0) {
            merged = merged.length > 0 ? this.mergeCookies(merged, part) : part;
          }
        } catch (_e) {
          // ignore per-url failures
        }
      }
      const names = (merged || '').split(';').map((p: string) => {
        const eq = p.indexOf('=');
        return eq > 0 ? p.substring(0, eq).trim() : '';
      }).filter((n: string) => n.length > 0);
      logger.info(`Collected cookies count=${names.length} hasSID=${names.indexOf('SID') >= 0} `
        + `hasSAPISID=${names.indexOf('SAPISID') >= 0 || names.indexOf('__Secure-3PAPISID') >= 0}`);
      return merged.length > 0 ? merged : this.extractedCookies;
    } catch (e) {
      logger.warn(`fetch cookies failed: ${e}`);
      return this.extractedCookies;
    }
  }

  private mergeCookies(primary: string, secondary: string): string {
    const seen = new Set<string>();
    const result: string[] = [];
    const pairs = primary.split(';');
    for (let i = 0; i < pairs.length; i++) {
      const pair = pairs[i].trim();
      const eqIdx = pair.indexOf('=');
      if (eqIdx > 0) {
        seen.add(pair.substring(0, eqIdx).trim());
        result.push(pair);
      }
    }
    const secondaryPairs = secondary.split(';');
    for (let i = 0; i < secondaryPairs.length; i++) {
      const pair = secondaryPairs[i].trim();
      const eqIdx = pair.indexOf('=');
      if (eqIdx > 0) {
        const name = pair.substring(0, eqIdx).trim();
        if (!seen.has(name)) {
          result.push(pair);
        }
      }
    }
    return result.join('; ');
  }

  private finishWithoutPot(): void {
    const allCookies = this.getAllYouTubeCookies();
    const credential = CookieAuthCredential.fromCookies(allCookies, '');
    if (credential.sapiSid.length === 0) {
      this.state = LoginState.FAILED;
      this.errorMessage = getContext().resourceManager.getStringSync($r('app.string.yt_login_sapisid_failed').id);
      return;
    }
    if (this.authSession) {
      this.authSession.saveCookieCredential(credential);
    }
    AuthStateHelper.reconcilePlaybackClient();
    logger.info('Login complete (without pot)');
    this.state = LoginState.SUCCESS;
    if (this.onSuccess) {
      this.onSuccess();
    }
  }

  build() {
    Column() {
      if (this.state === LoginState.LOADING || this.state === LoginState.EXTRACTING_POT) {
        Stack({ alignContent: Alignment.Top }) {
          Web({ src: WebViewLoginPage.LOGIN_URL, controller: this.webController })
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .mixedMode(MixedMode.All)
            .width('100%')
            .height('100%')
            .onProgressChange((event) => {
              if (event) {
                this.progress = event.newProgress;
              }
            })
            .onPageEnd(() => {
              this.checkLoginCookies();
            })
            .onInterceptRequest((event) => {
              if (!event) {
                return null;
              }
              const url = event.request.getRequestUrl();
              if (url.includes('googlevideo.com/videoplayback')) {
                this.handleVideoPlaybackIntercepted(url);
              }
              return null;
            })

          if (this.progress < 100) {
            Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(3)
              .color(this.themePrimary)
          }

          if (this.state === LoginState.EXTRACTING_POT) {
            Column() {
              Text($r('app.string.yt_login_extracting_auth'))
                .fontSize(14)
                .fontColor(Color.White)
                .padding(12)
                .borderRadius(8)
                .backgroundColor('rgba(0,0,0,0.7)')

              Button($r('app.string.yt_login_skip_pot'))
                .fontSize(13)
                .fontColor(Color.White)
                .backgroundColor('rgba(0,0,0,0.5)')
                .margin({ top: 12 })
                .onClick(() => { this.finishWithoutPot(); })
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .backgroundColor('rgba(0,0,0,0.3)')
          }
        }
        .width('100%')
        .layoutWeight(1)
      } else if (this.state === LoginState.FAILED) {
        Column({ space: 16 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
            .fontSize(48)
            .fontColor([$r('app.color.yourtube_text_quaternary')])

          Text(this.errorMessage)
            .fontSize(15)
            .fontColor($r('app.color.yourtube_text_primary'))
            .textAlign(TextAlign.Center)

          Button($r('app.string.yt_action_retry'))
            .height(44)
            .width('80%')
            .fontSize(15)
            .backgroundColor(this.themePrimary)
            .fontColor(Color.White)
            .onClick(() => {
              this.state = LoginState.LOADING;
              this.hasDetectedLogin = false;
              this.hasExtractedPot = false;
              this.webController.loadUrl(WebViewLoginPage.LOGIN_URL);
            })

          Button($r('app.string.yt_action_cancel'))
            .height(42)
            .width('80%')
            .fontSize(15)
            .fontColor($r('app.color.yourtube_text_primary'))
            .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
            .onClick(() => {
              if (this.onCancel) {
                this.onCancel();
              }
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .padding(24)
      }
    }
    .width('100%')
    .height('100%')
  }
}

