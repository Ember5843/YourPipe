import { PreferencesStore } from './PreferencesStore';
import { AppLog } from './AppLog';

const logger = AppLog.getInstance('PlaybackConfig');

export type VideoQualityCap = 'best' | '4320p' | '2160p' | '1440p' | '1080p' | '720p' | '480p' | '360p' | '240p' | '144p';

export const VIDEO_QUALITY_CAP_HEIGHT: Record<VideoQualityCap, number> = {
  'best': 9999,
  '4320p': 4320,
  '2160p': 2160,
  '1440p': 1440,
  '1080p': 1080,
  '720p': 720,
  '480p': 480,
  '360p': 360,
  '240p': 240,
  '144p': 144,
};

export const VIDEO_QUALITY_CAP_LABELS: VideoQualityCap[] = [
  'best', '4320p', '2160p', '1440p', '1080p', '720p', '480p', '360p', '240p', '144p'
];

export const VIDEO_QUALITY_CAP_DISPLAY: Record<VideoQualityCap, string> = {
  'best': 'best',
  '4320p': '8K (4320p)',
  '2160p': '4K (2160p)',
  '1440p': '2K (1440p)',
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

/** 游客态播放端点（PipePipe per-state allow-list: visionos | mweb） */
export type GuestPlayerClient = 'visionos' | 'mweb';
/** 登录态播放端点（PipePipe per-state allow-list: tv_downgraded | mweb） */
export type AuthPlayerClient = 'tv_downgraded' | 'mweb';

export const GUEST_PLAYER_CLIENT_LABELS: GuestPlayerClient[] = ['visionos', 'mweb'];
export const AUTH_PLAYER_CLIENT_LABELS: AuthPlayerClient[] = ['tv_downgraded', 'mweb'];

export function getPlayerClientDisplay(value: string): Resource {
  if (value === 'tv_downgraded') {
    return $r('app.string.yt_setting_client_tv_downgraded');
  }
  if (value === 'mweb') {
    return $r('app.string.yt_setting_client_mweb');
  }
  return $r('app.string.yt_setting_client_visionos');
}

/** 长按加速可选倍速档 */
export const HOLD_SPEED_VALUES: number[] = [1.25, 1.5, 1.75, 2.0, 2.5, 3.0];

/** 长按触发延迟可选档位（毫秒） */
export const HOLD_SPEED_DELAYS: number[] = [300, 500, 800, 1000];

/** 覆盖层字幕字号倍率（相对播放器默认 14/18fp） */
export type SubtitleFontScale = '0.75' | '1' | '1.25' | '1.5';
export const SUBTITLE_FONT_SCALE_LABELS: SubtitleFontScale[] = ['0.75', '1', '1.25', '1.5'];

/** 覆盖层字幕底部间距（vp） */
export type SubtitleBottomMargin = '32' | '48' | '64' | '96';
export const SUBTITLE_BOTTOM_MARGIN_LABELS: SubtitleBottomMargin[] = ['32', '48', '64', '96'];

/** 覆盖层字幕字体颜色 */
export type SubtitleFontColor = 'white' | 'yellow' | 'green' | 'cyan';
export const SUBTITLE_FONT_COLOR_LABELS: SubtitleFontColor[] = ['white', 'yellow', 'green', 'cyan'];
export const SUBTITLE_FONT_COLOR_VALUES: Record<SubtitleFontColor, string> = {
  'white': '#FFFFFF',
  'yellow': '#FFEB3B',
  'green': '#4CAF50',
  'cyan': '#00E5FF',
};

/** 覆盖层字幕背景样式 */
export type SubtitleBackground = 'semi' | 'solid' | 'none';
export const SUBTITLE_BACKGROUND_LABELS: SubtitleBackground[] = ['semi', 'solid', 'none'];
export const SUBTITLE_BACKGROUND_VALUES: Record<SubtitleBackground, string> = {
  'semi': '#80000000',
  'solid': '#D9000000',
  'none': '#00000000',
};

/** 字幕延迟档位（毫秒，正值 = 字幕延后显示，mpv sub-delay 语义） */
export const SUBTITLE_OFFSET_VALUES: number[] = [-1000, -500, -250, 0, 250, 500, 1000];

export function getSubtitleOffsetDisplay(value: number): string {
  if (value === 0) return '0s';
  const sign = value > 0 ? '+' : '-';
  const abs = Math.abs(value);
  return `${sign}${abs >= 1000 ? `${abs / 1000}` : `0.${abs / 10}`}s`;
}

export function getSubtitleFontColorDisplay(value: SubtitleFontColor): Resource {
  return $r(`app.string.yt_subtitle_color_${value}`);
}

export function getSubtitleBackgroundDisplay(value: SubtitleBackground): Resource {
  return $r(`app.string.yt_subtitle_bg_${value}`);
}

export function getHoldSpeedDelayDisplay(value: number): string {
  return value >= 1000 ? `${value / 1000}s` : `${value}ms`;
}

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
  /** Full-surface swipe shortcuts. Visible controls remain available when disabled. */
  gestureSeekEnabled: boolean = true;
  gestureBrightnessEnabled: boolean = true;
  gestureVolumeEnabled: boolean = true;
  /** 长按屏幕临时加速（松手恢复原倍速） */
  holdSpeedEnabled: boolean = true;
  /** 长按加速的目标倍速 */
  holdSpeedValue: number = 2.0;
  /** 长按多久触发加速（毫秒） */
  holdSpeedDelayMs: number = 500;
  /** 返回键/home 键时是否自动进入画中画（设备不支持时强制 false） */
  pipOnReturn: boolean = true;
  /**
   * 真后台时延迟关闭视频解码，仅保留音频（省电）。
   * 分享/投屏/PiP 不会关视频。回前台自动恢复。
   */
  backgroundAudioOnly: boolean = true;
  /** 进入后台后多久关视频（秒），0=立即 */
  backgroundVideoOffDelaySec: BackgroundVideoOffDelay = '15';
  /** 是否继续播放下一个视频（每次启动时作为队列自动播放会话开关的默认值） */
  autoPlayNext: boolean = true;

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
  /** 游客（未登录/未启用播放鉴权）时的 YouTube 播放端点 */
  guestPlayerClient: GuestPlayerClient = 'visionos';
  /** 登录（且启用播放鉴权）时的 YouTube 播放端点 */
  authPlayerClient: AuthPlayerClient = 'mweb';
  /** 覆盖层字幕字号倍率 */
  subtitleFontScale: SubtitleFontScale = '1';
  /** 覆盖层字幕底部间距（vp） */
  subtitleBottomMarginVp: SubtitleBottomMargin = '48';
  /** 覆盖层字幕字体颜色 */
  subtitleFontColor: SubtitleFontColor = 'white';
  /** 覆盖层字幕背景样式 */
  subtitleBackground: SubtitleBackground = 'semi';
  /** 字幕延迟（毫秒，正值 = 延后显示） */
  subtitleOffsetMs: number = 0;
  /** 系统 AI 字幕（Speech Kit AICaptionComponent 自动捕获应用音频；仅支持的机型/地区生效） */
  systemAiCaption: boolean = false;
  /** 系统 AI 字幕源语言（'zh'|'en'；英文源输出中英双语） */
  systemAiCaptionSource: string = 'en';

  constructor() {}

  clone(): PlaybackConfig {
    const next = new PlaybackConfig();
    next.defaultQuality = this.defaultQuality;
    next.mobileQuality = this.mobileQuality;
    next.gestureSeekEnabled = this.gestureSeekEnabled;
    next.gestureBrightnessEnabled = this.gestureBrightnessEnabled;
    next.gestureVolumeEnabled = this.gestureVolumeEnabled;
    next.holdSpeedEnabled = this.holdSpeedEnabled;
    next.holdSpeedValue = this.holdSpeedValue;
    next.holdSpeedDelayMs = this.holdSpeedDelayMs;
    next.pipOnReturn = this.pipOnReturn;
    next.backgroundAudioOnly = this.backgroundAudioOnly;
    next.backgroundVideoOffDelaySec = this.backgroundVideoOffDelaySec;
    next.autoPlayNext = this.autoPlayNext;
    next.hwdecEnabled = this.hwdecEnabled;
    next.cacheSecs = this.cacheSecs;
    next.demuxerReadaheadSecs = this.demuxerReadaheadSecs;
    next.demuxerMaxBytes = this.demuxerMaxBytes;
    next.gpuApi = this.gpuApi;
    next.guestPlayerClient = this.guestPlayerClient;
    next.authPlayerClient = this.authPlayerClient;
    next.subtitleFontScale = this.subtitleFontScale;
    next.subtitleBottomMarginVp = this.subtitleBottomMarginVp;
    next.subtitleFontColor = this.subtitleFontColor;
    next.subtitleBackground = this.subtitleBackground;
    next.subtitleOffsetMs = this.subtitleOffsetMs;
    next.systemAiCaption = this.systemAiCaption;
    next.systemAiCaptionSource = this.systemAiCaptionSource;
    return next;
  }

  static loadFromPreferences(): PlaybackConfig {
    const cfg = new PlaybackConfig();
    cfg.defaultQuality = normalizeQuality(PreferencesStore.getString('cfg_pb_defaultQuality', '480p'), '480p');
    cfg.mobileQuality = normalizeQuality(PreferencesStore.getString('cfg_pb_mobileQuality', '480p'), '480p');
    cfg.gestureSeekEnabled = PreferencesStore.getString('cfg_pb_gestureSeekEnabled', 'true') === 'true';
    cfg.gestureBrightnessEnabled = PreferencesStore.getString('cfg_pb_gestureBrightnessEnabled', 'true') === 'true';
    cfg.gestureVolumeEnabled = PreferencesStore.getString('cfg_pb_gestureVolumeEnabled', 'true') === 'true';
    cfg.holdSpeedEnabled = PreferencesStore.getString('cfg_pb_holdSpeedEnabled', 'true') === 'true';
    const holdSpeedValue = Number(PreferencesStore.getString('cfg_pb_holdSpeedValue', '2'));
    cfg.holdSpeedValue = HOLD_SPEED_VALUES.includes(holdSpeedValue) ? holdSpeedValue : 2.0;
    const holdSpeedDelay = Number(PreferencesStore.getString('cfg_pb_holdSpeedDelayMs', '500'));
    cfg.holdSpeedDelayMs = HOLD_SPEED_DELAYS.includes(holdSpeedDelay) ? holdSpeedDelay : 500;
    cfg.pipOnReturn = PreferencesStore.getString('cfg_pb_pipOnReturn', 'true') === 'true';
    cfg.backgroundAudioOnly = PreferencesStore.getString('cfg_pb_backgroundAudioOnly', 'true') === 'true';
    const delay = PreferencesStore.getString('cfg_pb_backgroundVideoOffDelaySec', '15');
    cfg.backgroundVideoOffDelaySec = BACKGROUND_VIDEO_OFF_DELAY_LABELS.includes(delay as BackgroundVideoOffDelay)
      ? delay as BackgroundVideoOffDelay : '15';
    cfg.autoPlayNext = PreferencesStore.getString('cfg_pb_autoPlayNext', 'true') === 'true';

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
    const guestClient = PreferencesStore.getString('cfg_pb_guestPlayerClient', 'visionos');
    cfg.guestPlayerClient = GUEST_PLAYER_CLIENT_LABELS.includes(guestClient as GuestPlayerClient)
      ? guestClient as GuestPlayerClient : 'visionos';
    const authClient = PreferencesStore.getString('cfg_pb_authPlayerClient', 'mweb');
    cfg.authPlayerClient = AUTH_PLAYER_CLIENT_LABELS.includes(authClient as AuthPlayerClient)
      ? authClient as AuthPlayerClient : 'mweb';
    const subScale = PreferencesStore.getString('cfg_pb_subtitleFontScale', '1');
    cfg.subtitleFontScale = SUBTITLE_FONT_SCALE_LABELS.includes(subScale as SubtitleFontScale)
      ? subScale as SubtitleFontScale : '1';
    const subMargin = PreferencesStore.getString('cfg_pb_subtitleBottomMarginVp', '48');
    cfg.subtitleBottomMarginVp = SUBTITLE_BOTTOM_MARGIN_LABELS.includes(subMargin as SubtitleBottomMargin)
      ? subMargin as SubtitleBottomMargin : '48';
    const subColor = PreferencesStore.getString('cfg_pb_subtitleFontColor', 'white');
    cfg.subtitleFontColor = SUBTITLE_FONT_COLOR_LABELS.includes(subColor as SubtitleFontColor)
      ? subColor as SubtitleFontColor : 'white';
    const subBg = PreferencesStore.getString('cfg_pb_subtitleBackground', 'semi');
    cfg.subtitleBackground = SUBTITLE_BACKGROUND_LABELS.includes(subBg as SubtitleBackground)
      ? subBg as SubtitleBackground : 'semi';
    const subOffset = Number(PreferencesStore.getString('cfg_pb_subtitleOffsetMs', '0'));
    cfg.subtitleOffsetMs = SUBTITLE_OFFSET_VALUES.includes(subOffset) ? subOffset : 0;
    cfg.systemAiCaption = PreferencesStore.getString('cfg_pb_systemAiCaption', 'false') === 'true';
    const aiCaptionSrc = PreferencesStore.getString('cfg_pb_systemAiCaptionSource', 'en');
    cfg.systemAiCaptionSource = (aiCaptionSrc === 'zh' || aiCaptionSrc === 'en') ? aiCaptionSrc : 'en';

    logger.info(`Loaded PlaybackConfig: ${JSON.stringify(cfg)}`);
    return cfg;
  }

  static saveToPreferences(cfg: PlaybackConfig): void {
    PreferencesStore.setString('cfg_pb_defaultQuality', cfg.defaultQuality);
    PreferencesStore.setString('cfg_pb_mobileQuality', cfg.mobileQuality);
    PreferencesStore.setString('cfg_pb_gestureSeekEnabled', cfg.gestureSeekEnabled ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_gestureBrightnessEnabled', cfg.gestureBrightnessEnabled ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_gestureVolumeEnabled', cfg.gestureVolumeEnabled ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_holdSpeedEnabled', cfg.holdSpeedEnabled ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_holdSpeedValue', String(cfg.holdSpeedValue));
    PreferencesStore.setString('cfg_pb_holdSpeedDelayMs', String(cfg.holdSpeedDelayMs));
    PreferencesStore.setString('cfg_pb_pipOnReturn', cfg.pipOnReturn ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_backgroundAudioOnly', cfg.backgroundAudioOnly ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_backgroundVideoOffDelaySec', cfg.backgroundVideoOffDelaySec);
    PreferencesStore.setString('cfg_pb_autoPlayNext', cfg.autoPlayNext ? 'true' : 'false');

    // MPV 播放器设置
    PreferencesStore.setString('cfg_pb_hwdecEnabled', cfg.hwdecEnabled ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_cacheSecs', cfg.cacheSecs);
    PreferencesStore.setString('cfg_pb_demuxerReadaheadSecs', cfg.demuxerReadaheadSecs);
    PreferencesStore.setString('cfg_pb_demuxerMaxBytes', cfg.demuxerMaxBytes);
    PreferencesStore.setString('cfg_pb_gpuApi', cfg.gpuApi);
    PreferencesStore.setString('cfg_pb_guestPlayerClient', cfg.guestPlayerClient);
    PreferencesStore.setString('cfg_pb_authPlayerClient', cfg.authPlayerClient);
    PreferencesStore.setString('cfg_pb_subtitleFontScale', cfg.subtitleFontScale);
    PreferencesStore.setString('cfg_pb_subtitleBottomMarginVp', cfg.subtitleBottomMarginVp);
    PreferencesStore.setString('cfg_pb_subtitleFontColor', cfg.subtitleFontColor);
    PreferencesStore.setString('cfg_pb_subtitleBackground', cfg.subtitleBackground);
    PreferencesStore.setString('cfg_pb_subtitleOffsetMs', String(cfg.subtitleOffsetMs));
    PreferencesStore.setString('cfg_pb_systemAiCaption', cfg.systemAiCaption ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_systemAiCaptionSource', cfg.systemAiCaptionSource);

    logger.info('Saved PlaybackConfig');
  }
}
