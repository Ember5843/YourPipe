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

/** 游客态播放端点：visionos（默认，免 token 直链）| mweb（SABR，调试用）。 */
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

/** 手势交互方案预设（一次性套用模板，不与下方分项开关耦合）：enhanced=播放器增强、youtube=YouTube 经典、bilibili=Bilibili 经典 */
export type GesturePreset = 'enhanced' | 'youtube' | 'bilibili';
export const GESTURE_PRESET_LABELS: GesturePreset[] = ['enhanced', 'youtube', 'bilibili'];

/** 双击屏幕的动作（与左右快进退互斥：单选，天然避免手势冲突） */
export type DoubleTapAction = 'seek' | 'playpause' | 'off';
export const DOUBLE_TAP_ACTION_LABELS: DoubleTapAction[] = ['seek', 'playpause', 'off'];

/** 双击快退/快进的步长（秒）——对齐 YouTube 可选范围（5–60s） */
export const DOUBLE_TAP_SEEK_SECONDS: number[] = [5, 10, 15, 20, 30, 60];

export function getGestureSchemeDisplay(value: GesturePreset): Resource {
  return $r(`app.string.yt_gesture_scheme_${value}`);
}

export function getDoubleTapActionDisplay(value: DoubleTapAction): Resource {
  return $r(`app.string.yt_gesture_double_tap_${value}`);
}

export function getDoubleTapSeekDisplay(value: number): string {
  return `${value}s`;
}

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

/** 覆盖层字幕背景样式（历史 3 档键，保留供迁移与旧设置项兼容） */
export type SubtitleBackground = 'semi' | 'solid' | 'none';
export const SUBTITLE_BACKGROUND_LABELS: SubtitleBackground[] = ['semi', 'solid', 'none'];
export const SUBTITLE_BACKGROUND_VALUES: Record<SubtitleBackground, string> = {
  'semi': '#80000000',
  'solid': '#D9000000',
  'none': '#00000000',
};

/** 覆盖层字幕边缘样式：描边+阴影 / 纯描边 / 仅阴影 / 无 */
export type SubtitleEdgeStyle = 'outline_shadow' | 'outline' | 'shadow' | 'none';
export const SUBTITLE_EDGE_STYLE_LABELS: SubtitleEdgeStyle[] = ['outline_shadow', 'outline', 'shadow', 'none'];

/** 覆盖层字幕背景不透明度离散档位（0=无背景 .. 1.0=纯黑不透明） */
export const SUBTITLE_BG_OPACITY_VALUES: number[] = [0, 0.35, 0.6, 0.85, 1.0];

export function normalizeSubtitleBgOpacity(value: number): number {
  if (!Number.isFinite(value)) {
    return 0.6;
  }
  let closest: number = SUBTITLE_BG_OPACITY_VALUES[0];
  let bestDiff: number = Math.abs(value - closest);
  for (let i = 1; i < SUBTITLE_BG_OPACITY_VALUES.length; i++) {
    const candidate = SUBTITLE_BG_OPACITY_VALUES[i];
    const diff = Math.abs(value - candidate);
    if (diff < bestDiff) {
      closest = candidate;
      bestDiff = diff;
    }
  }
  return closest;
}

/** 字幕延迟范围与预设档位（毫秒，正值 = 字幕延后显示，mpv sub-delay 语义） */
export const SUBTITLE_OFFSET_MIN_MS: number = -5000;
export const SUBTITLE_OFFSET_MAX_MS: number = 5000;
export const SUBTITLE_OFFSET_VALUES: number[] = [-1000, -500, -250, 0, 250, 500, 1000];

export function clampSubtitleOffsetMs(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  const rounded = Math.round(value);
  if (rounded < SUBTITLE_OFFSET_MIN_MS) {
    return SUBTITLE_OFFSET_MIN_MS;
  }
  if (rounded > SUBTITLE_OFFSET_MAX_MS) {
    return SUBTITLE_OFFSET_MAX_MS;
  }
  return rounded === 0 ? 0 : rounded;
}

export function getSubtitleOffsetDisplay(value: number): string {
  const clamped = clampSubtitleOffsetMs(value);
  if (clamped === 0) return '0s';
  const sign = clamped > 0 ? '+' : '-';
  const abs = Math.abs(clamped);
  if (abs % 1000 === 0) {
    return `${sign}${abs / 1000}s`;
  }
  const formatted = (abs / 1000).toFixed(2).replace(/0$/, '');
  return `${sign}${formatted}s`;
}

/** MPV 原生音画延迟范围与步长（毫秒） */
export const AUDIO_DELAY_MIN_MS: number = -1000;
export const AUDIO_DELAY_MAX_MS: number = 1000;
export const AUDIO_DELAY_STEP_MS: number = 50;

export function clampAudioDelayMs(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  const rounded = Math.round(value);
  if (rounded < AUDIO_DELAY_MIN_MS) {
    return AUDIO_DELAY_MIN_MS;
  }
  if (rounded > AUDIO_DELAY_MAX_MS) {
    return AUDIO_DELAY_MAX_MS;
  }
  return rounded === 0 ? 0 : rounded;
}

export function getAudioDelayDisplay(valueMs: number): string {
  const clamped = clampAudioDelayMs(valueMs);
  if (clamped === 0) {
    return '0ms';
  }
  return `${clamped > 0 ? '+' : ''}${clamped}ms`;
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

@Observed
export class PlaybackConfig {
  @Track defaultQuality: VideoQualityCap = '480p';
  @Track mobileQuality: VideoQualityCap = '480p';
  /** Full-surface swipe shortcuts. Visible controls remain available when disabled. */
  @Track gestureSeekEnabled: boolean = true;
  @Track gestureBrightnessEnabled: boolean = true;
  @Track gestureVolumeEnabled: boolean = true;
  /** 长按屏幕临时加速（松手恢复原倍速） */
  @Track holdSpeedEnabled: boolean = true;
  /** 长按加速的目标倍速 */
  @Track holdSpeedValue: number = 2.0;
  /** 长按多久触发加速（毫秒） */
  @Track holdSpeedDelayMs: number = 500;
  /** 双击屏幕的动作：左右快进退 / 播放暂停 / 关闭 */
  @Track doubleTapAction: DoubleTapAction = 'seek';
  /** 双击快进退步长（秒），仅 doubleTapAction='seek' 时生效 */
  @Track doubleTapSeekSeconds: number = 15;
  /** 返回键/home 键时是否自动进入画中画（设备不支持时强制 false） */
  @Track pipOnReturn: boolean = true;
  /**
   * 真后台时延迟关闭视频解码，仅保留音频（省电）。
   * 分享/投屏/PiP 不会关视频。回前台自动恢复。
   */
  @Track backgroundAudioOnly: boolean = true;
  /** 进入后台后多久关视频（秒），0=立即 */
  @Track backgroundVideoOffDelaySec: BackgroundVideoOffDelay = '15';
  /** 是否继续播放下一个视频（每次启动时作为队列自动播放会话开关的默认值） */
  @Track autoPlayNext: boolean = true;

  // MPV 播放器设置
  /** 硬件解码开关 */
  @Track hwdecEnabled: boolean = true;
  /** 内存缓存时长（秒） */
  @Track cacheSecs: CacheSecs = '10';
  /** 预读缓冲时长（秒） */
  @Track demuxerReadaheadSecs: DemuxerReadahead = '8';
  /** 解封装器最大缓冲区（MB） */
  @Track demuxerMaxBytes: DemuxerMaxBytes = '20';
  /** GPU 渲染 API */
  @Track gpuApi: GpuApi = 'auto';
  /** 游客（未登录/未启用播放鉴权）时的 YouTube 播放端点 */
  @Track guestPlayerClient: GuestPlayerClient = 'visionos';
  /** 登录（且启用播放鉴权）时的 YouTube 播放端点 */
  @Track authPlayerClient: AuthPlayerClient = 'mweb';
  /** 字幕总开关（与 subtitlePreferredTrack 解耦：关闭时保留偏好语言，一键 CC 可恢复） */
  @Track subtitleEnabled: boolean = false;
  /** 字幕偏好轨道键：'' | 'original' | 'lang|manual' | 'lang|auto' */
  @Track subtitlePreferredTrack: string = '';
  /** 双语副字幕偏好轨道键：''（关闭）| 'lang|manual' | 'lang|auto' */
  @Track secondarySubtitleTrack: string = '';
  /** 覆盖层字幕字号倍率 */
  @Track subtitleFontScale: SubtitleFontScale = '1';
  /** 覆盖层字幕底部间距（vp） */
  @Track subtitleBottomMarginVp: SubtitleBottomMargin = '48';
  /** 覆盖层字幕字体颜色 */
  @Track subtitleFontColor: SubtitleFontColor = 'white';
  /** 覆盖层字幕背景样式（历史字段，保留兼容） */
  @Track subtitleBackground: SubtitleBackground = 'semi';
  /** 覆盖层字幕边缘样式：'outline_shadow' | 'outline' | 'shadow' | 'none' */
  @Track subtitleEdgeStyle: SubtitleEdgeStyle = 'outline_shadow';
  /** 覆盖层字幕粗体开关 */
  @Track subtitleBold: boolean = false;
  /** 覆盖层字幕背景不透明度（离散档位 0 / 0.35 / 0.6 / 0.85 / 1.0） */
  @Track subtitleBgOpacity: number = 0.6;
  /** 字幕延迟（毫秒，正值 = 延后显示） */
  @Track subtitleOffsetMs: number = 0;
  /** 系统 AI 字幕（Speech Kit AICaptionComponent 自动捕获应用音频；仅支持的机型/地区生效） */
  @Track systemAiCaption: boolean = false;
  /** 系统 AI 字幕源语言（'zh'|'en'；英文源输出中英双语） */
  @Track systemAiCaptionSource: string = 'en';
  /** MPV 原生响度均衡（acompressor + alimiter） */
  @Track audioNormalizeEnabled: boolean = false;
  /** MPV 原生音画延迟（毫秒，范围 -1000..1000） */
  @Track audioDelayMs: number = 0;

  constructor() {}

  /** 就地复位全部播放配置到默认值（遵循 ArkUI V1 @Observed/@Track 就地修改规范）。 */
  resetToDefaults(): void {
    this.defaultQuality = '480p';
    this.mobileQuality = '480p';
    this.gestureSeekEnabled = true;
    this.gestureBrightnessEnabled = true;
    this.gestureVolumeEnabled = true;
    this.holdSpeedEnabled = true;
    this.holdSpeedValue = 2.0;
    this.holdSpeedDelayMs = 500;
    this.doubleTapAction = 'seek';
    this.doubleTapSeekSeconds = 15;
    this.pipOnReturn = true;
    this.backgroundAudioOnly = true;
    this.backgroundVideoOffDelaySec = '15';
    this.autoPlayNext = true;
    this.hwdecEnabled = true;
    this.cacheSecs = '10';
    this.demuxerReadaheadSecs = '8';
    this.demuxerMaxBytes = '20';
    this.gpuApi = 'auto';
    this.guestPlayerClient = 'visionos';
    this.authPlayerClient = 'mweb';
    this.subtitleEnabled = false;
    this.subtitlePreferredTrack = '';
    this.secondarySubtitleTrack = '';
    this.subtitleFontScale = '1';
    this.subtitleBottomMarginVp = '48';
    this.subtitleFontColor = 'white';
    this.subtitleBackground = 'semi';
    this.subtitleEdgeStyle = 'outline_shadow';
    this.subtitleBold = false;
    this.subtitleBgOpacity = 0.6;
    this.subtitleOffsetMs = 0;
    this.systemAiCaption = false;
    this.systemAiCaptionSource = 'en';
    this.audioNormalizeEnabled = false;
    this.audioDelayMs = 0;
  }

  /**
   * 手势方案预设：一次性写回各分项开关（双击单选 + 滑动组 + 长按组），不与分项开关反向耦合。
   * enhanced = 播放器增强（双击 ±15s、横滑进度、左亮右音、长按 2x、关闭中央播放按钮）；
   * youtube  = YouTube 经典（双击 ±10s、无横滑/亮度/音量滑、长按 2x、开启中央播放按钮）；
   * bilibili = Bilibili 经典（双击播放/暂停、横滑进度、左亮右音、长按加速、关闭中央播放按钮）。
   */
  static applyGesturePreset(cfg: PlaybackConfig, preset: GesturePreset): void {
    if (preset === 'enhanced') {
      cfg.doubleTapAction = 'seek';
      cfg.doubleTapSeekSeconds = 15;
      cfg.gestureSeekEnabled = true;
      cfg.gestureBrightnessEnabled = true;
      cfg.gestureVolumeEnabled = true;
      cfg.holdSpeedEnabled = true;
    } else if (preset === 'youtube') {
      cfg.doubleTapAction = 'seek';
      cfg.doubleTapSeekSeconds = 10;
      cfg.gestureSeekEnabled = false;
      cfg.gestureBrightnessEnabled = false;
      cfg.gestureVolumeEnabled = false;
      cfg.holdSpeedEnabled = true;
    } else if (preset === 'bilibili') {
      cfg.doubleTapAction = 'playpause';
      cfg.gestureSeekEnabled = true;
      cfg.gestureBrightnessEnabled = true;
      cfg.gestureVolumeEnabled = true;
      cfg.holdSpeedEnabled = true;
    }
  }

  /** 各手势预设对应的中央播放按钮开关：仅 YouTube 经典默认开启，其余关闭。 */
  static centerPlayButtonForPreset(preset: GesturePreset): boolean {
    return preset === 'youtube';
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
    const doubleTapRaw = PreferencesStore.getString('cfg_pb_doubleTapAction', 'seek');
    cfg.doubleTapAction = DOUBLE_TAP_ACTION_LABELS.includes(doubleTapRaw as DoubleTapAction)
      ? doubleTapRaw as DoubleTapAction : 'seek';
    const doubleTapSecs = Number(PreferencesStore.getString('cfg_pb_doubleTapSeekSeconds', '15'));
    cfg.doubleTapSeekSeconds = DOUBLE_TAP_SEEK_SECONDS.includes(doubleTapSecs) ? doubleTapSecs : 15;
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
    // 游客端点只保留 visionos（默认）与 mweb。旧版本可能存过 tv_samsung，
    // 或存过已被移除的其它值：统一回落到 visionos 并写回，避免下次再读旧值。
    const guestClient = PreferencesStore.getString('cfg_pb_guestPlayerClient', 'visionos');
    const resolvedGuestClient = GUEST_PLAYER_CLIENT_LABELS.includes(guestClient as GuestPlayerClient)
      ? guestClient as GuestPlayerClient : 'visionos';
    if (resolvedGuestClient !== guestClient) {
      PreferencesStore.setString('cfg_pb_guestPlayerClient', resolvedGuestClient);
      logger.info(`guest endpoint migrated ${guestClient} -> ${resolvedGuestClient}`);
    }
    cfg.guestPlayerClient = resolvedGuestClient;
    const authClient = PreferencesStore.getString('cfg_pb_authPlayerClient', 'mweb');
    cfg.authPlayerClient = AUTH_PLAYER_CLIENT_LABELS.includes(authClient as AuthPlayerClient)
      ? authClient as AuthPlayerClient : 'mweb';
    const MISSING_PREF = '__yp_missing__';
    const subEnabledRaw = PreferencesStore.getString('cfg_pb_subtitleEnabled', MISSING_PREF);
    const subPrefTrackRaw = PreferencesStore.getString('cfg_pb_subtitlePreferredTrack', MISSING_PREF);
    if (subEnabledRaw === MISSING_PREF && subPrefTrackRaw === MISSING_PREF) {
      // 从旧单键 cfg_subtitle_preferred_lang 平滑迁移到「开关 + 偏好轨道」解耦模型
      const legacyLang = PreferencesStore.getString('cfg_subtitle_preferred_lang', '').trim();
      if (legacyLang.length > 0) {
        if (legacyLang.startsWith('ai:')) {
          const target = legacyLang.substring(3).trim();
          cfg.subtitleEnabled = target.length > 0;
          cfg.subtitlePreferredTrack = target.length > 0 ? `${target}|manual` : '';
        } else {
          cfg.subtitleEnabled = true;
          cfg.subtitlePreferredTrack = (legacyLang.includes('|') || legacyLang === 'original')
            ? legacyLang : `${legacyLang}|manual`;
        }
        PreferencesStore.setString('cfg_pb_subtitleEnabled', cfg.subtitleEnabled ? 'true' : 'false');
        PreferencesStore.setString('cfg_pb_subtitlePreferredTrack', cfg.subtitlePreferredTrack);
        logger.info(`subtitle pref migrated ${legacyLang} -> enabled=${cfg.subtitleEnabled} track=${cfg.subtitlePreferredTrack}`);
      } else {
        cfg.subtitleEnabled = false;
        cfg.subtitlePreferredTrack = '';
      }
    } else {
      cfg.subtitleEnabled = subEnabledRaw === 'true';
      cfg.subtitlePreferredTrack = subPrefTrackRaw === MISSING_PREF ? '' : subPrefTrackRaw.trim();
    }
    cfg.secondarySubtitleTrack = PreferencesStore.getString('cfg_pb_secondarySubtitleTrack', '').trim();
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
    const subEdgeRaw = PreferencesStore.getString('cfg_pb_subtitleEdgeStyle', 'outline_shadow');
    cfg.subtitleEdgeStyle = SUBTITLE_EDGE_STYLE_LABELS.includes(subEdgeRaw as SubtitleEdgeStyle)
      ? subEdgeRaw as SubtitleEdgeStyle : 'outline_shadow';
    cfg.subtitleBold = PreferencesStore.getString('cfg_pb_subtitleBold', 'false') === 'true';
    const subBgOpacityRaw = PreferencesStore.getString('cfg_pb_subtitleBgOpacity', MISSING_PREF);
    if (subBgOpacityRaw === MISSING_PREF) {
      // 新键缺失时从旧 subtitleBackground 迁移默认透明度
      if (cfg.subtitleBackground === 'none') {
        cfg.subtitleBgOpacity = 0;
      } else if (cfg.subtitleBackground === 'solid') {
        cfg.subtitleBgOpacity = 0.85;
      } else {
        cfg.subtitleBgOpacity = 0.6;
      }
    } else {
      cfg.subtitleBgOpacity = normalizeSubtitleBgOpacity(Number(subBgOpacityRaw));
    }
    const subOffset = Number(PreferencesStore.getString('cfg_pb_subtitleOffsetMs', '0'));
    cfg.subtitleOffsetMs = clampSubtitleOffsetMs(subOffset);
    cfg.systemAiCaption = PreferencesStore.getString('cfg_pb_systemAiCaption', 'false') === 'true';
    const aiCaptionSrc = PreferencesStore.getString('cfg_pb_systemAiCaptionSource', 'en');
    cfg.systemAiCaptionSource = (aiCaptionSrc === 'zh' || aiCaptionSrc === 'en') ? aiCaptionSrc : 'en';
    cfg.audioNormalizeEnabled = PreferencesStore.getString('cfg_pb_audioNormalizeEnabled', 'false') === 'true';
    const audioDelayRaw = Number(PreferencesStore.getString('cfg_pb_audioDelayMs', '0'));
    cfg.audioDelayMs = clampAudioDelayMs(audioDelayRaw);

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
    PreferencesStore.setString('cfg_pb_doubleTapAction', cfg.doubleTapAction);
    PreferencesStore.setString('cfg_pb_doubleTapSeekSeconds', String(cfg.doubleTapSeekSeconds));
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
    PreferencesStore.setString('cfg_pb_subtitleEnabled', cfg.subtitleEnabled ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_subtitlePreferredTrack', cfg.subtitlePreferredTrack);
    PreferencesStore.setString('cfg_pb_secondarySubtitleTrack', cfg.secondarySubtitleTrack);
    PreferencesStore.setString('cfg_pb_subtitleFontScale', cfg.subtitleFontScale);
    PreferencesStore.setString('cfg_pb_subtitleBottomMarginVp', cfg.subtitleBottomMarginVp);
    PreferencesStore.setString('cfg_pb_subtitleFontColor', cfg.subtitleFontColor);
    PreferencesStore.setString('cfg_pb_subtitleBackground', cfg.subtitleBackground);
    PreferencesStore.setString('cfg_pb_subtitleEdgeStyle', cfg.subtitleEdgeStyle);
    PreferencesStore.setString('cfg_pb_subtitleBold', cfg.subtitleBold ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_subtitleBgOpacity', String(normalizeSubtitleBgOpacity(cfg.subtitleBgOpacity)));
    PreferencesStore.setString('cfg_pb_subtitleOffsetMs', String(clampSubtitleOffsetMs(cfg.subtitleOffsetMs)));
    PreferencesStore.setString('cfg_pb_systemAiCaption', cfg.systemAiCaption ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_systemAiCaptionSource', cfg.systemAiCaptionSource);
    PreferencesStore.setString('cfg_pb_audioNormalizeEnabled', cfg.audioNormalizeEnabled ? 'true' : 'false');
    PreferencesStore.setString('cfg_pb_audioDelayMs', String(clampAudioDelayMs(cfg.audioDelayMs)));

    logger.info('Saved PlaybackConfig');
  }
}
