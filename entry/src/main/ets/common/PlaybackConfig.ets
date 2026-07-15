import { PreferencesStore } from './PreferencesStore';
import { AppLog } from './AppLog';

const logger = AppLog.getInstance('PlaybackConfig');

export type VideoQualityCap = 'best' | '1080p' | '720p' | '480p' | '360p' | '240p' | '144p';

export const VIDEO_QUALITY_CAP_HEIGHT: Record<VideoQualityCap, number> = {
  'best': 9999,
  '1080p': 1080,
  '720p': 720,
  '480p': 480,
  '360p': 360,
  '240p': 240,
  '144p': 144,
};

export const VIDEO_QUALITY_CAP_LABELS: VideoQualityCap[] = [
  'best', '1080p', '720p', '480p', '360p', '240p', '144p'
];

export const VIDEO_QUALITY_CAP_DISPLAY: Record<VideoQualityCap, string> = {
  'best': 'best',
  '1080p': '1080p',
  '720p': '720p',
  '480p': '480p',
  '360p': '360p',
  '240p': '240p',
  '144p': '144p',
};

function normalizeQuality(value: string, fallback: VideoQualityCap): VideoQualityCap {
  return VIDEO_QUALITY_CAP_LABELS.includes(value as VideoQualityCap) ? value as VideoQualityCap : fallback;
}

// MPV 播放器配置
export type CacheSecs = '5' | '10' | '20' | '30' | '60';
export type DemuxerReadahead = '5' | '8' | '15' | '30' | '60';
export type DemuxerMaxBytes = '10' | '20' | '50' | '100';
export type GpuApi = 'auto' | 'opengl' | 'vulkan';
export type BackgroundVideoOffDelay = '0' | '5' | '15' | '30' | '60';

export const BACKGROUND_VIDEO_OFF_DELAY_LABELS: BackgroundVideoOffDelay[] = ['0', '5', '15', '30', '60'];

export const CACHE_SECS_LABELS: CacheSecs[] = ['5', '10', '20', '30', '60'];

export const DEMUXER_READAHEAD_LABELS: DemuxerReadahead[] = ['5', '8', '15', '30', '60'];

export const DEMUXER_MAX_BYTES_LABELS: DemuxerMaxBytes[] = ['10', '20', '50', '100'];

export const GPU_API_LABELS: GpuApi[] = ['auto', 'opengl', 'vulkan'];

export function getBackgroundVideoOffDelayDisplay(value: BackgroundVideoOffDelay): ResourceStr {
  if (value === '0') {
    return $r('app.string.yt_setting_delay_immediate');
  }
  return $r(`app.string.yt_setting_delay_${value}`);
}

export function getCacheSecsDisplay(value: CacheSecs): ResourceStr {
  return $r(`app.string.yt_setting_cache_secs_${value}`);
}

export function getDemuxerReadaheadDisplay(value: DemuxerReadahead): ResourceStr {
  return $r(`app.string.yt_setting_readahead_${value}`);
}

export function getDemuxerMaxBytesDisplay(value: DemuxerMaxBytes): ResourceStr {
  return $r(`app.string.yt_setting_max_bytes_${value}`);
}

export function getGpuApiDisplay(value: GpuApi): Resource {
  if (value === 'auto') {
    return $r('app.string.yt_setting_gpu_auto');
  }
  return $r(`app.string.yt_label_${value}`);
}

export class PlaybackConfig {
  defaultQuality: VideoQualityCap = '480p';
  mobileQuality: VideoQualityCap = '480p';
  /** 返回键/home 键时是否自动进入画中画（设备不支持时强制 false） */
  pipOnReturn: boolean = true;
  /**
   * 真后台时延迟关闭视频解码，仅保留音频（省电）。
   * 分享/投屏/PiP 不会关视频。回前台自动恢复。
   */
  backgroundAudioOnly: boolean = true;
  /** 进入后台后多久关视频（秒），0=立即 */
  backgroundVideoOffDelaySec: BackgroundVideoOffDelay = '15';

  // MPV 播放器设置
  /** 硬件解码开关 */
  hwdecEnabled: boolean = true;
  /** 内存缓存时长（秒） */
  cacheSecs: CacheSecs = '10';
  /** 预读缓冲时长（秒） */
  demuxerReadaheadSecs: DemuxerReadahead = '8';
  /** 解封装器最大缓冲区（MB） */
  demuxerMaxBytes: DemuxerMaxBytes = '20';
  /** GPU 渲染 API */
  gpuApi: GpuApi = 'auto';

  constructor() {}

  clone(): PlaybackConfig {
    const next = new PlaybackConfig();
    next.defaultQuality = this.defaultQuality;
    next.mobileQuality = this.mobileQuality;
    next.pipOnReturn = this.pipOnReturn;
    next.backgroundAudioOnly = this.backgroundAudioOnly;
    next.backgroundVideoOffDelaySec = this.backgroundVideoOffDelaySec;
    next.hwdecEnabled = this.hwdecEnabled;
    next.cacheSecs = this.cacheSecs;
    next.demuxerReadaheadSecs = this.demuxerReadaheadSecs;
    next.demuxerMaxBytes = this.demuxerMaxBytes;
    next.gpuApi = this.gpuApi;
    return next;
  }

  static loadFromPreferences(): PlaybackConfig {
    const cfg = new PlaybackConfig();
    cfg.defaultQuality = normalizeQuality(PreferencesStore.getString('cfg_pb_defaultQuality', '480p'), '480p');
    cfg.mobileQuality = normalizeQuality(PreferencesStore.getString('cfg_pb_mobileQuality', '480p'), '480p');
    cfg.pipOnReturn = PreferencesStore.getString('cfg_pb_pipOnReturn', 'true') === 'true';
    cfg.backgroundAudioOnly = PreferencesStore.getString('cfg_pb_backgroundAudioOnly', 'true') === 'true';
    const delay = PreferencesStore.getString('cfg_pb_backgroundVideoOffDelaySec', '15');
    cfg.backgroundVideoOffDelaySec = BACKGROUND_VIDEO_OFF_DELAY_LABELS.includes(delay as BackgroundVideoOffDelay)
      ? delay as BackgroundVideoOffDelay : '15';

    // MPV 播放器设置
    cfg.hwdecEnabled = PreferencesStore.getString('cfg_pb_hwdecEnabled', 'true') === 'true';
    const cacheSecs = PreferencesStore.getString('cfg_pb_cacheSecs', '10');
    cfg.cacheSecs = CACHE_SECS_LABELS.includes(cacheSecs as CacheSecs) ? cacheSecs as CacheSecs : '10';
    const readahead = PreferencesStore.getString('cfg_pb_demuxerReadaheadSecs', '8');
    cfg.demuxerReadaheadSecs = DEMUXER_READAHEAD_LABELS.includes(readahead as DemuxerReadahead) ? readahead as DemuxerReadahead : '8';
    const maxBytes = PreferencesStore.getString('cfg_pb_demuxerMaxBytes', '20');
    cfg.demuxerMaxBytes = DEMUXER_MAX_BYTES_LABELS.includes(maxBytes as DemuxerMaxBytes) ? maxBytes as DemuxerMaxBytes : '20';
    const gpuApi = PreferencesStore.getString('cfg_pb_gpuApi', 'auto');
    cfg.gpuApi = GPU_API_LABELS.includes(gpuApi as GpuApi) ? gpuApi as GpuApi : 'auto';

    logger.info(`Loaded PlaybackConfig: ${JSON.stringify(cfg)}`);
    return cfg;
  }

  static saveToPreferences(cfg: PlaybackConfig): void {
    PreferencesStore.setString('cfg_pb_defaultQuality', cfg.defaultQuality);
    PreferencesStore.setString('cfg_pb_mobileQuality', cfg.mobileQuality);
    PreferencesStore.setString('cfg_pb_pipOnReturn', cfg.pipOnReturn ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_backgroundAudioOnly', cfg.backgroundAudioOnly ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_backgroundVideoOffDelaySec', cfg.backgroundVideoOffDelaySec);

    // MPV 播放器设置
    PreferencesStore.setString('cfg_pb_hwdecEnabled', cfg.hwdecEnabled ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_cacheSecs', cfg.cacheSecs);
    PreferencesStore.setString('cfg_pb_demuxerReadaheadSecs', cfg.demuxerReadaheadSecs);
    PreferencesStore.setString('cfg_pb_demuxerMaxBytes', cfg.demuxerMaxBytes);
    PreferencesStore.setString('cfg_pb_gpuApi', cfg.gpuApi);

    logger.info('Saved PlaybackConfig');
  }
}
