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

export const CACHE_SECS_LABELS: CacheSecs[] = ['5', '10', '20', '30', '60'];
export const CACHE_SECS_DISPLAY: Record<CacheSecs, string> = {
  '5': '5 秒', '10': '10 秒', '20': '20 秒', '30': '30 秒', '60': '60 秒'
};

export const DEMUXER_READAHEAD_LABELS: DemuxerReadahead[] = ['5', '8', '15', '30', '60'];
export const DEMUXER_READAHEAD_DISPLAY: Record<DemuxerReadahead, string> = {
  '5': '5 秒', '8': '8 秒', '15': '15 秒', '30': '30 秒', '60': '60 秒'
};

export const DEMUXER_MAX_BYTES_LABELS: DemuxerMaxBytes[] = ['10', '20', '50', '100'];
export const DEMUXER_MAX_BYTES_DISPLAY: Record<DemuxerMaxBytes, string> = {
  '10': '10 MB', '20': '20 MB', '50': '50 MB', '100': '100 MB'
};

export const GPU_API_LABELS: GpuApi[] = ['auto', 'opengl', 'vulkan'];
export const GPU_API_DISPLAY: Record<GpuApi, string> = {
  'auto': '自动', 'opengl': 'OpenGL', 'vulkan': 'Vulkan'
};

export class PlaybackConfig {
  defaultQuality: VideoQualityCap = 'best';
  mobileQuality: VideoQualityCap = '480p';
  showHighResolutions: boolean = false;
  /** 返回键/home 键时是否自动进入画中画（设备不支持时强制 false） */
  pipOnReturn: boolean = true;

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
    next.showHighResolutions = this.showHighResolutions;
    next.pipOnReturn = this.pipOnReturn;
    next.hwdecEnabled = this.hwdecEnabled;
    next.cacheSecs = this.cacheSecs;
    next.demuxerReadaheadSecs = this.demuxerReadaheadSecs;
    next.demuxerMaxBytes = this.demuxerMaxBytes;
    next.gpuApi = this.gpuApi;
    return next;
  }

  static loadFromPreferences(): PlaybackConfig {
    const cfg = new PlaybackConfig();
    cfg.defaultQuality = normalizeQuality(PreferencesStore.getString('cfg_pb_defaultQuality', 'best'), 'best');
    cfg.mobileQuality = normalizeQuality(PreferencesStore.getString('cfg_pb_mobileQuality', '480p'), '480p');
    cfg.showHighResolutions = PreferencesStore.getString('cfg_pb_showHighRes', 'false') === 'true';
    cfg.pipOnReturn = PreferencesStore.getString('cfg_pb_pipOnReturn', 'true') === 'true';

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
    PreferencesStore.setString('cfg_pb_showHighRes', cfg.showHighResolutions ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_pipOnReturn', cfg.pipOnReturn ? 'true' : 'false');

    // MPV 播放器设置
    PreferencesStore.setString('cfg_pb_hwdecEnabled', cfg.hwdecEnabled ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_cacheSecs', cfg.cacheSecs);
    PreferencesStore.setString('cfg_pb_demuxerReadaheadSecs', cfg.demuxerReadaheadSecs);
    PreferencesStore.setString('cfg_pb_demuxerMaxBytes', cfg.demuxerMaxBytes);
    PreferencesStore.setString('cfg_pb_gpuApi', cfg.gpuApi);

    logger.info('Saved PlaybackConfig');
  }
}
