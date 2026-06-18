import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { UIConfig } from '../../common/AppState';
import { PlaybackConfig, VideoQualityCap, VIDEO_QUALITY_CAP_LABELS, GPU_API_LABELS, GPU_API_DISPLAY, CACHE_SECS_LABELS, CACHE_SECS_DISPLAY, DEMUXER_READAHEAD_LABELS, DEMUXER_READAHEAD_DISPLAY, DEMUXER_MAX_BYTES_LABELS, DEMUXER_MAX_BYTES_DISPLAY } from '../../common/PlaybackConfig';
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
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('playbackConfig') playbackConfig: PlaybackConfig = new PlaybackConfig();

  @Prop params: OptionsPlaybackPageParams = {
    themeColor: $r('app.color.yourtube_theme_primary'),
    updatePlaybackConfig: () => {},
    updateUiConfig: () => {},
    getQualityDisplay: (quality) => quality
  };

  private getQualityOptions(): SelectOption[] {
    return VIDEO_QUALITY_CAP_LABELS.map(cap => ({ value: this.params.getQualityDisplay(cap) } as SelectOption));
  }

  private getGpuApiOptions(): SelectOption[] {
    return GPU_API_LABELS.map(s => ({ value: GPU_API_DISPLAY[s] } as SelectOption));
  }

  private getCacheSecsOptions(): SelectOption[] {
    return CACHE_SECS_LABELS.map(s => ({ value: CACHE_SECS_DISPLAY[s] } as SelectOption));
  }

  private getReadaheadOptions(): SelectOption[] {
    return DEMUXER_READAHEAD_LABELS.map(s => ({ value: DEMUXER_READAHEAD_DISPLAY[s] } as SelectOption));
  }

  private getMaxBytesOptions(): SelectOption[] {
    return DEMUXER_MAX_BYTES_LABELS.map(s => ({ value: DEMUXER_MAX_BYTES_DISPLAY[s] } as SelectOption));
  }

  private getConcurrencyOptions(): SelectOption[] {
    return DOWNLOAD_CONCURRENCY_VALUES.map(value => ({ value: value.toString() } as SelectOption));
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 6 }) {
          PlaybackSectionTitle({ title: $r('app.string.yt_section_video') })

          PlaybackSelectRow({
            title: $r('app.string.yt_setting_default_quality'),
            options: this.getQualityOptions(),
            selectedIndex: VIDEO_QUALITY_CAP_LABELS.indexOf(this.playbackConfig.defaultQuality),
            fontColor: this.params.themeColor,
            onChange: (index: number) => {
              const cap = VIDEO_QUALITY_CAP_LABELS[index];
              this.params.updatePlaybackConfig(cfg => cfg.defaultQuality = cap);
            }
          })

          if (PiPManager.getInstance().isPiPSupported()) {
            PlaybackSectionTitle({ title: '画中画' })

            PlaybackToggleRow({
              title: '返回时进入画中画',
              subtitle: '按返回键或 home 键时自动弹出画中画窗口',
              isOn: this.playbackConfig.pipOnReturn,
              themeColor: this.params.themeColor,
              onChange: (val: boolean) => {
                this.params.updatePlaybackConfig(cfg => cfg.pipOnReturn = val);
              }
            })
          }

          PlaybackSectionTitle({ title: '播放器' })

          PlaybackToggleRow({
            title: '硬件解码',
            subtitle: '启用硬件加速解码，降低功耗并提升性能',
            isOn: this.playbackConfig.hwdecEnabled,
            themeColor: this.params.themeColor,
            onChange: (val: boolean) => {
              this.params.updatePlaybackConfig(cfg => cfg.hwdecEnabled = val);
            }
          })

          PlaybackSelectRow({
            title: 'GPU 渲染',
            options: this.getGpuApiOptions(),
            selectedIndex: GPU_API_LABELS.indexOf(this.playbackConfig.gpuApi),
            fontColor: this.params.themeColor,
            onChange: (index: number) => {
              const api = GPU_API_LABELS[index];
              this.params.updatePlaybackConfig(cfg => cfg.gpuApi = api);
            }
          })

          PlaybackSectionTitle({ title: '缓冲与网络' })

          PlaybackSelectRow({
            title: '内存缓存',
            options: this.getCacheSecsOptions(),
            selectedIndex: CACHE_SECS_LABELS.indexOf(this.playbackConfig.cacheSecs),
            fontColor: this.params.themeColor,
            onChange: (index: number) => {
              const secs = CACHE_SECS_LABELS[index];
              this.params.updatePlaybackConfig(cfg => cfg.cacheSecs = secs);
            }
          })

          PlaybackSelectRow({
            title: '预读缓冲',
            options: this.getReadaheadOptions(),
            selectedIndex: DEMUXER_READAHEAD_LABELS.indexOf(this.playbackConfig.demuxerReadaheadSecs),
            fontColor: this.params.themeColor,
            onChange: (index: number) => {
              const secs = DEMUXER_READAHEAD_LABELS[index];
              this.params.updatePlaybackConfig(cfg => cfg.demuxerReadaheadSecs = secs);
            }
          })

          PlaybackSelectRow({
            title: '缓冲区大小',
            options: this.getMaxBytesOptions(),
            selectedIndex: DEMUXER_MAX_BYTES_LABELS.indexOf(this.playbackConfig.demuxerMaxBytes),
            fontColor: this.params.themeColor,
            onChange: (index: number) => {
              const bytes = DEMUXER_MAX_BYTES_LABELS[index];
              this.params.updatePlaybackConfig(cfg => cfg.demuxerMaxBytes = bytes);
            }
          })

          PlaybackSectionTitle({ title: '下载' })

          PlaybackSelectRow({
            title: '并发下载任务',
            options: this.getConcurrencyOptions(),
            selectedIndex: DOWNLOAD_CONCURRENCY_VALUES.indexOf(this.uiConfig.maxConcurrentDownloads || 1),
            fontColor: this.params.themeColor,
            onChange: (index: number) => {
              const value = DOWNLOAD_CONCURRENCY_VALUES[index] || 1;
              this.params.updateUiConfig(cfg => cfg.maxConcurrentDownloads = value);
            }
          })

          Blank().height(24)
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
