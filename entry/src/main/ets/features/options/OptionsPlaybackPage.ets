import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import { UIConfig } from '../../common/AppState';
import {
  PlaybackConfig, VideoQualityCap, VIDEO_QUALITY_CAP_LABELS, GPU_API_LABELS,
  CACHE_SECS_LABELS, DEMUXER_READAHEAD_LABELS,
  DEMUXER_MAX_BYTES_LABELS,
  BACKGROUND_VIDEO_OFF_DELAY_LABELS, BackgroundVideoOffDelay,
  getGpuApiDisplay, getCacheSecsDisplay, getDemuxerReadaheadDisplay,
  getDemuxerMaxBytesDisplay, getBackgroundVideoOffDelayDisplay,
  HOLD_SPEED_VALUES, HOLD_SPEED_DELAYS, getHoldSpeedDelayDisplay,
} from '../../common/PlaybackConfig';
import { PiPManager } from '../player/pip/PiPManager';

const DOWNLOAD_CONCURRENCY_VALUES: number[] = [1, 2, 3, 4];

interface OptionsPlaybackPageParams {
  themeColor: ResourceColor;
  updatePlaybackConfig: (updater: (cfg: PlaybackConfig) => void) => void;
  updateUiConfig: (updater: (cfg: UIConfig) => void) => void;
  getQualityDisplay: (quality: VideoQualityCap) => ResourceStr;
}

@Component
export struct OptionsPlaybackPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('playbackConfig') playbackConfig: PlaybackConfig = new PlaybackConfig();

  @Prop params: OptionsPlaybackPageParams = {
    themeColor: '#E53935',
    updatePlaybackConfig: () => {},
    updateUiConfig: () => {},
    getQualityDisplay: (quality) => quality
  };

  private getQualityOptions(): SelectOption[] {
    return VIDEO_QUALITY_CAP_LABELS.map(cap => ({ value: this.params.getQualityDisplay(cap) } as SelectOption));
  }

  private getGpuApiOptions(): SelectOption[] {
    return GPU_API_LABELS.map(s => ({ value: getGpuApiDisplay(s) } as SelectOption));
  }

  private getCacheSecsOptions(): SelectOption[] {
    return CACHE_SECS_LABELS.map(s => ({ value: getCacheSecsDisplay(s) } as SelectOption));
  }

  private getReadaheadOptions(): SelectOption[] {
    return DEMUXER_READAHEAD_LABELS.map(s => ({ value: getDemuxerReadaheadDisplay(s) } as SelectOption));
  }

  private getMaxBytesOptions(): SelectOption[] {
    return DEMUXER_MAX_BYTES_LABELS.map(s => ({ value: getDemuxerMaxBytesDisplay(s) } as SelectOption));
  }

  private getConcurrencyOptions(): SelectOption[] {
    return DOWNLOAD_CONCURRENCY_VALUES.map(value => ({ value: value.toString() } as SelectOption));
  }

  private getBgVideoOffDelayOptions(): SelectOption[] {
    return BACKGROUND_VIDEO_OFF_DELAY_LABELS.map(
      s => ({ value: getBackgroundVideoOffDelayDisplay(s) } as SelectOption));
  }

  private getHoldSpeedOptions(): SelectOption[] {
    return HOLD_SPEED_VALUES.map(v => ({ value: `${v}x` } as SelectOption));
  }

  private getHoldSpeedDelayOptions(): SelectOption[] {
    return HOLD_SPEED_DELAYS.map(v => ({ value: getHoldSpeedDelayDisplay(v) } as SelectOption));
  }

  build() {
    Column() {
      List({ space: 6 }) {
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
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
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
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .borderRadius(SECTION_CARD_RADIUS)
          .clip(true)
        }

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_playback_player') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_playback_background_audio_only'),
              subtitle: $r('app.string.yt_playback_background_audio_only_subtitle'),
              isOn: this.playbackConfig.backgroundAudioOnly,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updatePlaybackConfig(cfg => cfg.backgroundAudioOnly = val);
              }
            })
          }

          if (this.playbackConfig.backgroundAudioOnly) {
            ListItem() {
              PlaybackSelectRow({
                title: $r('app.string.yt_playback_video_off_delay'),
                options: this.getBgVideoOffDelayOptions(),
                selectedIndex: BACKGROUND_VIDEO_OFF_DELAY_LABELS.indexOf(
                  this.playbackConfig.backgroundVideoOffDelaySec),
                fontColor: this.params.themeColor,
                transparentBackground: true,
                onChange: (index: number) => {
                  const d = BACKGROUND_VIDEO_OFF_DELAY_LABELS[index] as BackgroundVideoOffDelay;
                  this.params.updatePlaybackConfig(cfg => cfg.backgroundVideoOffDelaySec = d);
                }
              })
            }
          }

          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_playback_hwdec'),
              subtitle: $r('app.string.yt_playback_hwdec_subtitle'),
              isOn: this.playbackConfig.hwdecEnabled,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updatePlaybackConfig(cfg => cfg.hwdecEnabled = val);
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_playback_gpu_rendering'),
              options: this.getGpuApiOptions(),
              selectedIndex: GPU_API_LABELS.indexOf(this.playbackConfig.gpuApi),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const api = GPU_API_LABELS[index];
                this.params.updatePlaybackConfig(cfg => cfg.gpuApi = api);
              }
            })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_playback_gestures') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_playback_gesture_seek'),
              subtitle: $r('app.string.yt_playback_gesture_seek_subtitle'),
              isOn: this.playbackConfig.gestureSeekEnabled,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updatePlaybackConfig(cfg => cfg.gestureSeekEnabled = val);
              }
            })
          }

          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_playback_gesture_brightness'),
              subtitle: $r('app.string.yt_playback_gesture_brightness_subtitle'),
              isOn: this.playbackConfig.gestureBrightnessEnabled,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updatePlaybackConfig(cfg => cfg.gestureBrightnessEnabled = val);
              }
            })
          }

          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_playback_gesture_volume'),
              subtitle: $r('app.string.yt_playback_gesture_volume_subtitle'),
              isOn: this.playbackConfig.gestureVolumeEnabled,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updatePlaybackConfig(cfg => cfg.gestureVolumeEnabled = val);
              }
            })
          }

          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_playback_hold_speed'),
              subtitle: $r('app.string.yt_playback_hold_speed_subtitle'),
              isOn: this.playbackConfig.holdSpeedEnabled,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updatePlaybackConfig(cfg => cfg.holdSpeedEnabled = val);
              }
            })
          }

          if (this.playbackConfig.holdSpeedEnabled) {
            ListItem() {
              PlaybackSelectRow({
                title: $r('app.string.yt_playback_hold_speed_value'),
                options: this.getHoldSpeedOptions(),
                selectedIndex: HOLD_SPEED_VALUES.indexOf(this.playbackConfig.holdSpeedValue),
                fontColor: this.params.themeColor,
                transparentBackground: true,
                onChange: (index: number) => {
                  const v = HOLD_SPEED_VALUES[index];
                  this.params.updatePlaybackConfig(cfg => cfg.holdSpeedValue = v);
                }
              })
            }

            ListItem() {
              PlaybackSelectRow({
                title: $r('app.string.yt_playback_hold_speed_delay'),
                options: this.getHoldSpeedDelayOptions(),
                selectedIndex: HOLD_SPEED_DELAYS.indexOf(this.playbackConfig.holdSpeedDelayMs),
                fontColor: this.params.themeColor,
                transparentBackground: true,
                onChange: (index: number) => {
                  const v = HOLD_SPEED_DELAYS[index];
                  this.params.updatePlaybackConfig(cfg => cfg.holdSpeedDelayMs = v);
                }
              })
            }
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_playback_buffer_network') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_playback_memory_cache'),
              options: this.getCacheSecsOptions(),
              selectedIndex: CACHE_SECS_LABELS.indexOf(this.playbackConfig.cacheSecs),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const secs = CACHE_SECS_LABELS[index];
                this.params.updatePlaybackConfig(cfg => cfg.cacheSecs = secs);
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_playback_readahead'),
              options: this.getReadaheadOptions(),
              selectedIndex: DEMUXER_READAHEAD_LABELS.indexOf(this.playbackConfig.demuxerReadaheadSecs),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const secs = DEMUXER_READAHEAD_LABELS[index];
                this.params.updatePlaybackConfig(cfg => cfg.demuxerReadaheadSecs = secs);
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_playback_buffer_size'),
              options: this.getMaxBytesOptions(),
              selectedIndex: DEMUXER_MAX_BYTES_LABELS.indexOf(this.playbackConfig.demuxerMaxBytes),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const bytes = DEMUXER_MAX_BYTES_LABELS[index];
                this.params.updatePlaybackConfig(cfg => cfg.demuxerMaxBytes = bytes);
              }
            })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

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
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
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
