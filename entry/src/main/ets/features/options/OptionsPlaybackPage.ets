import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import {
  PlaybackConfig, VideoQualityCap, VIDEO_QUALITY_CAP_LABELS,
  GUEST_PLAYER_CLIENT_LABELS, AUTH_PLAYER_CLIENT_LABELS, getPlayerClientDisplay,
  AUDIO_DELAY_MIN_MS, AUDIO_DELAY_MAX_MS, AUDIO_DELAY_STEP_MS,
  clampAudioDelayMs, getAudioDelayDisplay,
} from '../../common/PlaybackConfig';
import { UIConfig } from '../../common/AppState';
import { PlayerSession } from '../../common/PlayerSession';
import { PiPManager } from '../player/pip/PiPManager';
import { AuthSessionManager } from 'youtube_core';

const DOWNLOAD_CONCURRENCY_VALUES: number[] = [1, 2, 3, 4];
/** 下载整体超时（分钟）。0 = 不超时。 */
const DOWNLOAD_TIMEOUT_VALUES: number[] = [0, 5, 10, 15, 30, 60, 120];

interface OptionsPlaybackPageParams {
  themeColor: ResourceColor;
  clickEffectEnabled: ClickEffect | null;
  updatePlaybackConfig: (updater: (cfg: PlaybackConfig) => void) => void;
  updateUiConfig: (updater: (cfg: UIConfig) => void) => void;
  getQualityDisplay: (quality: VideoQualityCap) => ResourceStr;
  /** 播放端点变更后的副作用（应用配置 + 重置身份/pot/prefetch），在写盘后调用 */
  onPlayerClientChanged: (guest: string, auth: string) => void;
}

@Component
export struct OptionsPlaybackPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('playbackConfig') playbackConfig: PlaybackConfig = new PlaybackConfig();
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('optionsHighlightKey') @Watch('onHighlightKeyChanged') optionsHighlightKey: string = '';

  private listScroller: ListScroller = new ListScroller();
  @State private highlightGuestEndpoint: boolean = false;
  @State private highlightAuthEndpoint: boolean = false;

  @Prop params: OptionsPlaybackPageParams = {
    themeColor: '#E53935',
    clickEffectEnabled: null,
    updatePlaybackConfig: () => {},
    updateUiConfig: () => {},
    getQualityDisplay: (quality) => quality,
    onPlayerClientChanged: () => {}
  };

  private getQualityOptions(): SelectOption[] {
    return VIDEO_QUALITY_CAP_LABELS.map(cap => ({ value: this.params.getQualityDisplay(cap) } as SelectOption));
  }

  private getGuestPlayerClientOptions(): SelectOption[] {
    return GUEST_PLAYER_CLIENT_LABELS.map(s => ({ value: getPlayerClientDisplay(s) } as SelectOption));
  }

  private getAuthPlayerClientOptions(): SelectOption[] {
    return AUTH_PLAYER_CLIENT_LABELS.map(s => ({ value: getPlayerClientDisplay(s) } as SelectOption));
  }

  private getConcurrencyOptions(): SelectOption[] {
    return DOWNLOAD_CONCURRENCY_VALUES.map(value => ({ value: value.toString() } as SelectOption));
  }

  private getTimeoutOptions(): SelectOption[] {
    const resourceManager = getContext().resourceManager;
    return DOWNLOAD_TIMEOUT_VALUES.map((value: number) => ({
      // 注意：$r('app.string.x', 参数) 返回的是**带格式化参数的 Resource**。
      // Text 渲染 Resource 时会套用参数，但 ArkUI 的 Select 解析 Resource 走的是
      // getStringSync(id)（不带参数）→ 选项里会原样显示 "%d 分钟"。
      // 这里直接取已格式化的字符串。
      value: value === 0
        ? resourceManager.getStringSync($r('app.string.yt_download_timeout_off').id)
        : resourceManager.getStringSync($r('app.string.yt_download_timeout_minutes').id, value)
    } as SelectOption));
  }

  private applyAudioDelay(nextMs: number): void {
    const clamped = clampAudioDelayMs(nextMs);
    this.params.updatePlaybackConfig((cfg: PlaybackConfig) => {
      cfg.audioDelayMs = clamped;
    });
    PlayerSession.getInstance().setAudioDelayMs(clamped);
  }

  aboutToAppear(): void {
    this.syncEndpointHighlight();
  }

  aboutToDisappear(): void {
    this.highlightGuestEndpoint = false;
    this.highlightAuthEndpoint = false;
  }

  onHighlightKeyChanged(): void {
    this.syncEndpointHighlight();
  }

  private syncEndpointHighlight(): void {
    if (this.optionsHighlightKey !== 'endpoint_section') {
      this.highlightGuestEndpoint = false;
      this.highlightAuthEndpoint = false;
      return;
    }
    const usePlaybackAuth = AuthSessionManager.getInstance()?.isAuthEnabledForPlayback() === true;
    setTimeout(() => {
      this.listScroller.scrollToIndex(4, true);
      this.highlightGuestEndpoint = !usePlaybackAuth;
      this.highlightAuthEndpoint = usePlaybackAuth;
    }, 180);
  }

  private clearEndpointHighlight(): void {
    this.highlightGuestEndpoint = false;
    this.highlightAuthEndpoint = false;
    if (this.optionsHighlightKey === 'endpoint_section') {
      this.optionsHighlightKey = '';
    }
  }

  build() {
    Column() {
      List({ space: 6, scroller: this.listScroller }) {
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_section_video') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_default_quality'),
              options: this.getQualityOptions(),
              selectedIndex: VIDEO_QUALITY_CAP_LABELS.indexOf(this.playbackConfig.defaultQuality),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const cap = VIDEO_QUALITY_CAP_LABELS[index];
                this.params.updatePlaybackConfig(cfg => cfg.defaultQuality = cap);
              }
            })
          }

          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_playback_auto_play_next'),
              subtitle: $r('app.string.yt_playback_auto_play_next_subtitle'),
              isOn: this.playbackConfig.autoPlayNext,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updatePlaybackConfig(cfg => cfg.autoPlayNext = val);
              }
            })
          }
        }
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_section_audio_enhance') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_playback_audio_normalize'),
              subtitle: $r('app.string.yt_playback_audio_normalize_subtitle'),
              isOn: this.playbackConfig.audioNormalizeEnabled,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updatePlaybackConfig((cfg: PlaybackConfig) => {
                  cfg.audioNormalizeEnabled = val;
                });
                PlayerSession.getInstance().applyAudioFilters(val);
              }
            })
          }

          ListItem() {
            Column({ space: 10 }) {
              Row({ space: 12 }) {
                Column() {
                  Text($r('app.string.yt_playback_audio_delay'))
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.yourtube_text_primary'))
                  Text($r('app.string.yt_playback_audio_delay_subtitle'))
                    .fontSize(12)
                    .fontColor($r('app.color.yourtube_text_quaternary'))
                    .margin({ top: 3 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text(getAudioDelayDisplay(this.playbackConfig.audioDelayMs))
                  .fontSize(14)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(this.playbackConfig.audioDelayMs !== 0
                    ? this.params.themeColor
                    : $r('app.color.yourtube_text_secondary'))
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Row({ space: 8 }) {
                Button() {
                  SymbolGlyph($r('sys.symbol.minus'))
                    .fontSize(16)
                    .fontColor([$r('app.color.yourtube_text_primary')])
                }
                .width(40)
                .height(34)
                .backgroundColor($r('sys.color.comp_background_tertiary'))
                .borderRadius(17)
                .enabled(this.playbackConfig.audioDelayMs > AUDIO_DELAY_MIN_MS)
                .opacity(this.playbackConfig.audioDelayMs > AUDIO_DELAY_MIN_MS ? 1 : 0.4)
                .onClick(() => {
                  this.applyAudioDelay(this.playbackConfig.audioDelayMs - AUDIO_DELAY_STEP_MS);
                })

                Button() {
                  SymbolGlyph($r('sys.symbol.plus'))
                    .fontSize(16)
                    .fontColor([$r('app.color.yourtube_text_primary')])
                }
                .width(40)
                .height(34)
                .backgroundColor($r('sys.color.comp_background_tertiary'))
                .borderRadius(17)
                .enabled(this.playbackConfig.audioDelayMs < AUDIO_DELAY_MAX_MS)
                .opacity(this.playbackConfig.audioDelayMs < AUDIO_DELAY_MAX_MS ? 1 : 0.4)
                .onClick(() => {
                  this.applyAudioDelay(this.playbackConfig.audioDelayMs + AUDIO_DELAY_STEP_MS);
                })

                Blank()

                if (this.playbackConfig.audioDelayMs !== 0) {
                  Button($r('app.string.yt_playback_audio_delay_reset'))
                    .height(34)
                    .padding({ left: 14, right: 14 })
                    .fontSize(13)
                    .fontColor(this.params.themeColor)
                    .backgroundColor($r('sys.color.comp_background_tertiary'))
                    .borderRadius(17)
                    .onClick(() => {
                      this.applyAudioDelay(0);
                    })
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          }
        }
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_playback_stream_endpoint') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_playback_guest_player_client'),
              helpText: $r('app.string.yt_help_guest_endpoint'),
              forceShowPopup: this.highlightGuestEndpoint,
              onPopupClosed: () => {
                this.clearEndpointHighlight();
              },
              options: this.getGuestPlayerClientOptions(),
              selectedIndex: GUEST_PLAYER_CLIENT_LABELS.indexOf(this.playbackConfig.guestPlayerClient),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const client = GUEST_PLAYER_CLIENT_LABELS[index];
                this.params.updatePlaybackConfig(cfg => cfg.guestPlayerClient = client);
                this.params.onPlayerClientChanged(client, this.playbackConfig.authPlayerClient);
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_playback_auth_player_client'),
              helpText: $r('app.string.yt_help_auth_endpoint'),
              forceShowPopup: this.highlightAuthEndpoint,
              onPopupClosed: () => {
                this.clearEndpointHighlight();
              },
              options: this.getAuthPlayerClientOptions(),
              selectedIndex: AUTH_PLAYER_CLIENT_LABELS.indexOf(this.playbackConfig.authPlayerClient),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const client = AUTH_PLAYER_CLIENT_LABELS[index];
                this.params.updatePlaybackConfig(cfg => cfg.authPlayerClient = client);
                this.params.onPlayerClientChanged(this.playbackConfig.guestPlayerClient, client);
              }
            })
          }
        }
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        if (PiPManager.getInstance().isPiPSupported()) {
          ListItem() {
            PlaybackSectionTitle({ title: $r('app.string.yt_playback_pip') })
          }
          .padding({ left: 0, right: 0 })

          ListItemGroup() {
            ListItem() {
              PlaybackToggleRow({
                title: $r('app.string.yt_playback_pip_on_return'),
                subtitle: $r('app.string.yt_playback_pip_on_return_subtitle'),
                isOn: this.playbackConfig.pipOnReturn,
                themeColor: this.params.themeColor,
                transparentBackground: true,
                onChange: (val: boolean) => {
                  this.params.updatePlaybackConfig(cfg => cfg.pipOnReturn = val);
                }
              })
            }
          }
          .backgroundColor($r('sys.color.comp_background_list_card'))
          .borderRadius(SECTION_CARD_RADIUS)
          .clip(true)
        }

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_download_title') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_download_concurrent_tasks'),
              options: this.getConcurrencyOptions(),
              selectedIndex: DOWNLOAD_CONCURRENCY_VALUES.indexOf(this.uiConfig.maxConcurrentDownloads || 1),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const value = DOWNLOAD_CONCURRENCY_VALUES[index] || 1;
                this.params.updateUiConfig(cfg => cfg.maxConcurrentDownloads = value);
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_download_timeout_title'),
              options: this.getTimeoutOptions(),
              selectedIndex: Math.max(0, DOWNLOAD_TIMEOUT_VALUES.indexOf(
                this.uiConfig.downloadTimeoutMinutes ?? 30)),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const value = DOWNLOAD_TIMEOUT_VALUES[index] ?? 30;
                this.params.updateUiConfig(cfg => cfg.downloadTimeoutMinutes = value);
              }
            })
          }
        }
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)

        ListItem() {
          Column().height(24)
        }
        .padding({ left: 0, right: 0 })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16 })
      .edgeEffect(EdgeEffect.Spring)
      .alignListItem(ListItemAlign.Start)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
