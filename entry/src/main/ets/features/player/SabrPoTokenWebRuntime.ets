import web_webview from '@ohos.web.webview';
import { SabrLocalDomPoTokenGenerator } from './SabrLocalDomPoTokenGenerator';
import { SabrWebViewPoTokenProvider } from './SabrWebViewPoTokenProvider';

@Component
export struct SabrPoTokenWebRuntime {
  private controller: web_webview.WebviewController = new web_webview.WebviewController();
  private provider: SabrWebViewPoTokenProvider = SabrWebViewPoTokenProvider.getInstance();
  private generator?: SabrLocalDomPoTokenGenerator;
  private runtimeReady: boolean = false;

  aboutToDisappear(): void {
    this.provider.setMinter(undefined);
    this.generator = undefined;
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
        // BotGuard changes its signal output for opaque/about:blank origins. Match PipePipe's
        // first-party blank runtime without loading the actual YouTube site.
        this.controller.loadData(
          '<!doctype html><html><head><title></title></head><body><div id="interaction"></div></body></html>',
          'text/html', 'UTF-8', 'https://www.youtube.com/', 'about:blank');
      })
      .onPageEnd(() => {
        if (this.runtimeReady) {
          return;
        }
        this.runtimeReady = true;
        this.generator = new SabrLocalDomPoTokenGenerator(
          this.controller, getContext(this).resourceManager);
        this.provider.setMinter(async (
          visitorData: string,
          videoId: string,
          forceRefresh: boolean
        ): Promise<Uint8Array | undefined> => {
          return await this.generator?.mint(visitorData, videoId, forceRefresh);
        });
      })
  }
}
