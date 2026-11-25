import web_webview from '@ohos.web.webview';
import {
  FALLBACK_SABR_POTOKEN_USER_AGENT,
  resolveSabrWebViewUserAgent,
  SabrLocalDomPoTokenGenerator
} from './SabrLocalDomPoTokenGenerator';
import { SabrWebViewPoTokenProvider } from './SabrWebViewPoTokenProvider';
import { AppLog } from '../../common/AppLog';
import { NetworkProxyConfig } from '../../common/NetworkProxyConfig';

const logger = AppLog.getInstance('SabrPoTokenWebRuntime');

@Component
export struct SabrPoTokenWebRuntime {
  private controller: web_webview.WebviewController = new web_webview.WebviewController();
  private provider: SabrWebViewPoTokenProvider = SabrWebViewPoTokenProvider.getInstance();
  private generator?: SabrLocalDomPoTokenGenerator;
  private resolvedUserAgent: string = FALLBACK_SABR_POTOKEN_USER_AGENT;
  private runtimeReady: boolean = false;

  aboutToDisappear(): void {
    this.provider.setMinter(undefined);
    this.generator = undefined;
  }

  // First-attached-WebView hook (this resident runtime attaches at startup):
  // warm DNS + sockets for the origins other WebViews navigate to. The login
  // WebView loads accounts.google.com and lands on www.youtube.com; the PoToken
  // bootstrap itself fetches via HttpDownloader (netstack), not WebView
  // navigation, so WebView prefetch would not help it. Must await the ArkWeb
  // proxy override first — pre-connecting inside the async proxy-apply window
  // would silently go direct for proxy users (same rule as startup prewarm).
  private preconnectUpcomingWebOrigins(): void {
    NetworkProxyConfig.awaitReady()
      .then(() => {
        try {
          web_webview.WebviewController.prepareForPageLoad('https://www.youtube.com', true, 2);
          web_webview.WebviewController.prepareForPageLoad('https://accounts.google.com', true, 1);
          logger.debug('preconnected web origins: www.youtube.com x2, accounts.google.com x1');
        } catch (e) {
          logger.warn(`prepareForPageLoad failed: ${e}`);
        }
      })
      .catch((e: Error) => logger.warn(`proxy awaitReady rejected, skip preconnect: ${e.message}`));
  }

  build() {
    Web({ src: '', controller: this.controller })
      .javaScriptAccess(true)
      .domStorageAccess(true)
      .width(1)
      .height(1)
      .opacity(0.01)
      .hitTestBehavior(HitTestMode.None)
      .onControllerAttached(() => {
        // Align home/GenerateIT requests with the underlying WebView engine UA (minus "; wv")
        // so BotGuard checks match the runtime engine (PipePipe f67df3e58).
        this.resolvedUserAgent = resolveSabrWebViewUserAgent(this.controller);
        try {
          this.controller.setCustomUserAgent(this.resolvedUserAgent);
          logger.info(`resolved WebView UA len=${this.resolvedUserAgent.length}`);
          this.controller.loadData(
            '<!doctype html><html><head><title></title></head><body><div id="interaction"></div></body></html>',
            'text/html', 'UTF-8', 'https://www.youtube.com/', 'about:blank');
        } catch (e) {
          logger.warn(`WebRuntime setup failed: ${e}`);
        }
        this.preconnectUpcomingWebOrigins();
      })
      .onPageEnd(() => {
        if (this.runtimeReady) {
          return;
        }
        this.runtimeReady = true;
        this.generator = new SabrLocalDomPoTokenGenerator(
          this.controller, getContext(this).resourceManager, this.resolvedUserAgent);
        this.provider.setMinter(async (
          visitorData: string,
          videoId: string,
          forceRefresh: boolean
        ): Promise<Uint8Array | undefined> => {
          return await this.generator?.mint(visitorData, videoId, forceRefresh);
        }, (expectedGeneration?: number): void => {
          this.generator?.invalidate(expectedGeneration);
        }, (token: Uint8Array): number | undefined => {
          return this.generator?.generationOf(token);
        });
      })
  }
}
