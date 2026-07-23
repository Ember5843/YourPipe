import { http } from '@kit.NetworkKit';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { OptionItem } from '../../common/components/OptionItem';
import { NetworkProxyConfig } from '../../common/NetworkProxyConfig';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { UIConfig } from '../../common/AppState';
import { HttpDownloader } from 'youtube_core';
import { AppLog } from '../../common/AppLog';

const logger = AppLog.getInstance('OptionsNetworkPage');

interface OptionsNetworkPageParams {
  themeColor: ResourceColor;
  onConfigChanged: (cfg: NetworkProxyConfig) => void;
}

@Component
export struct OptionsNetworkPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('networkProxyConfig') networkProxyConfig: NetworkProxyConfig = new NetworkProxyConfig();

  @Prop params: OptionsNetworkPageParams = {
    themeColor: '#F1680D',
    onConfigChanged: () => {}
  };

  @State private testing: boolean = false;
  @State private testMessage: ResourceStr = '';

  private persist(): void {
    NetworkProxyConfig.save(this.networkProxyConfig);
    NetworkProxyConfig.applySystemAndProviders(this.networkProxyConfig);
    this.params.onConfigChanged(this.networkProxyConfig);
  }

  private async runProxyTest(): Promise<void> {
    if (this.testing) {
      return;
    }
    if (!this.networkProxyConfig.enabled) {
      this.testMessage = $r('app.string.yt_proxy_test_disabled');
      return;
    }
    if (this.networkProxyConfig.kind === 'socks5') {
      this.testMessage = $r('app.string.yt_proxy_socks5_soon');
      return;
    }
    if (!this.networkProxyConfig.isReady()) {
      this.testMessage = $r('app.string.yt_proxy_incomplete');
      return;
    }
    this.testing = true;
    this.testMessage = $r('app.string.yt_proxy_testing');
    this.persist();
    const testUrl = 'https://www.youtube.com/generate_204';
    const req = http.createHttp();
    const startedAt = Date.now();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: 10000,
        readTimeout: 10000,
        usingCache: false
      };
      HttpDownloader.applyProxyToOptions(options, testUrl);
      const response = await req.request(testUrl, options);
      const elapsed = Date.now() - startedAt;
      logger.info(`proxy test status=${response.responseCode} elapsed=${elapsed}ms`);
      if (response.responseCode >= 200 && response.responseCode < 400) {
        this.testMessage = $r('app.string.yt_proxy_test_ok');
      } else {
        this.testMessage = $r('app.string.yt_proxy_test_http_error');
      }
    } catch (e) {
      logger.warn(`proxy test failed: ${e instanceof Error ? e.message : String(e)}`);
      this.testMessage = $r('app.string.yt_proxy_test_failed');
    } finally {
      req.destroy();
      this.testing = false;
    }
  }

  build() {
    Column() {
      List({ space: 6 }) {
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_option_network') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_proxy_enable'),
              subtitle: $r('app.string.yt_proxy_enable_subtitle'),
              isOn: this.networkProxyConfig.enabled,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.networkProxyConfig.enabled = val;
                this.persist();
              }
            })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(16)
        .clip(true)

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_proxy_type') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            OptionItem({
              icon: $r('sys.symbol.wifi'),
              title: $r('app.string.yt_proxy_type_http'),
              subtitle: $r('app.string.yt_proxy_type_http_subtitle'),
              showChevron: false,
              iconColor: this.themePrimary,
              clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
              transparentBackground: true,
              onClickAction: () => {
                this.networkProxyConfig.kind = 'http';
                this.persist();
              }
            })
          }

          ListItem() {
            Row({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.lock_shield'))
                .fontSize(24)
                .fontColor([$r('app.color.yourtube_icon_hint')])
                .opacity(0.45)
              Column() {
                Text($r('app.string.yt_proxy_type_socks5'))
                  .fontWeight(FontWeight.Medium)
                  .fontSize(16)
                  .fontColor($r('app.color.yourtube_text_quaternary'))
                Text($r('app.string.yt_proxy_socks5_soon'))
                  .fontSize(13)
                  .fontColor($r('app.color.yourtube_text_quaternary'))
                  .margin({ top: 4 })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .constraintSize({ minHeight: 56 })
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .opacity(0.7)
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(16)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_proxy_server') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            Column({ space: 8 }) {
              Text($r('app.string.yt_proxy_host'))
                .fontSize(13)
                .fontColor($r('app.color.yourtube_text_quaternary'))
                .width('100%')
              TextInput({
                text: this.networkProxyConfig.host,
                placeholder: $r('app.string.yt_proxy_host_placeholder')
              })
                .width('100%')
                .height(44)
                .fontSize(15)
                .backgroundColor(Color.Transparent)
                .onChange((v: string) => {
                  this.networkProxyConfig.host = v.trim();
                })
                .onSubmit(() => {
                  this.persist();
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .alignItems(HorizontalAlign.Start)
          }

          ListItem() {
            Column({ space: 8 }) {
              Text($r('app.string.yt_proxy_port'))
                .fontSize(13)
                .fontColor($r('app.color.yourtube_text_quaternary'))
                .width('100%')
              TextInput({
                text: `${this.networkProxyConfig.port}`,
                placeholder: '7890'
              })
                .width('100%')
                .height(44)
                .fontSize(15)
                .type(InputType.Number)
                .backgroundColor(Color.Transparent)
                .onChange((v: string) => {
                  const n = parseInt(v, 10);
                  if (Number.isFinite(n)) {
                    this.networkProxyConfig.port = Math.max(1, Math.min(65535, n));
                  }
                })
                .onSubmit(() => {
                  this.persist();
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .alignItems(HorizontalAlign.Start)
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(16)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_proxy_auth_optional') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            Column({ space: 8 }) {
              Text($r('app.string.yt_proxy_username'))
                .fontSize(13)
                .fontColor($r('app.color.yourtube_text_quaternary'))
                .width('100%')
              TextInput({
                text: this.networkProxyConfig.username,
                placeholder: $r('app.string.yt_proxy_optional_placeholder')
              })
                .width('100%')
                .height(44)
                .fontSize(15)
                .backgroundColor(Color.Transparent)
                .onChange((v: string) => {
                  this.networkProxyConfig.username = v;
                })
                .onSubmit(() => {
                  this.persist();
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .alignItems(HorizontalAlign.Start)
          }

          ListItem() {
            Column({ space: 8 }) {
              Text($r('app.string.yt_proxy_password'))
                .fontSize(13)
                .fontColor($r('app.color.yourtube_text_quaternary'))
                .width('100%')
              TextInput({
                text: this.networkProxyConfig.password,
                placeholder: $r('app.string.yt_proxy_optional_placeholder')
              })
                .width('100%')
                .height(44)
                .fontSize(15)
                .type(InputType.Password)
                .backgroundColor(Color.Transparent)
                .onChange((v: string) => {
                  this.networkProxyConfig.password = v;
                })
                .onSubmit(() => {
                  this.persist();
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
            .alignItems(HorizontalAlign.Start)
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(16)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        ListItem() {
          Button(this.testing ? $r('app.string.yt_proxy_testing') : $r('app.string.yt_proxy_test'))
            .width('100%')
            .height(48)
            .fontSize(16)
            .backgroundColor(this.themePrimary)
            .fontColor(Color.White)
            .borderRadius(16)
            .enabled(!this.testing)
            .onClick(() => {
              this.persist();
              this.runProxyTest();
            })
        }
        .padding({ left: 0, right: 0, top: 8 })

        if (!(typeof this.testMessage === 'string' && this.testMessage.length === 0)) {
          ListItem() {
            Text(this.testMessage)
              .fontSize(13)
              .fontColor($r('app.color.yourtube_text_quaternary'))
              .width('100%')
              .padding({ left: 4, right: 4 })
          }
        }

        ListItem() {
          Text($r('app.string.yt_proxy_loopback_note'))
            .fontSize(12)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .width('100%')
            .padding({ left: 4, right: 4, top: 8, bottom: 16 })
        }

        ListItem() {
          Column().height(24)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 8, bottom: 12 })
      .edgeEffect(EdgeEffect.Spring)
      .alignListItem(ListItemAlign.Start)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .onDisAppear(() => {
      this.persist();
    })
  }
}
