import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import {
  PlaybackConfig, GPU_API_LABELS,
  CACHE_SECS_LABELS, DEMUXER_READAHEAD_LABELS,
  DEMUXER_MAX_BYTES_LABELS,
  BACKGROUND_VIDEO_OFF_DELAY_LABELS, BackgroundVideoOffDelay,
  getGpuApiDisplay, getCacheSecsDisplay, getDemuxerReadaheadDisplay,
  getDemuxerMaxBytesDisplay, getBackgroundVideoOffDelayDisplay,
} from '../../common/PlaybackConfig';

interface OptionsPerformancePageParams {
  themeColor: ResourceColor;
  clickEffectEnabled: ClickEffect | null;
  updatePlaybackConfig: (updater: (cfg: PlaybackConfig) => void) => void;
}

@Component
export struct OptionsPerformancePage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('playbackConfig') playbackConfig: PlaybackConfig = new PlaybackConfig();

  @Prop params: OptionsPerformancePageParams = {
    themeColor: '#E53935',
    clickEffectEnabled: null,
    updatePlaybackConfig: () => {}
  };

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

  private getBgVideoOffDelayOptions(): SelectOption[] {
    return BACKGROUND_VIDEO_OFF_DELAY_LABELS.map(
      s => ({ value: getBackgroundVideoOffDelayDisplay(s) } as SelectOption));
  }

  build() {
    Column() {
      List({ space: 6 }) {
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
          PlaybackSectionTitle({ title: $r('app.string.yt_section_buffer') })
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
