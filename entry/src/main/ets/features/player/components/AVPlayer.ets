/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { ColorMetrics, componentUtils, curves, LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { audio, AVVolumePanel } from '@kit.AudioKit';
import { i18n } from '@kit.LocalizationKit';
import { KeyCode } from '@kit.InputKit';
import { hdsEffect } from '@kit.UIDesignKit';
import { AICaptionComponent, AICaptionController, AICaptionOptions } from '@kit.SpeechKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { Logger, CommonConstants, secondToTime } from 'mediaservice';
import { ThemeColorUtil } from '../../../common/ThemeColorUtil';
import { MaterialUtil } from '../../../common/utils/MaterialUtil';
import { UIConfig } from '../../../common/AppState';
import {
  AvPlayerController,
  VideoData,
  StreamInfo,
  PlayerState,
  PlaybackState,
  StateChangeListener,
  VideoEntry,
  ChapterInfo,
  SubtitleTrack,
  SubtitleErrorKind,
  HeatmapPoint,
  StoryboardInfo,
  PlaybackStats
} from 'mediaservice';
import {
  StreamStatsLabels,
  resolveStreamStatsLabels,
  formatTransportSummary,
  formatHwdec,
  formatColorInfo,
  formatFrameRateSummary,
  formatAvSync,
  getAvSyncSeverity,
  formatDroppedFrames,
  formatBufferSummary,
  formatSpeedBps,
  formatBitrateBps,
  formatAudioChannelsShort,
  formatAudioFxSummary,
  buildDiagnosticReport,
  copyDiagnosticsToClipboard
} from '../StreamStatsFormatter';
import { PlayerEnvironmentService } from '../PlayerEnvironmentService';
import { ActionHub } from '../../../common/ActionHub';
import { PlayerSession } from '../../../common/PlayerSession';
import { SponsorBlockSkipper, SponsorSkipNotice } from '../../../common/experimental/SponsorBlockSkipper';
import { SponsorSegment } from '../../../common/experimental/SponsorBlockClient';
import { ExperimentalConfig } from '../../../common/experimental/ExperimentalConfig';
import { PlayerPresentation } from '../../../common/PlayerPresentation';
import { PiPManager } from '../pip/PiPManager';
import { PlayerUiViewModel } from 'mediaservice';
import { MediaThumb } from '../../../common/components/MediaThumb';
import { ItagItem, VideoItem } from 'youtube_core';
import {
  PlaybackConfig,
  SubtitleEdgeStyle,
  SUBTITLE_FONT_COLOR_VALUES,
  normalizeSubtitleBgOpacity
} from '../../../common/PlaybackConfig';
import { LanguageManager } from '../../../common/LanguageManager';
import {
  SeekBarTrackOverlay,
  SeekPreviewBubble,
  getSponsorCategoryColor,
  findNextJumpAheadPeak
} from './SeekBarOverlay';
import { PreferencesStore } from '../../../common/PreferencesStore';
import { LlmTranslateConfig } from '../../../common/LlmTranslateConfig';
import { TranslationService } from '../../../common/TranslationService';
import {
  SubtitleTranslationService,
  SubtitleTranslateProgress
} from '../translate/SubtitleTranslationService';
import { SabrBackoffNotice } from './SabrBackoffNotice';
// [DISABLED] P3 端侧 ASR 实时识别：产品只保留 P0 tlang 官方自动翻译轨（代码保留）
// import { AsrLiveCaptionService, AsrLiveProgress } from '../asr/AsrLiveCaptionService';

const TAG: string = '[PlayerLog][VideoPlayer]';
const GESTURE_LOCK_DISTANCE: number = 12;
const GESTURE_AXIS_DOMINANCE: number = 1.25;
const CONTROLS_HIDE_DELAY: number = 3000;
const SIDE_HINT_HIDE_DELAY: number = 800;
const SEEK_HINT_HIDE_DELAY: number = 200;
const DOUBLE_TAP_HINT_HIDE_DELAY: number = 800;
const JUMP_AHEAD_HIDE_DELAY_MS: number = 5000;
const OVERLAY_PILL_HEIGHT_VP: number = 42;
/** Max gap between two taps that still counts as one double-tap. TapGesture's
 *  fixed count cannot express "2nd, 4th, 6th …"; we count a single-tap stream
 *  manually so every pair fires (see onCenterTap). */
const DOUBLE_TAP_WINDOW_MS: number = 300;
const CONTROL_SLOT_SIZE: number = 40;
/** 中央播放按钮的可点判定半径（72vp 直径的一半 + 容差）。 */
const CENTER_PLAY_BUTTON_HIT_RADIUS: number = 44;
const SPEED_CONTROL_WIDTH: number = 48;
const CONTROL_SIDE_MIN: number = 24;
const CONTROL_SIDE_MAX: number = 36;
const CONTROL_SAFE_GAP: number = 12;
const CONTROL_VERTICAL_INSET: number = 16;
const FULLSCREEN_VERTICAL_INSET: number = 20;
const COMPACT_CONTROL_WIDTH: number = 360;
const PROGRESS_MIN_WIDTH: number = 32;
const TIMELINE_TEXT_MIN_WIDTH: number = 480;
const TIMELINE_TEXT_MIN_HEIGHT: number = 240;
/** 视频内边距的比例目标 = 视频显示高度的该比例（边距随视频区缩放，小屏不再绝对值顶到中部） */
const SUBTITLE_VIDEO_MARGIN_RATIO: number = 0.10;
/** 视频内边距下限（vp），极小窗口也不贴死底边 */
const SUBTITLE_MARGIN_MIN_VP: number = 12;
/** 字幕与控制条之间的最小间隙（vp） */
const SUBTITLE_BAR_GAP_VP: number = 8;
/** 拖动字幕时下移/上移的上限 = 视频显示高度的该比例 */
const SUBTITLE_DRAG_MAX_RATIO: number = 0.6;
/** 拖动字幕时水平偏移上限 = 容器宽度的该比例 */
const SUBTITLE_DRAG_X_MAX_RATIO: number = 0.35;
/** 顶部右侧工具条预估宽度超过容器一半时收成三横杠菜单 */
const TOP_TOOLS_HALF_RATIO: number = 0.5;

/** 视频显示区域在控制容器内的布局（letterbox 居中） */
interface VideoLayoutVp {
  letterboxVp: number;
  videoHVp: number;
  videoWVp: number;
}

/** 画面比例模式：fit=嵌入（等比全显）/ fill=填充（等比裁切铺满）/ stretch=拉伸（变形铺满） */
type VideoAspectMode = 'fit' | 'fill' | 'stretch';

/** 双指缩放上限倍率 */
const VIDEO_PINCH_MAX_SCALE: number = 4;
/** 双指手势判别：中点位移超过该值且主导 → 判定为平移（vp） */
const PINCH_DECIDE_VP: number = 10;
/** 双指手势判别：间距相对变化超过该比例且主导 → 判定为缩放 */
const PINCH_DECIDE_SCALE_RATIO: number = 0.08;

/** 画面缩放分量（模式基础 × 双指） */
interface VideoScaleXY {
  sx: number;
  sy: number;
}

/** 排序后的字幕菜单条目，保留在 vm.subtitleTracks 中的原始索引 */
interface SubtitleTrackMenuEntry {
  originalIndex: number;
  track: SubtitleTrack;
  label: string;
}

enum PlayerGestureMode {
  IDLE = 'idle',
  PENDING = 'pending',
  IGNORED = 'ignored',
  SEEK = 'seek',
  BRIGHTNESS = 'brightness',
  VOLUME = 'volume'
}

enum PlayerInteractionKind {
  NONE = 'none',
  PAN = 'pan',
  SLIDER = 'slider',
  MENU = 'menu'
}

@Preview
@Component
export struct VideoPlayer {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @Consume('actionHub') actionHub: ActionHub;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('playerGestureSafeTop') playerGestureSafeTop: number = 24;
  @StorageProp('playerGestureSafeBottom') playerGestureSafeBottom: number = 16;
  @StorageProp('playerGestureSafeLeft') playerGestureSafeLeft: number = 16;
  @StorageProp('playerGestureSafeRight') playerGestureSafeRight: number = 16;
  @StorageProp('playerControlAvoidTop') playerControlAvoidTop: number = 0;
  @StorageProp('playerControlAvoidBottom') playerControlAvoidBottom: number = 0;
  @StorageProp('playerControlAvoidLeft') playerControlAvoidLeft: number = 0;
  @StorageProp('playerControlAvoidRight') playerControlAvoidRight: number = 0;
  // Index Provide fallback when Storage statusBarHeight is 0 (bars hidden / mid-rotate).
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  @StorageProp('currentColorMode') currentColorMode: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  @Prop @Watch('onFullscreenModeChange') isFullLandscapeScreen: boolean = false;
  /** 强制全屏（分屏/挤压铺满，非用户手动全屏）时隐藏右下角全屏切换按钮——该状态下按钮无意义 */
  @Prop showFullscreenButton: boolean = true;
  @StorageProp('playerPageVisible') @Watch('onPageVisibilityChange') isPageShow: boolean = false;
  @StorageProp('isAppBackground') @Watch('onPageVisibilityChange') isAppBackground: boolean = false;
  /** 会话级仅音频：封面层在播控之下，不挡进度条/手势 */
  @StorageLink('isAudioOnlyMode') isAudioOnlyMode: boolean = false;
  /** 本地文件模式：隐藏在线字幕 / 章节 / 音轨 / 画质等 YouTube 专属入口。 */
  @StorageLink('isLocalMode') isLocalMode: boolean = false;
  @StorageLink('playbackConfig') playbackConfig: PlaybackConfig = new PlaybackConfig();
  @StorageLink('experimentalConfig') experimentalConfig: ExperimentalConfig = new ExperimentalConfig();
  @StorageProp('selectedVideo') selectedVideo: VideoItem | null = null;
  @Prop index: number = 0;
  @Link @Watch('onSourceChange') curSource: VideoData;
  @Prop chapters: ChapterInfo[] = [];
  @State storyboard: StoryboardInfo | undefined = undefined;
  @State heatmap: HeatmapPoint[] = [];
  @State sponsorSegments: SponsorSegment[] = [];
  @State jumpAheadTargetSec: number | null = null;
  private jumpAheadTimerId: number = -1;
  @State showChaptersSheet: boolean = false;
  /** In-player "Stats for Nerds" floating HUD overlay (persists across auto-hide & orientation). */
  @State showStatsOverlay: boolean = false;
  @State overlayStats: PlaybackStats | null = null;
  private statsOverlayTimerId: number = -1;
  private statsObservationController: AvPlayerController | null = null;
  private lastSourceVideoId: string = '';
  @Prop @Watch('onIndexChange') curIndex: number = CommonConstants.CURINDEX_DEFAULT_NUM;
  @State surfaceWidth: number = CommonConstants.SURFACE_WIDTH;
  @State surfaceHeight: number = CommonConstants.SURFACE_HEIGHT;
  @State containerWidthPX: number = 0;
  @State containerHeightPX: number = 0;

  @State trackThicknessSize: number = CommonConstants.TRACK_SIZE_MIN;
  @Link @Watch('onControllerChanged') controller: AvPlayerController;
  // ArkUI V1 的 @Track 不会穿透到嵌套 @Observed，因此 vm 必须由组件自己 @Link，
  // 才能让 vm 内部字段（isPlaying / isReady / ...）的变化触发 UI 重渲染。
  @Link vm: PlayerUiViewModel;
  private lastController?: AvPlayerController;
  @State hasStreams: boolean = false;
  @State hasError: boolean = false;
  @State playbackStarted: boolean = false;
  @State isWaitingForDualBuffer: boolean = false;
  // currentTime/durationTime 通过节流后的 ProgressSubscriber 更新（避免高频 @Track 触发 UI 重渲染）
  @State currentTime: number = 0;
  @State durationTime: number = 0;

  /**
   * 状态机监听器：在 PLAYING/BUFFERING/READY 时保持屏幕常亮，
   * 其余状态（PAUSED/COMPLETED/ERROR/IDLE/RELEASED）释放常亮，让系统正常息屏。
   *
   * 旧实现把 onPlayingChanged 写成 "@Watch" 风格但从未注册，
   * 导致 setWindowKeepScreenOn 永远不会被调用、播放中息屏。
   */
  private keepScreenListener: StateChangeListener = new KeepScreenOnStateListener(this);

  // 由 KeepScreenOnStateListener 调用，集中管理屏幕常亮策略。
  public _onKeepScreenStateChanged(to: PlayerState): void {
    const shouldKeepOn: boolean = to === PlayerState.PLAYING
      || to === PlayerState.BUFFERING
      || to === PlayerState.READY;
    this.envService.setKeepScreenOn(shouldKeepOn);
    if (to === PlayerState.PLAYING || to === PlayerState.BUFFERING) {
      this.scheduleHideControls();
    } else {
      this.clearHideTimer();
      this.showControls = true;
    }
  }

  private progressListener = (currentTime: number, durationTime: number) => {
    this.currentTime = currentTime;
    this.durationTime = durationTime;
    if (!this.playbackStarted && (currentTime > 0
      || (this.vm.isReady && this.vm.isPlaying && !this.vm.isBuffering))) {
      this.playbackStarted = true;
    }
  };

  private playbackExtrasListener = (source: VideoData): void => {
    if (!source) {
      return;
    }
    const curId = this.curSource.videoId || '';
    if (curId.length > 0 && source.videoId && source.videoId !== curId) {
      return;
    }
    this.storyboard = source.storyboard;
    this.heatmap = source.heatmap ? source.heatmap.slice() : [];
  };

  private sponsorSegmentsListener = (segments: SponsorSegment[]): void => {
    this.sponsorSegments = segments.slice();
  };

  private syncSeekbarMetadataFromSession(): void {
    const curId = this.curSource.videoId || '';
    const sessionSource = PlayerSession.getInstance().currentVideoSource;
    const sessionMatches = !!sessionSource && (curId.length === 0 || sessionSource.videoId === curId);
    const nextStoryboard = this.curSource.storyboard
      ?? (sessionMatches ? sessionSource.storyboard : undefined);
    const curHeatmap = this.curSource.heatmap && this.curSource.heatmap.length > 0
      ? this.curSource.heatmap : undefined;
    const sessionHeatmap = sessionMatches && sessionSource.heatmap && sessionSource.heatmap.length > 0
      ? sessionSource.heatmap : undefined;
    const nextHeatmap = curHeatmap ?? sessionHeatmap;
    this.storyboard = nextStoryboard;
    this.heatmap = nextHeatmap ? nextHeatmap.slice() : [];
  }

  private clearJumpAheadPill(): void {
    if (this.jumpAheadTimerId >= 0) {
      clearTimeout(this.jumpAheadTimerId);
      this.jumpAheadTimerId = -1;
    }
    this.jumpAheadTargetSec = null;
  }

  private maybeShowJumpAhead(referenceSec: number): void {
    const jumpEnabled = this.experimentalConfig.heatmapPluginEnabled && this.experimentalConfig.heatmapJumpAhead;
    if (!jumpEnabled || this.curSource.isLive || this.isLocalMode || this.skipNotice !== null || this.heatmap.length === 0) {
      this.clearJumpAheadPill();
      return;
    }
    const peakSec = findNextJumpAheadPeak(this.heatmap, referenceSec, this.durationTime);
    if (peakSec === null) {
      this.clearJumpAheadPill();
      return;
    }
    if (this.jumpAheadTimerId >= 0) {
      clearTimeout(this.jumpAheadTimerId);
      this.jumpAheadTimerId = -1;
    }
    this.jumpAheadTargetSec = peakSec;
    this.jumpAheadTimerId = setTimeout(() => {
      this.jumpAheadTimerId = -1;
      this.jumpAheadTargetSec = null;
    }, JUMP_AHEAD_HIDE_DELAY_MS);
  }

  private jumpAheadToPeak(): void {
    const target = this.jumpAheadTargetSec;
    this.clearJumpAheadPill();
    if (target === null) {
      return;
    }
    Logger.info(TAG, `Jump ahead to heatmap peak target=${target.toFixed(1)}s`);
    this.controller.syncSeek(target * 1000);
  }

  private currentChannelId(): string {
    return (this.curSource.channelId || this.selectedVideo?.channelId || '').trim();
  }

  private canToggleChannelWhitelist(): boolean {
    return !this.isLocalMode && !this.curSource.isLive
      && this.experimentalConfig.sponsorBlockEnabled
      && this.currentChannelId().length > 0;
  }

  private toggleCurrentChannelWhitelist(): void {
    const channelId = this.currentChannelId();
    if (channelId.length === 0) {
      return;
    }
    const whitelisted = this.experimentalConfig.toggleChannelWhitelist(channelId);
    this.experimentalConfig.saveToPreferences();
    const session = PlayerSession.getInstance();
    const skipper = SponsorBlockSkipper.getInstance();
    if (session.currentVideo && session.controller.isActive()) {
      skipper.reconnect(session.controller, session.currentVideo);
    } else {
      skipper.onPlaybackStopped();
    }
    this.getUIContext().getPromptAction().showToast({
      message: whitelisted
        ? $r('app.string.yt_exp_sb_channel_whitelisted')
        : $r('app.string.yt_exp_sb_channel_unwhitelisted'),
      duration: 2000
    });
    Logger.info(TAG, `SponsorBlock channel whitelist toggled channel=${channelId} whitelisted=${whitelisted}`);
  }

  private overlayPillBottomVp(): number {
    if (this.showControls) {
      return Math.max(this.bottomControlBarVpH + 12, 72);
    }
    return Math.min(84, Math.max(20, Math.round(this.containerVpHeight * 0.14)));
  }

  private previewBubbleBottomVp(): number {
    if (this.showControls) {
      return Math.max(this.bottomControlBarVpH + 10, 62);
    }
    return Math.max(24, Math.round(this.containerVpHeight * 0.34));
  }

  /** SponsorBlock 提示层：toast（可撤销）、manual（手动跳过）、poi（跳转精彩片段）。 */
  private skipNoticeListener = (notice: SponsorSkipNotice | null): void => {
    if (this.skipNoticeTimerId >= 0) {
      clearTimeout(this.skipNoticeTimerId);
      this.skipNoticeTimerId = -1;
    }
    if (notice !== null) {
      this.clearJumpAheadPill();
    }
    this.skipNotice = notice;
    if (!notice) {
      return;
    }
    if (notice.mode === 'manual') {
      // manual 按钮跟随片段生命周期，由 skipper 离开片段或用户点击/关闭时收起。
      return;
    }
    if (notice.mode === 'poi') {
      // 精彩片段提示限时展示 10 秒，超时后标记已处理并收起，不遮挡观影。
      this.skipNoticeTimerId = setTimeout(() => {
        this.skipNoticeTimerId = -1;
        SponsorBlockSkipper.getInstance().dismissNotice();
      }, 10000);
      return;
    }
    const config = AppStorage.get<ExperimentalConfig>('experimentalConfig');
    const seconds = config ? Math.max(1, config.sponsorUnskipSeconds) : 5;
    // 提示最多提前 seconds 秒出现；真正跳过或撤销时由 skipper 主动收起。
    // 这里的定时器只是兜底，避免异常路径下提示常驻。
    this.skipNoticeTimerId = setTimeout(() => {
      this.skipNotice = null;
      this.skipNoticeTimerId = -1;
    }, (seconds + 5) * 1000);
  };

  private skipCategoryLabel(category: string): string {
    const rm = getContext().resourceManager;
    let key: Resource = $r('app.string.yt_exp_sb_cat_sponsor');
    if (category === 'selfpromo') {
      key = $r('app.string.yt_exp_sb_cat_selfpromo');
    } else if (category === 'interaction') {
      key = $r('app.string.yt_exp_sb_cat_interaction');
    } else if (category === 'intro') {
      key = $r('app.string.yt_exp_sb_cat_intro');
    } else if (category === 'outro') {
      key = $r('app.string.yt_exp_sb_cat_outro');
    } else if (category === 'preview') {
      key = $r('app.string.yt_exp_sb_cat_preview');
    } else if (category === 'music_offtopic') {
      key = $r('app.string.yt_exp_sb_cat_music');
    } else if (category === 'filler') {
      key = $r('app.string.yt_exp_sb_cat_filler');
    } else if (category === 'poi_highlight') {
      key = $r('app.string.yt_exp_sb_cat_highlight');
    }
    return rm.getStringSync(key.id);
  }

  private clearLocalSkipNotice(): void {
    this.skipNotice = null;
    if (this.skipNoticeTimerId >= 0) {
      clearTimeout(this.skipNoticeTimerId);
      this.skipNoticeTimerId = -1;
    }
  }

  private undoSponsorSkip(): void {
    const undone = SponsorBlockSkipper.getInstance().undo();
    Logger.info(TAG, `sponsor skip undo tapped result=${undone}`);
    if (undone) {
      this.clearLocalSkipNotice();
    }
  }

  private skipManualSponsorSegment(): void {
    const skipped = SponsorBlockSkipper.getInstance().skipManual();
    Logger.info(TAG, `sponsor manual skip tapped result=${skipped}`);
    if (skipped) {
      this.clearLocalSkipNotice();
    }
  }

  private jumpToPoiHighlight(): void {
    const jumped = SponsorBlockSkipper.getInstance().jumpToPoi();
    Logger.info(TAG, `sponsor poi jump tapped result=${jumped}`);
    if (jumped) {
      this.clearLocalSkipNotice();
    }
  }

  private dismissSponsorNotice(): void {
    SponsorBlockSkipper.getInstance().dismissNotice();
    this.clearLocalSkipNotice();
    Logger.info(TAG, 'sponsor notice dismissed by user');
  }

  private sponsorActionNoticeText(notice: SponsorSkipNotice): ResourceStr {
    if (notice.mode === 'poi') {
      return $r('app.string.yt_exp_sb_jump_highlight');
    }
    const rm = this.getUIContext().getHostContext()?.resourceManager;
    if (!rm) {
      return $r('app.string.yt_exp_sb_cat_sponsor');
    }
    try {
      return rm.getStringSync(
        $r('app.string.yt_exp_sb_skip_manual').id,
        this.skipCategoryLabel(notice.category)
      );
    } catch (_e) {
      return $r('app.string.yt_exp_sb_cat_sponsor');
    }
  }

  private playbackStateListener = (state: PlaybackState) => {
    // PlaybackState is emitted continuously by the engine and closes the
    // timing gap where the state-machine transition happened before this page
    // registered its listener. Buffering must keep the display awake even when
    // the native player temporarily reports isPlaying=false.
    this.envService.setKeepScreenOn(state.isPlaying || state.isBuffering
      || state.engineState === 'buffering');
    if (!this.playbackStarted && state.isReady && state.isPlaying && !state.isBuffering) {
      this.playbackStarted = true;
      Logger.info(TAG, 'Playback started; startup cover dismissed');
    }
  };

  private syncPlaybackStateFromController(): void {
    if (!this.controller) {
      return;
    }
    // 移除主动刷新，依赖 PlayerStateRelay 的事件驱动
    // 仅在必要时同步最新值（如页面恢复、源切换）
    // isPlaying/isBuffering/isReady 由 @Track 自动同步到模板
    this.currentTime = this.vm.currentTime;
    this.durationTime = this.vm.durationTime;
  }

  private lastLoggedError: string = '';

  private errorListener = (errorMsg: string) => {
    if (errorMsg.length > 0 && errorMsg !== this.lastLoggedError) {
      Logger.info(TAG, `Error received: ${errorMsg}`);
      this.lastLoggedError = errorMsg;
    } else if (errorMsg.length === 0) {
      this.lastLoggedError = '';
    }
    this.hasError = errorMsg.length > 0;
    if (this.hasError) {
      this.clearHideTimer();
      this.showControls = true;
    }
  };

  private getErrorDisplay(errorMsg: string | undefined): string {
    const ctx = this.getUIContext().getHostContext();
    if (!errorMsg) {
      if (!ctx) return '[Player] Playback error, please retry';
      return '[Player] ' + ctx.resourceManager.getStringSync($r('app.string.yt_error_play_error_retry').id);
    }
    if (!ctx) return errorMsg;
    const rm = ctx.resourceManager;

    // 解析 [SOURCE] CODE 格式
    const match = errorMsg.match(/^\[(API|PLAYER)\]\s*(.+)/);
    if (match) {
      const source = match[1];
      const code = match[2];
      try {
        if (source === 'API') {
          switch (code) {
            case 'NO_PLAYABLE_STREAM': return '[API] ' + rm.getStringSync($r('app.string.yt_error_no_playable_stream').id);
            case 'NO_SUPPORTED_STREAM': return '[API] ' + rm.getStringSync($r('app.string.yt_error_no_supported_stream').id);
          }
        }
      } catch (e) {
        Logger.warn(TAG, `getErrorDisplay localization failed: ${e}`);
      }
      // 已知来源但无法本地化，返回原始带前缀的 CODE
      return errorMsg;
    }

    // 兼容旧格式（无前缀的内部码）
    switch (errorMsg) {
      case 'NO_PLAYABLE_STREAM':
        return '[API] ' + rm.getStringSync($r('app.string.yt_error_no_playable_stream').id);
      case 'NO_SUPPORTED_STREAM':
        return '[API] ' + rm.getStringSync($r('app.string.yt_error_no_supported_stream').id);
      default: return errorMsg;
    }
  }

  private waitingForBufferListener = (isWaiting: boolean) => {
    Logger.debug(TAG, `Waiting for dual buffer: ${isWaiting}`);
    this.isWaitingForDualBuffer = isWaiting;
  };
  private lastSubtitleErrorToastAtMs: number = 0;
  private lastSubtitleErrorKind: string = '';
  private subtitleErrorListener = (kind: SubtitleErrorKind): void => {
    const now = Date.now();
    if (kind === this.lastSubtitleErrorKind && now - this.lastSubtitleErrorToastAtMs < 1500) {
      return;
    }
    this.lastSubtitleErrorKind = kind;
    this.lastSubtitleErrorToastAtMs = now;
    Logger.warn(TAG, `Subtitle load error kind=${kind}`);
    try {
      this.getUIContext().getPromptAction().showToast({
        message: kind === 'rate_limited'
          ? $r('app.string.yt_player_subtitle_error_rate_limited')
          : $r('app.string.yt_player_subtitle_error_unavailable'),
        duration: 2800
      });
    } catch (e) {
      Logger.warn(TAG, `Subtitle error toast failed: ${e}`);
    }
  };
  @State showSubtitleMenu: boolean = false;
  @State showCollapsedSubtitleMenu: boolean = false;
  @State sliderStyle: SliderStyle = SliderStyle.NONE;
  @State isSliderDragging: boolean = false;
  @State sliderDragValue: number = 0;   // 拖动时的本地同步值，避免依赖异步的 currentTime
  private sliderTouchCanceled: boolean = false;
  // UI auto-hide
  @State showControls: boolean = true;
  private controlsHideTimerId: number = -1;
  @State containerVpWidth: number = 0;
  @State containerVpHeight: number = 0;
  /** 字幕拖动：垂直上浮（相对视频显示高度的比例）与水平偏移（相对容器宽度的比例）。
   *  会话级、比例化——旋转/折叠/大小屏切换时位置观感不变。 */
  @State subtitleDragLiftRatio: number = 0;
  @State subtitleDragOffsetXRatio: number = 0;
  @State aiTranslateProgress: string = '';
  @State skipNotice: SponsorSkipNotice | null = null;
  private skipNoticeTimerId: number = -1;
  @State aiCaptionShown: boolean = false;
  /** 拖动中的高亮态（虚线取景框 + 气泡样式），需在 build 中响应 */
  @State subtitleDragging: boolean = false;
  // 系统 AI 字幕（P1）：Speech Kit AICaptionComponent，自动捕获应用音频
  private aiCaptionController: AICaptionController = new AICaptionController();
  private aiCaptionOptions: AICaptionOptions | undefined = undefined;
  private aiCaptionSupported: boolean = false;
  /** 画面比例模式（嵌入/填充/拉伸），纯 UI 层 scale 实现，不重建 surface */
  @State videoAspectMode: VideoAspectMode = 'fit';
  /** 双指缩放倍率（1=未缩放），单指平移偏移（vp） */
  @State videoPinchScale: number = 1;
  @State videoPanXVp: number = 0;
  @State videoPanYVp: number = 0;
  private videoPinching: boolean = false;
  private pinchStartScale: number = 1;
  /** 实测底部控制条高度（vp，onAreaChange 持续更新；含导航条/全屏内边距），隐藏时也在树上 */
  @State bottomControlBarVpH: number = 0;
  /** 实测进度条轨道相对播放容器的水平位置与宽度（vp），供 SeekPreviewBubble 1:1 跟随指尖 */
  @State sliderTrackLeftVp: number = 0;
  @State sliderTrackWidthVp: number = 0;
  // horizontal seek gesture
  @State isGestureSeek: boolean = false;
  @State gestureSeekTime: number = 0;
  private gestureSeekStartTime: number = 0;
  private panEndTime: number = 0;
  private gestureMode: PlayerGestureMode = PlayerGestureMode.IDLE;
  private activeInteraction: PlayerInteractionKind = PlayerInteractionKind.NONE;
  private gestureStartX: number = 0;
  private gestureStartY: number = 0;
  private interactionEpoch: number = 0;
  private seekHintHideTimerId: number = -1;
  /** Manual tap-pair state: last tap timestamp + the deferred single-tap action. */
  private lastTapAtMs: number = 0;
  private pendingSingleTapTimerId: number = -1;
  // brightness/volume hints
  @State showBrightnessHint: boolean = false;
  @State showVolumeHint: boolean = false;
  @State gestureBrightnessValue: number = 0;
  @State gestureVolumeValue: number = 0;
  @State gestureBrightnessIcon: Resource = $r('sys.symbol.sun_max_fill');
  @State gestureVolumeIcon: Resource = $r('sys.symbol.speaker_wave_3_fill');
  private gestureInitValue: number = 0;
  private maxVolume: number = 15;
  private volHideTimerId: number = -1;
  private brightnessHideTimerId: number = -1;
  // double-tap hints
  // Canvas context for multi-segment cache bar rendering.
  // HarmonyOS Canvas onReady 是 VoidCallback（无参数），context 通过构造时传入的对象引用获得。
  private cacheCanvasSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private cacheCanvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.cacheCanvasSettings);
  private seekableRangesListener = () => { this.drawCacheRanges(); };
  @State showForwardHint: boolean = false;
  @State showBackwardHint: boolean = false;
  private forwardHintTimerId: number = -1;
  private backwardHintTimerId: number = -1;
  // 长按倍速（hold-to-boost）：松手/取消时恢复加速前的倍速
  @State showSpeedBoostHint: boolean = false;
  private speedBoostActive: boolean = false;
  private speedBoostPreviousSpeed: number = 1.0;
  private speedBoostTarget: number = 2.0;

  
  // 播放页渲染用的 XComponentController。也作为 PiP 的 componentController：
  // XComponent 方式的 PiP 不迁移节点，进/出 PiP 时同一个 surface 直接投到悬浮窗，
  // surfaceId 不变，MPV 无需 detach/re-attach，避免黑帧与几何丢失。
  private x_componentController: XComponentController = new XComponentController();
  private envService: PlayerEnvironmentService = new PlayerEnvironmentService();

  // 手势控制相关的私有变量

  onFullScreenClick: (isLandscape?: boolean) => void = () => {};
  /** 当播放器内部发生不可恢复错误时，通知父组件重新获取流信息 */
  onRetry: () => void = () => {};
  onOpenOptionsTarget?: (route: string, highlightKey?: string) => void;
  onSurfaceReady?: (xc: XComponentController) => void;
  /** 全屏/分屏/挤压铺满态：打开信息面板 sheet（PlayerPage 注入） */
  onShowInfoPanel?: () => void;

  onSourceChange(): void {
    this.resetTransientUi('source-change');
    // Source submission is owned exclusively by PlayerSession.play() ->
    // controller.updateVideoSource(). This watcher only mirrors UI state.
    this.hasStreams = !!(this.curSource.streams && this.curSource.streams.length > 0);
    this.playbackStarted = false;
    const nextVideoId = this.curSource.videoId || '';
    if (nextVideoId !== this.lastSourceVideoId) {
      this.lastSourceVideoId = nextVideoId;
      this.showChaptersSheet = false;
    }
    this.syncSeekbarMetadataFromSession();

    // When a reused PlayerPage starts a fresh session after detachSurface(),
    // re-bind its live XComponent surfaceId so native pendingLoad can fire immediately.
    if (this.controller && !this.controller.surfaceID) {
      try {
        const surfaceId = this.x_componentController.getXComponentSurfaceId();
        if (surfaceId) {
          this.controller.setSurfaceID(surfaceId);
          Logger.info(TAG, `SurfaceID re-bound on source change: ${surfaceId}`);
        }
      } catch (_e) {
        // XComponent surface may not be mounted yet; onLoad will bind it.
      }
    }

    this.syncPlaybackStateFromController();

    this.calculateSurfaceSize();
  }

  /**
   * Controller 实例被替换时（如 session.release + resetSession 后）自动迁移监听器
   * 并重新绑定 Surface ID，防止切视频后出现黑屏或 UI 无响应。
   */
  private onControllerChanged(): void {
    this.resetTransientUi('controller-change');
    // 1. 从旧 controller 移除监听器
    if (this.lastController && this.lastController !== this.controller) {
      this.lastController.unsubscribeProgress(this.progressListener);
      this.lastController.unsubscribePlaybackState(this.playbackStateListener);
      this.lastController.removeErrorListener(this.errorListener);
      this.lastController.removeWaitingForBufferListener(this.waitingForBufferListener);
      this.lastController.removeSeekableRangesListener(this.seekableRangesListener);
      this.lastController.setSubtitleErrorListener(undefined);
    }

    // 2. 向新 controller 注册监听器
    if (this.controller) {
      this.controller.subscribeProgress(this.progressListener);
      this.controller.subscribePlaybackState(this.playbackStateListener);
      this.controller.addErrorListener(this.errorListener);
      this.controller.addWaitingForBufferListener(this.waitingForBufferListener);
      this.controller.addSeekableRangesListener(this.seekableRangesListener);
      this.controller.setSubtitleErrorListener(this.subtitleErrorListener);

      // 3. 立即同步 UI 状态
      this.currentTime = this.vm.currentTime;
      this.durationTime = this.vm.durationTime;
      this.hasError = this.vm.userVisibleErrorMsg.length > 0;
      const pm = this.vm.playerModel;
      this.hasStreams = pm ? (pm.categorizedStreams.audio.length + pm.categorizedStreams.video.length +
                              pm.categorizedStreams.dashManifest.length + pm.categorizedStreams.hlsManifest.length +
                              pm.categorizedStreams.progressive.length) > 0 : false;
      this.syncPlaybackStateFromController();
      this.playbackStateListener(this.controller.getPlaybackState());

      // Re-inject the surface only when the new controller does not have one yet.
      try {
        if (!this.controller.surfaceID) {
          const surfaceId = this.x_componentController.getXComponentSurfaceId();
          if (surfaceId) {
            this.controller.setSurfaceID(surfaceId);
            Logger.debug(TAG, `SurfaceID re-injected after controller change: ${surfaceId}`);
          }
        }
      } catch (_e) {
        // XComponent surface may not be ready yet.
      }
    }

    this.lastController = this.controller;
  }

  onPageVisibilityChange(): void {
    const session = PlayerSession.getInstance();
    const isVisible = this.isPageShow && !this.isAppBackground;
    // Page hide alone never turns video off (share/cast/PiP must not look like Home).
    PlayerPresentation.onPlayerPageVisibility(isVisible);

    if (!isVisible) {
      this.stopStatsOverlayPolling();
      this.resetTransientUi('page-hidden');
      return;
    }

    if (this.showStatsOverlay) {
      this.startStatsOverlayPolling();
    }

    if (session.playerState === PlayerState.RELEASED) {
      // 会话已释放（极端时序）才需要重新初始化
      session.ensureInitialized().catch(() => {});
    }

    // surfaceID 兜底重绑：仅在丢失时
    if (!this.controller.surfaceID) {
      try {
        const surfaceId = this.x_componentController.getXComponentSurfaceId();
        if (surfaceId) {
          this.controller.setSurfaceID(surfaceId);
          Logger.info(TAG, `SurfaceID re-bound on visibility change: ${surfaceId}`);
        }
      } catch (_e) {
        Logger.warn(TAG, 'Failed to get surfaceId on visibility change');
      }
    }

    this.syncPlaybackStateFromController();
    this.showControls = true;
    this.scheduleHideControls();
  }

  aboutToAppear(): void {
    const context: Context = this.getUIContext().getHostContext() as Context;

    // 清理错误状态（包括 PlayerPage 设置的 API 层错误和 Controller 设置的播放错误）
    this.vm.errorMsg = '';
    this.hasError = false;
    this.isWaitingForDualBuffer = false;
    this.curSource.error = undefined;

    // 先拿主窗口，再注册 keep-screen / 状态监听。
    // 旧顺序在 mainWin 未就绪时调用 setKeepScreenOn，会把 lastKeepScreenOn 置 true
    // 却不下发系统 API，后续同值又被短路 → 播放中自动息屏。
    this.initializePlayerEnvironment(context);

    // 系统 AI 字幕（P1）能力探测 + 惰性初始化：仅支持 Phone/Tablet/2in1 部分机型，
    // 不支持模拟器；syscap 探测失败或 onError 都保持隐藏，不影响播放。
    try {
      this.aiCaptionSupported = canIUse('SystemCapability.AI.AICaption');
    } catch (_e) {
      this.aiCaptionSupported = false;
    }
    if (this.aiCaptionSupported && !this.aiCaptionOptions) {
      // 源/目标语言字段是 6.1.1(API 24) 新增；低版本运行时下传会报 1012900013，按版本裁剪
      const withLangFields = deviceInfo.sdkApiVersion >= 24;
      // 用户配置的源语言（默认英文视频 → 中英双语；中文源只出中文）
      const srcLang = this.playbackConfig.systemAiCaptionSource === 'zh' ? 'zh' : 'en';
      const onPrepared = (): void => {
        Logger.info(TAG, 'AICaption prepared');
      };
      const onError = (error: BusinessError): void => {
        Logger.warn(TAG, `AICaption error code=${error.code} msg=${error.message}`);
      };
      // 编译期同样受 SDK 版本约束：API 23 的 AICaptionOptions 类型没有语言字段，
      // 字面量直传会编译失败，因此先构造基础对象再按版本补字段。
      const baseOptions: AICaptionOptions = {
        initialOpacity: 1,
        onPrepared: onPrepared,
        onError: onError
      };
      if (withLangFields) {
        const extra = baseOptions as Record<string, ESObject>;
        extra['sourceLanguage'] = srcLang;
        extra['targetLanguage'] = srcLang === 'en' ? 'zh-en' : 'zh';
      }
      this.aiCaptionOptions = baseOptions;
    }
    this.aiCaptionShown = this.playbackConfig.systemAiCaption && this.aiCaptionSupported;

    // 注册进度监听（节流后的 currentTime/durationTime）
    this.controller.subscribeProgress(this.progressListener);
    SponsorBlockSkipper.getInstance().setNoticeListener(this.skipNoticeListener);
    SponsorBlockSkipper.getInstance().subscribeSegments(this.sponsorSegmentsListener);
    PlayerSession.getInstance().subscribePlaybackExtras(this.playbackExtrasListener);
    this.lastSourceVideoId = this.curSource.videoId || '';
    this.syncSeekbarMetadataFromSession();
    this.controller.subscribePlaybackState(this.playbackStateListener);
    // 错误与特殊状态监听
    this.controller.addErrorListener(this.errorListener);
    this.controller.addWaitingForBufferListener(this.waitingForBufferListener);
    this.controller.addSeekableRangesListener(this.seekableRangesListener);
    this.controller.setSubtitleErrorListener(this.subtitleErrorListener);
    // AI 字幕翻译进度（字幕菜单内展示 x/y）
    SubtitleTranslationService.getInstance().addProgressListener(this.aiTranslateProgressListener);
    // [DISABLED] P3 ASR：进度/失败监听随菜单项一起禁用
    // AsrLiveCaptionService.getInstance().addProgressListener(this.asrLiveProgressListener);
    // AsrLiveCaptionService.getInstance().addErrorListener(this.asrLiveErrorListener);
    // 屏幕常亮：跟随播放状态机驱动
    this.controller.addStateListener(this.keepScreenListener);
    // 立即按当前 vm 状态同步一次（避免错过初始 PLAYING / 引擎已就绪）
    this.envService.setKeepScreenOn(this.vm.isPlaying || this.vm.isBuffering);
    // 立即同步一次 PiP 播放/暂停按钮状态（页面恢复/复用时按钮即时对齐）
    PiPManager.getInstance().updatePlayPauseStatus(this.vm.isPlaying);

    // 初始化流状态
    this.hasStreams = !!(this.curSource.streams && this.curSource.streams.length > 0);

    this.calculateSurfaceSize();

    // 确保播放引擎已初始化（不再需要传递 XComponentController）
    const session = PlayerSession.getInstance();
    session.ensureInitialized().catch((e: Error) => {
      Logger.warn(TAG, `Deferred engine initialization failed: ${e.message || e}`);
    });

    // 主动注入 componentController：aboutToAppear 每次组件创建必跑，比 onLoad 可靠。
    // 冷启动 destroy 清空了 PiPManager.componentController，若仅靠 onLoad 重注入，
    // 节点复用不重跑 onLoad 时会导致 pendingInit 永远挂起、PiP 不可用。这里兜底注入。
    PiPManager.getInstance().setComponentController(this.x_componentController);

    // XComponent.onLoad 时会自动绑定 surfaceId

    // 订阅屏幕锁定/亮屏事件
    this.envService.subscribeScreenEvents(
      () => { /* screen off — globally disabled */ },
      () => {
        // Screen-on is not a user play command. Keep the explicit pause/play
        // intent instead of unexpectedly starting audio from the lock screen.
        Logger.info(TAG, 'Screen on → keep current playback intent');
      }
    );
  }

  // ── 多段缓存条绘制 ──
  // 当 seekableRanges 更新时由 @Watch 触发，在 Canvas onReady 保存的 ctx 上绘制。
  private async initializePlayerEnvironment(context: Context): Promise<void> {
    try {
      await this.envService.init(context);
      const brightness = await this.envService.getBrightness(context);
      this.gestureBrightnessValue = brightness;
      const volInfo = this.envService.getVolume();
      this.gestureVolumeValue = volInfo.volume / volInfo.maxVolume;
    } catch (e) {
      Logger.warn(TAG, `Player environment initialization failed: ${e}`);
    }
  }

  private drawCacheRanges(): void {
    const ctx = this.cacheCanvasCtx;
    const duration = this.durationTime;
    const ranges = this.vm.seekableRanges;
    const w = ctx.width;
    const h = ctx.height;
    ctx.clearRect(0, 0, w, h);
    if (duration <= 0 || ranges.length === 0 || w <= 0) return;
    ctx.fillStyle = 'rgba(255,255,255,0.5)';
    for (const range of ranges) {
      const start = Math.max(0, range[0]);
      const end = Math.min(duration, range[1]);
      if (end <= start) continue;
      const x = (start / duration) * w;
      const segW = ((end - start) / duration) * w;
      ctx.fillRect(x, 0, segW, h);
    }
  }



  // ── UI 自动隐藏 ──
  private scheduleHideControls(): void {
    this.clearHideTimer();
    if (!this.showControls || this.activeInteraction !== PlayerInteractionKind.NONE ||
      !this.isPageShow || this.isAppBackground || !this.canAutoHideControls()) {
      return;
    }
    const epoch = this.interactionEpoch;
    this.controlsHideTimerId = setTimeout(() => {
      this.controlsHideTimerId = -1;
      if (epoch === this.interactionEpoch && this.activeInteraction === PlayerInteractionKind.NONE &&
        this.isPageShow && !this.isAppBackground && this.canAutoHideControls()) {
        this.showControls = false;
        // 提示层独立于 showControls 渲染，控制层隐藏时必须一并清掉，防止残留常驻
        this.clearGestureHints();
      }
    }, CONTROLS_HIDE_DELAY);
  }

  private clearHideTimer(): void {
    if (this.controlsHideTimerId >= 0) {
      clearTimeout(this.controlsHideTimerId);
      this.controlsHideTimerId = -1;
    }
  }

  /**
   * 画面区域的单击（只在**画面空白处**触发——控件的点击不再漏进手势层）。
   *
   * <p>语义 = **切换**控件显隐：点一下收起、再点一下唤出。收起只发生在
   * 「控件可见」且用户明确点了空白处时；按播放键、拖进度条、开菜单这些
   * **控件上的操作**都不会再把控件收走（它们根本不进手势层）。
   *
   * <p>暂停态下 `canAutoHideControls()` 为 false → 单击只会把控件显示出来，
   * 不会收起：这样"看清时间码/画面再精确暂停"的形态始终可用。
   */
  /**
   * Single tap stream with manual pair counting.
   *
   * <p>ArkUI's TapGesture(count:2) cannot fire repeatedly for 2nd/4th/6th taps:
   * after a successful double-tap the recognizer stays in its sequence until the
   * multi-tap window lapses, so a fast follow-up pair is swallowed (the hint
   * lifetime made it look like "wait for the hint"). HarmonyOS exposes no
   * per-event tap counter (TapRecognizer.getTapCount() returns the configured
   * count, not the actual one), so we use ONE count:1 recognizer and pair taps
   * by timestamp here. Every even tap seeks; an unpaired tap falls back to the
   * normal controls toggle after the double-tap window.
   */
  private onCenterTap(event: GestureEvent): void {
    // 交互进行中（菜单已打开 / 正在拖进度条 / 正在滑动）：单击不再处理控件显隐，
    // 否则"点开更多菜单"这类操作会连带把控件收起来，菜单上方空一片。
    if (this.activeInteraction !== PlayerInteractionKind.NONE) {
      return;
    }
    if (this.isCenterButtonTap(event)) {
      // 中央按钮自己处理这次点击（切换播放/暂停），这里只重置自动隐藏
      // 计时器：用户刚操作过，控件按正常节奏消失，但**不**切换显隐。
      // 按钮上的点击永远不参与双击配对。
      this.lastTapAtMs = 0;
      this.clearPendingSingleTap();
      this.interactionEpoch++;
      this.clearHideTimer();
      this.scheduleHideControls();
      return;
    }
    const now: number = Date.now();
    if (this.lastTapAtMs > 0 && now - this.lastTapAtMs <= DOUBLE_TAP_WINDOW_MS) {
      // 第 2/4/6… 次：取消待执行的单击动作，立即快进/快退。
      this.lastTapAtMs = 0;
      this.clearPendingSingleTap();
      this.performDoubleTap(event);
      return;
    }
    // 第 1/3/5… 次：等双击窗口过去再执行单击动作；第二下会取消这个定时器。
    this.lastTapAtMs = now;
    this.clearPendingSingleTap();
    this.pendingSingleTapTimerId = setTimeout(() => {
      this.pendingSingleTapTimerId = -1;
      this.lastTapAtMs = 0;
      this.applySingleTapToggle();
    }, DOUBLE_TAP_WINDOW_MS);
  }

  private clearPendingSingleTap(): void {
    if (this.pendingSingleTapTimerId >= 0) {
      clearTimeout(this.pendingSingleTapTimerId);
      this.pendingSingleTapTimerId = -1;
    }
  }

  private applySingleTapToggle(): void {
    this.interactionEpoch++;
    this.clearHideTimer();
    if (!this.canAutoHideControls()) {
      this.showControls = true;
      return;
    }
    this.showControls = !this.showControls;
    if (this.showControls) {
      this.scheduleHideControls();
    } else {
      this.clearHideTimer();
      this.clearGestureHints();
    }
  }

  /** The double-tap action itself (seek / play-pause / off), shared by every
   *  even tap of the manual pair counter. */
  private performDoubleTap(event: GestureEvent): void {
    this.registerDoubleTapActivity();
    const action = this.playbackConfig.doubleTapAction;
    if (action === 'off') {
      return;
    }
    if (action === 'playpause') {
      this.togglePlayback();
      return;
    }
    const step = this.playbackConfig.doubleTapSeekSeconds > 0
      ? this.playbackConfig.doubleTapSeekSeconds : 15;
    const x: number = event.fingerList[0]?.localX ?? 0;
    if (x > this.containerVpWidth / 2) {
      Logger.info(TAG, `Double-tap forward +${step}s`);
      const targetSec = Math.min(this.currentTime + step, this.durationTime);
      this.controller.syncSeek(targetSec * 1000);
      this.showForwardHint = true;
      this.forwardHintTimerId = setTimeout(() => {
        this.forwardHintTimerId = -1;
        this.showForwardHint = false;
      }, DOUBLE_TAP_HINT_HIDE_DELAY);
      this.maybeShowJumpAhead(targetSec);
    } else {
      Logger.info(TAG, `Double-tap backward -${step}s`);
      this.controller.syncSeek(Math.max(this.currentTime - step, 0) * 1000);
      this.showBackwardHint = true;
      this.backwardHintTimerId = setTimeout(() => {
        this.backwardHintTimerId = -1;
        this.showBackwardHint = false;
      }, DOUBLE_TAP_HINT_HIDE_DELAY);
    }
  }

  private canAutoHideControls(): boolean {
    if (!this.controller || this.hasError) {
      return false;
    }
    const state = this.controller.getPlaybackState();
    return state.isPlaying || state.isBuffering || state.engineState === 'buffering';
  }

  private beginInteraction(kind: PlayerInteractionKind): void {
    this.interactionEpoch++;
    this.clearHideTimer();
    this.clearTransientHintTimers();
    this.showBrightnessHint = false;
    this.showVolumeHint = false;
    this.isGestureSeek = false;
    this.showForwardHint = false;
    this.showBackwardHint = false;
    this.activeInteraction = kind;
    this.showControls = true;
  }

  private clearTransientHintTimers(): void {
    if (this.seekHintHideTimerId >= 0) {
      clearTimeout(this.seekHintHideTimerId);
      this.seekHintHideTimerId = -1;
    }
    if (this.volHideTimerId >= 0) {
      clearTimeout(this.volHideTimerId);
      this.volHideTimerId = -1;
    }
    if (this.brightnessHideTimerId >= 0) {
      clearTimeout(this.brightnessHideTimerId);
      this.brightnessHideTimerId = -1;
    }
    if (this.forwardHintTimerId >= 0) {
      clearTimeout(this.forwardHintTimerId);
      this.forwardHintTimerId = -1;
    }
    if (this.backwardHintTimerId >= 0) {
      clearTimeout(this.backwardHintTimerId);
      this.backwardHintTimerId = -1;
    }
    // A deferred single-tap toggle must not fire after another interaction or a
    // page/source reset.
    this.clearPendingSingleTap();
  }

  /** 清空全部手势提示（seek/亮度/音量/双击/倍速），计时器一并取消。
   *  用于控制层隐藏兜底——提示层独立于 showControls 渲染，不得比 UI 活得更久。 */
  private clearGestureHints(): void {
    this.clearTransientHintTimers();
    this.isGestureSeek = false;
    this.showBrightnessHint = false;
    this.showVolumeHint = false;
    this.showForwardHint = false;
    this.showBackwardHint = false;
    this.showSpeedBoostHint = false;
  }

  private resetTransientUi(reason: string): void {
    this.interactionEpoch++;
    this.onHoldSpeedEnd('reset-ui');
    this.clearHideTimer();
    this.clearTransientHintTimers();
    this.gestureMode = PlayerGestureMode.IDLE;
    this.activeInteraction = PlayerInteractionKind.NONE;
    this.isGestureSeek = false;
    this.showBrightnessHint = false;
    this.showVolumeHint = false;
    this.showForwardHint = false;
    this.showBackwardHint = false;
    this.isSliderDragging = false;
    this.clearJumpAheadPill();
    // 拖动中途的全屏切换/换源/页面隐藏必须复位，否则标志卡住会永久门禁根手势
    this.subtitleDragging = false;
    this.showSubtitleMenu = false;
    this.showCollapsedSubtitleMenu = false;
    this.trackThicknessSize = CommonConstants.TRACK_SIZE_MIN;
    this.sliderStyle = SliderStyle.NONE;
    this.showControls = true;
    Logger.debug(TAG, `Transient UI reset reason=${reason}`);
  }

  private subtitleDragStartLiftRatio: number = 0;
  private subtitleDragStartOffsetXRatio: number = 0;

  /** 视频显示区域在控制容器内的布局：上下黑边高度 + 视频显示高度（居中 letterbox）。 */
  private videoLayoutVp(): VideoLayoutVp {
    const containerW = this.containerVpWidth;
    const containerH = this.containerVpHeight;
    if (containerW <= 0 || containerH <= 0 || !this.curSource.width || !this.curSource.height) {
      return { letterboxVp: 0, videoHVp: containerH, videoWVp: containerW };
    }
    const videoAspect = this.curSource.width / this.curSource.height;
    if (videoAspect > containerW / containerH) {
      return { letterboxVp: (containerH - containerW / videoAspect) / 2, videoHVp: containerW / videoAspect, videoWVp: containerW };
    }
    return { letterboxVp: 0, videoHVp: containerH, videoWVp: containerH * videoAspect };
  }

  /**
   * 字幕底部间距：锚定**视频显示区域**而非控制容器——小屏/竖屏时视频按宽高比
   * 居中、上下有黑边，底部黑边高度加回去；全屏铺满时黑边为 0，自然退化为容器底。
   * 视频内边距随视频显示高度按比例缩放（10%，设置值为上限，下限 12vp），
   * 小屏贴底不占道，大屏行为与设置一致。
   * 控制栏显示时只在会被控制条盖到的情况下上浮（实测条高 + 间隙），不再无条件常量上浮。
   * 容器/控制条尺寸、视频比例全部走 @State 响应式，旋转/全屏/折叠/分屏自动重算。
   */
  private subtitleBottomVp(): number {
    if (this.containerVpWidth <= 0 || this.containerVpHeight <= 0) {
      return Number(this.playbackConfig.subtitleBottomMarginVp);
    }
    const layout = this.displayLayoutVp();
    // 边距 = clamp(视频高×10%, 12, 设置值)：设置值是上限，实际随视频显示高度缩放。
    // 小屏 ~200vp 视频 → ~20vp 贴底；全屏 ~800vp → 比例值超过设置值，用设置值。
    const marginInVideo = Math.min(
      Math.max(SUBTITLE_MARGIN_MIN_VP, layout.videoHVp * SUBTITLE_VIDEO_MARGIN_RATIO),
      Number(this.playbackConfig.subtitleBottomMarginVp));
    const rest = layout.letterboxVp + marginInVideo;
    // 用户显式拖动过的位置优先于控制条/提示胶囊避让；未拖动时才按需上浮
    const hasDrag = this.subtitleDragLiftRatio !== 0 || this.subtitleDragOffsetXRatio !== 0;
    let clearance = 0;
    if (!hasDrag) {
      if (this.showControls) {
        const barH = this.bottomControlBarVpH > 0 ? this.bottomControlBarVpH : 60;
        clearance = Math.max(clearance, barH + SUBTITLE_BAR_GAP_VP);
      }
      if (this.skipNotice !== null
        || (this.experimentalConfig.heatmapPluginEnabled && this.experimentalConfig.heatmapJumpAhead
          && this.jumpAheadTargetSec !== null)) {
        clearance = Math.max(clearance, this.overlayPillBottomVp() + OVERLAY_PILL_HEIGHT_VP + SUBTITLE_BAR_GAP_VP);
      }
    }
    const lifted = Math.max(rest, clearance);
    // 拖动值按比例存储，乘回当前视频显示高度——大小屏/折叠切换位置观感不变
    const maxDragTop = layout.letterboxVp + layout.videoHVp * SUBTITLE_DRAG_MAX_RATIO;
    const upperBound = Math.min(Math.max(maxDragTop, lifted), Math.max(24, this.containerVpHeight - 44));
    return Math.min(
      Math.max(lifted + this.subtitleDragLiftRatio * layout.videoHVp, layout.letterboxVp + 8),
      upperBound);
  }

  /**
   * 字幕拖动偏移复原：全屏切换、旋转、折叠、分屏等导致容器/窗口形态变化时调用。
   * 拖动位置在形态内固定（不吸附、不回退），形态切换后回到默认位置重来。
   */
  private resetSubtitleDrag(): void {
    if (this.subtitleDragLiftRatio !== 0 || this.subtitleDragOffsetXRatio !== 0) {
      this.subtitleDragLiftRatio = 0;
      this.subtitleDragOffsetXRatio = 0;
    }
    this.subtitleDragging = false;
  }

  /** 字幕/取景框的锚定布局：fill/stretch 时画面铺满容器（黑边为 0），fit 时按等比视频区。
   *  注意与 videoScaleXY/clampVideoPan 用的 fit 布局分离——fill 倍率必须用 fit 尺寸算。 */
  private displayLayoutVp(): VideoLayoutVp {
    if (this.videoAspectMode !== 'fit') {
      return { letterboxVp: 0, videoHVp: this.containerVpHeight, videoWVp: this.containerVpWidth };
    }
    return this.videoLayoutVp();
  }

  /**
   * 画面总缩放（模式基础缩放 × 双指缩放）。纯 UI 层 scale，surface 不重建、
   * 播放不受影响；fill/stretch 超出的部分由 PlayerContainer 的 clip(true) 裁掉。
   */
  private videoScaleXY(): VideoScaleXY {
    const layout = this.videoLayoutVp();
    const cw = Math.max(1, this.containerVpWidth);
    const ch = Math.max(1, this.containerVpHeight);
    const fitW = Math.max(1, layout.videoWVp);
    const fitH = Math.max(1, layout.videoHVp);
    let sx = 1;
    let sy = 1;
    if (this.videoAspectMode === 'fill') {
      sx = Math.max(cw / fitW, ch / fitH);
      sy = sx;
    } else if (this.videoAspectMode === 'stretch') {
      sx = cw / fitW;
      sy = ch / fitH;
    }
    return { sx: sx * this.videoPinchScale, sy: sy * this.videoPinchScale };
  }

  /** 平移钳制：缩放后的画面不允许露出黑边（各方向最多移到边缘）。 */
  private clampVideoPan(): void {
    const layout = this.videoLayoutVp();
    const scale = this.videoScaleXY();
    const maxX = Math.max(0, (layout.videoWVp * scale.sx - this.containerVpWidth) / 2);
    const maxY = Math.max(0, (layout.videoHVp * scale.sy - this.containerVpHeight) / 2);
    this.videoPanXVp = Math.min(Math.max(this.videoPanXVp, -maxX), maxX);
    this.videoPanYVp = Math.min(Math.max(this.videoPanYVp, -maxY), maxY);
  }

  /** 还原画面：缩放/平移归零（比例模式保持当前选择）。 */
  private resetVideoZoom(): void {
    this.videoPinchScale = 1;
    this.videoPanXVp = 0;
    this.videoPanYVp = 0;
  }

  private aspectModeLabel(): Resource {
    return $r(`app.string.yt_aspect_${this.videoAspectMode}`);
  }

  /** 选择比例模式：切换模式并还原双指缩放（模式即基准）；菜单交互经 MENU 保活，不收起 UI。 */
  private selectAspectMode(mode: VideoAspectMode): void {
    this.videoAspectMode = mode;
    this.resetVideoZoom();
  }

  @Builder
  AspectMenu() {
    Menu() {
      if (this.videoPinchScale > 1 || this.videoPanXVp !== 0 || this.videoPanYVp !== 0) {
        MenuItem({
          content: $r('app.string.yt_aspect_reset')
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
          .onClick(() => this.resetVideoZoom())
      }
      ForEach(['fit', 'fill', 'stretch'] as VideoAspectMode[], (mode: VideoAspectMode) => {
        MenuItem({
          content: $r(`app.string.yt_aspect_${mode}`),
          endIcon: this.videoAspectMode === mode ? $r('sys.symbol.checkmark') : ''
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
          .backgroundColor(this.videoAspectMode === mode
            ? this.getSelectedMenuBackground() : Color.Transparent)
          .onClick(() => this.selectAspectMode(mode))
      }, (mode: VideoAspectMode) => mode)
    }
    .onAppear(() => this.onControlMenuAppear())
    .onDisAppear(() => this.onControlMenuDisappear())
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .borderRadius(12)
    .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
    .width(220)
  }

  private pinchStartDistanceVp: number = 0;
  private pinchLastMidXVp: number = 0;
  private pinchLastMidYVp: number = 0;
  private pinchStartMidXVp: number = 0;
  private pinchStartMidYVp: number = 0;
  /** 实际已应用的缩放值（滞后带判定基准） */
  private pinchAppliedScale: number = 1;
  /** 双指手势判别：起手先不定，间距变化主导→缩放，中点位移主导→平移，序列内互斥 */
  private pinchGestureMode: 'undecided' | 'pan' | 'scale' = 'undecided';

  /**
   * 双指缩放（onTouch 手动跟踪双指距离）：PinchGesture 放在 Exclusive 手势组里
   * 会被单指 pan 抢先识别（先动的手指赢），实测双指放不上来；改在触摸层处理。
   * UI 隐藏时锁定；pinch 起手时取消进行中的单指 pan。
   */
  private onPinchTouch(event: TouchEvent): void {
    if (!this.showControls) return;
    if (event.touches.length === 2) {
      const a = event.touches[0];
      const b = event.touches[1];
      const dx = a.x - b.x;
      const dy = a.y - b.y;
      const dist = Math.sqrt(dx * dx + dy * dy);
      if (!this.videoPinching) {
        this.videoPinching = true;
        this.pinchStartDistanceVp = Math.max(1, dist);
        this.pinchStartScale = this.videoPinchScale;
        this.pinchAppliedScale = this.videoPinchScale;
        this.pinchStartMidXVp = (a.x + b.x) / 2;
        this.pinchStartMidYVp = (a.y + b.y) / 2;
        this.pinchLastMidXVp = this.pinchStartMidXVp;
        this.pinchLastMidYVp = this.pinchStartMidYVp;
        this.pinchGestureMode = 'undecided';
        this.clearHideTimer();
        // pinch 起手接管本次触摸序列：取消进行中的单指 pan 与字幕拖动
        this.ignorePlayerPan('pinch-start');
        this.subtitleDragging = false;
        return;
      }
      if (event.type === TouchType.Move) {
        const midX = (a.x + b.x) / 2;
        const midY = (a.y + b.y) / 2;
        if (this.pinchGestureMode === 'undecided') {
          // 判别期：中点位移 vs 双指间距变化，谁明显主导就锁定谁（互斥）
          const distChange = Math.abs(dist - this.pinchStartDistanceVp);
          const midDisp = Math.hypot(midX - this.pinchStartMidXVp, midY - this.pinchStartMidYVp);
          if (midDisp > PINCH_DECIDE_VP && midDisp > distChange * 1.5) {
            this.pinchGestureMode = 'pan';
          } else if (distChange / this.pinchStartDistanceVp > PINCH_DECIDE_SCALE_RATIO
            && distChange > midDisp * 1.5) {
            this.pinchGestureMode = 'scale';
          }
        }
        if (this.pinchGestureMode === 'scale') {
          const raw = this.pinchStartScale * (dist / this.pinchStartDistanceVp);
          const clamped = Math.min(Math.max(raw, 1), VIDEO_PINCH_MAX_SCALE);
          // 缩放滞后带：相对变化 <1% 不更新——触摸噪声不应变成画面抖动
          if (Math.abs(clamped - this.pinchAppliedScale) / this.pinchAppliedScale >= 0.01) {
            this.pinchAppliedScale = clamped;
            this.videoPinchScale = clamped;
            this.clampVideoPan();
          }
        } else if (this.pinchGestureMode === 'pan') {
          // 双指平移 = 双指中点的位移（TouchObject 坐标单位即 vp，直接使用）
          this.videoPanXVp += midX - this.pinchLastMidXVp;
          this.videoPanYVp += midY - this.pinchLastMidYVp;
          this.clampVideoPan();
        }
        this.pinchLastMidXVp = midX;
        this.pinchLastMidYVp = midY;
      }
      return;
    }
    if (this.videoPinching && (event.type === TouchType.Up || event.type === TouchType.Cancel)) {
      this.videoPinching = false;
      // 缩回到接近 1 时彻底归位，清除浮点残留
      if (this.videoPinchScale <= 1.05) {
        this.resetVideoZoom();
      }
      this.scheduleHideControls();
    }
  }

  private onFullscreenModeChange(): void {
    this.resetTransientUi('fullscreen-change');
    this.resetSubtitleDrag();
    this.resetVideoZoom();
    this.calculateSurfaceSize();
  }

  private isInFullscreenGestureSafeEdge(x: number, y: number): boolean {
    if (!this.isFullLandscapeScreen) {
      return false;
    }
    const top = Math.max(this.playerGestureSafeTop, this.safeAreaTop);
    return x <= this.playerGestureSafeLeft || x >= this.containerVpWidth - this.playerGestureSafeRight ||
      y <= top || y >= this.containerVpHeight - this.playerGestureSafeBottom;
  }

  private ignorePlayerPan(reason: string): void {
    this.gestureMode = PlayerGestureMode.IGNORED;
    this.isGestureSeek = false;
    this.showBrightnessHint = false;
    this.showVolumeHint = false;
    Logger.debug(TAG, `Player pan ignored reason=${reason}`);
  }

  private hiddenUiSeekOnly: boolean = false;

  private onPlayerPanStart(event: GestureEvent): void {
    this.hiddenUiSeekOnly = false;
    if (this.subtitleDragging || this.videoPinching) {
      this.ignorePlayerPan(this.subtitleDragging ? 'subtitle-dragging' : 'pinching');
      return;
    }
    if (this.isSliderDragging) {
      this.gestureMode = PlayerGestureMode.IGNORED;
      Logger.debug(TAG, 'Player pan ignored reason=slider-dragging-start');
      return;
    }
    const finger = event.fingerList[0];
    this.gestureStartX = (finger?.localX ?? 0) - event.offsetX;
    this.gestureStartY = (finger?.localY ?? 0) - event.offsetY;
    this.gestureSeekStartTime = this.currentTime;
    this.gestureSeekTime = this.currentTime;
    this.panEndTime = this.currentTime;
    // UI 隐藏时只放行横滑 seek（进度/双击/长按三件套可在隐藏态工作），
    // 不点亮控制层、不占用 activeInteraction；亮度/音量/字幕仍锁定。
    if (!this.showControls) {
      this.hiddenUiSeekOnly = true;
      this.gestureMode = PlayerGestureMode.PENDING;
      if (event.fingerList.length !== 1) {
        this.ignorePlayerPan('finger-count');
      }
      return;
    }
    this.beginInteraction(PlayerInteractionKind.PAN);
    this.gestureMode = PlayerGestureMode.PENDING;
    if (event.fingerList.length !== 1) {
      this.ignorePlayerPan('finger-count');
    } else if (this.isInFullscreenGestureSafeEdge(this.gestureStartX, this.gestureStartY)) {
      this.ignorePlayerPan('system-safe-edge');
    }
  }

  private lockPlayerPanMode(event: GestureEvent): void {
    const absX = Math.abs(event.offsetX);
    const absY = Math.abs(event.offsetY);
    if (Math.max(absX, absY) < GESTURE_LOCK_DISTANCE) {
      return;
    }
    // UI 隐藏时启动的受限 pan：只允许横滑 seek，垂直方向（亮度/音量）仍锁定。
    // 画面平移是双指手势（onPinchTouch），单指始终留给进度/亮度/音量。
    if (this.hiddenUiSeekOnly && absX < absY * GESTURE_AXIS_DOMINANCE) {
      this.ignorePlayerPan('controls-hidden-vertical');
      return;
    }
    if (absX >= absY * GESTURE_AXIS_DOMINANCE) {
      const state = this.controller.getPlaybackState();
      if (!this.playbackConfig.gestureSeekEnabled || this.curSource.isLive || this.durationTime <= 0 ||
        !state.isSeekable) {
        this.ignorePlayerPan(this.playbackConfig.gestureSeekEnabled ? 'seek-unavailable' : 'seek-disabled');
        return;
      }
      this.gestureMode = PlayerGestureMode.SEEK;
      this.isGestureSeek = true;
      Logger.debug(TAG, 'Player pan locked mode=seek');
      return;
    }
    if (absY < absX * GESTURE_AXIS_DOMINANCE) {
      return;
    }
    if (this.gestureStartX < this.containerVpWidth / 2) {
      if (!this.playbackConfig.gestureBrightnessEnabled) {
        this.ignorePlayerPan('brightness-disabled');
        return;
      }
      try {
        const context: Context = this.getUIContext().getHostContext() as Context;
        this.gestureBrightnessValue = this.envService.getBrightnessSync(context);
      } catch (e) {
        Logger.warn(TAG, `Brightness gesture baseline fallback reason=${e}`);
      }
      this.gestureInitValue = this.gestureBrightnessValue;
      this.gestureMode = PlayerGestureMode.BRIGHTNESS;
      this.showBrightnessHint = true;
      Logger.debug(TAG, 'Player pan locked mode=brightness');
    } else {
      if (!this.playbackConfig.gestureVolumeEnabled) {
        this.ignorePlayerPan('volume-disabled');
        return;
      }
      try {
        const volInfo = this.envService.getVolume();
        this.maxVolume = volInfo.maxVolume;
        this.gestureVolumeValue = volInfo.maxVolume > 0 ? volInfo.volume / volInfo.maxVolume : 0;
      } catch (e) {
        Logger.warn(TAG, `Volume gesture baseline fallback reason=${e}`);
      }
      this.gestureInitValue = this.gestureVolumeValue;
      this.gestureMode = PlayerGestureMode.VOLUME;
      this.showVolumeHint = true;
      Logger.debug(TAG, 'Player pan locked mode=volume');
    }
  }

  private onPlayerPanUpdate(event: GestureEvent): void {
    if (this.isSliderDragging || this.activeInteraction === PlayerInteractionKind.SLIDER) {
      this.ignorePlayerPan('slider-dragging-update');
      return;
    }
    if (event.fingerList.length !== 1) {
      this.ignorePlayerPan('finger-count-update');
      return;
    }
    if (this.gestureMode === PlayerGestureMode.PENDING) {
      this.lockPlayerPanMode(event);
    }
    if (this.gestureMode === PlayerGestureMode.SEEK) {
      const seekWidth = Math.max(1, this.containerVpWidth);
      const time = this.gestureSeekStartTime + (event.offsetX / seekWidth) * this.durationTime;
      this.gestureSeekTime = Math.min(Math.max(0, time), this.durationTime);
      this.panEndTime = this.gestureSeekTime;
    } else if (this.gestureMode === PlayerGestureMode.BRIGHTNESS) {
      const value = Math.min(1, Math.max(0, this.gestureInitValue + (-event.offsetY / 200)));
      this.gestureBrightnessValue = value;
      this.envService.setBrightness(value);
      this.gestureBrightnessIcon = value > 0.3 ? $r('sys.symbol.sun_max_fill') : $r('sys.symbol.moon_fill');
    } else if (this.gestureMode === PlayerGestureMode.VOLUME) {
      const value = Math.min(1, Math.max(0, this.gestureInitValue + (-event.offsetY / 200)));
      this.gestureVolumeValue = value;
      this.envService.setVolume(Math.round(value * this.maxVolume));
      this.gestureVolumeIcon = value > 0.5 ? $r('sys.symbol.speaker_wave_3_fill') :
        (value > 0 ? $r('sys.symbol.speaker_wave_1_fill') : $r('sys.symbol.speaker_slash_fill'));
    }
  }

  private onPlayerPanEnd(canceled: boolean): void {
    const mode = this.gestureMode;
    this.hiddenUiSeekOnly = false;
    if (!canceled && mode === PlayerGestureMode.SEEK) {
      this.controller.syncSeek(this.panEndTime * 1000);
      Logger.debug(TAG, `Player pan seek committed positionMs=${Math.round(this.panEndTime * 1000)}`);
      if (this.panEndTime > this.gestureSeekStartTime + 3) {
        this.maybeShowJumpAhead(this.panEndTime);
      }
    } else if (canceled && mode !== PlayerGestureMode.IDLE) {
      Logger.debug(TAG, `Player pan canceled mode=${mode}`);
    }
    this.gestureMode = PlayerGestureMode.IDLE;
    if (this.activeInteraction === PlayerInteractionKind.PAN) {
      this.activeInteraction = PlayerInteractionKind.NONE;
    }
    // 提示隐藏计时不做 epoch 守卫：新交互会经 clearTransientHintTimers 取消旧计时器，
    // epoch 失配反而会让提示永久常驻（如手势结束后点按切换了控制层）
    if (mode === PlayerGestureMode.SEEK) {
      if (canceled) {
        this.isGestureSeek = false;
      } else {
        this.seekHintHideTimerId = setTimeout(() => {
          this.seekHintHideTimerId = -1;
          this.isGestureSeek = false;
        }, SEEK_HINT_HIDE_DELAY);
      }
    } else if (mode === PlayerGestureMode.BRIGHTNESS) {
      if (canceled) {
        this.showBrightnessHint = false;
      } else {
        this.brightnessHideTimerId = setTimeout(() => {
          this.brightnessHideTimerId = -1;
          this.showBrightnessHint = false;
        }, SIDE_HINT_HIDE_DELAY);
      }
    } else if (mode === PlayerGestureMode.VOLUME) {
      if (canceled) {
        this.showVolumeHint = false;
      } else {
        this.volHideTimerId = setTimeout(() => {
          this.volHideTimerId = -1;
          this.showVolumeHint = false;
        }, SIDE_HINT_HIDE_DELAY);
      }
    }
    this.scheduleHideControls();
  }

  /**
   * Reset the transient interaction bookkeeping for a double-tap WITHOUT
   * waking the control layer. beginInteraction() forces showControls=true;
   * with the controls visible, the full-width Blank between the top and bottom
   * bars sat on top of the gesture layer and swallowed the next double-tap, so
   * repeated fast-forward/rewind only worked again after the 3s auto-hide.
   * Keep the current visibility (hidden stays hidden) and just re-arm the hint
   * timers; the hint layer itself is HitTestMode.None.
   */
  private registerDoubleTapActivity(): number {
    this.interactionEpoch++;
    this.clearHideTimer();
    this.clearTransientHintTimers();
    this.showForwardHint = false;
    this.showBackwardHint = false;
    this.activeInteraction = PlayerInteractionKind.NONE;
    this.scheduleHideControls();
    return this.interactionEpoch;
  }

  /**
   * 长按倍速激活（LongPressGesture.onAction）。Exclusive 手势组保证此刻
   * 单击/双击/滑动都已失败，不会在同一个触摸序列里竞争。
   */
  private onHoldSpeedStart(): void {
    if (this.speedBoostActive) {
      return;
    }
    // 长按倍速同属「隐藏态也放行」的进度控制，不要求先点亮 UI
    if (!this.playbackConfig.holdSpeedEnabled) {
      Logger.debug(TAG, 'Hold speed boost ignored reason=disabled');
      return;
    }
    if (this.curSource.isLive || !this.vm.isPlaying || this.isSliderDragging || this.hasError) {
      Logger.debug(TAG, `Hold speed boost ignored live=${this.curSource.isLive} `
        + `playing=${this.vm.isPlaying} slider=${this.isSliderDragging} error=${this.hasError}`);
      return;
    }
    const target = this.playbackConfig.holdSpeedValue;
    if (Math.abs(this.vm.playbackSpeed - target) < 0.001) {
      return; // 已在目标倍速，无需加速也不用显示提示
    }
    this.speedBoostActive = true;
    this.speedBoostPreviousSpeed = this.vm.playbackSpeed;
    this.speedBoostTarget = target;
    this.controller.setPlaybackSpeed(target);
    this.showSpeedBoostHint = true;
    Logger.debug(TAG, `Hold speed boost start ${this.speedBoostPreviousSpeed}x -> ${target}x`);
  }

  private onHoldSpeedEnd(reason: string): void {
    if (!this.speedBoostActive) {
      return;
    }
    this.speedBoostActive = false;
    this.showSpeedBoostHint = false;
    this.controller.setPlaybackSpeed(this.speedBoostPreviousSpeed);
    Logger.debug(TAG, `Hold speed boost end reason=${reason} restored=${this.speedBoostPreviousSpeed}x`);
  }

  private registerControlActivity(): void {
    this.beginInteraction(PlayerInteractionKind.NONE);
    this.scheduleHideControls();
  }

  private controlMenuDepth: number = 0;

  private onControlMenuAppear(): void {
    this.controlMenuDepth++;
    this.beginInteraction(PlayerInteractionKind.MENU);
  }

  private onControlMenuDisappear(): void {
    // 折叠菜单打开二级时父层可能先 onDisAppear；用深度计数避免控件立刻收起
    this.controlMenuDepth = Math.max(0, this.controlMenuDepth - 1);
    if (this.controlMenuDepth > 0) {
      return;
    }
    if (this.activeInteraction === PlayerInteractionKind.MENU) {
      this.activeInteraction = PlayerInteractionKind.NONE;
    }
    this.interactionEpoch++;
    this.scheduleHideControls();
  }

  private calculateSurfaceSizeByArea(width: number, height: number): void {
    if (this.curSource.width && this.curSource.height) {
      const videoAspectRatio = this.curSource.width / this.curSource.height;
      const containerAspectRatio = width / height;

      if (videoAspectRatio > containerAspectRatio) {
        // 视频更宽，以宽度为准
        this.surfaceWidth = width;
        this.surfaceHeight = width / videoAspectRatio;
      } else {
        // 视频更高或相等，以高度为准
        this.surfaceHeight = height;
        this.surfaceWidth = height * videoAspectRatio;
      }

      Logger.debug(TAG, `DEBUG - Layout Update: Container[${Math.round(width)}x${Math.round(height)}], ` +
        `Surface[${this.surfaceWidth}x${this.surfaceHeight}], ` +
        `LandscapeState: ${this.isFullLandscapeScreen}`);
    } else {
      this.surfaceWidth = width;
      this.surfaceHeight = height;
    }
  }



  private calculateSurfaceSize(): void {
    if (this.containerWidthPX > 0 && this.containerHeightPX > 0) {
      this.calculateSurfaceSizeByArea(this.containerWidthPX, this.containerHeightPX);
      return;
    }
    
    // 优先使用实际区域数据，如果没有则尝试根据全屏状态预计算
    try {
      const componentUtils = this.getUIContext().getComponentUtils();
      const componentInfo = componentUtils.getRectangleById('PlayerContainer');
      if (componentInfo && componentInfo.size) {
        const width = Number(componentInfo.size.width);
        const height = Number(componentInfo.size.height);
        if (width > 0 && height > 0) {
          this.calculateSurfaceSizeByArea(width, height);
          return;
        }
      }
    } catch (e) {
      Logger.warn(TAG, 'Failed to get component info via componentUtils');
    }

    // 兜底方案：基于视频比例和全屏状态预计算
    if (this.curSource.width && this.curSource.height) {
      const videoAspectRatio = this.curSource.width / this.curSource.height;
      let deviceWidth: number = AppStorage.get<number>('deviceWidth') || 0;
      let deviceHeight: number = AppStorage.get<number>('deviceHeight') || 0;
      
      if (deviceWidth > 0 && deviceHeight > 0) {
        let availableWidth = deviceWidth;
        let availableHeight = this.isFullLandscapeScreen ? deviceHeight : deviceWidth / videoAspectRatio;
        
        this.calculateSurfaceSizeByArea(availableWidth, availableHeight);
      }
    }
  }

  onIndexChange(): void {
    this.controller.setCurIndex(this.curIndex);
    if (this.curIndex !== this.index) {
      this.controller.syncPause();
    } else if (this.vm.isReady && this.isPageShow) {
      this.controller.syncPlay();
    }
  }

  private togglePlayback() {
    this.registerControlActivity();
    if (!this.vm.isReady || !this.hasStreams) {
      Logger.warn(TAG, `togglePlayback ignored: isReady=${this.vm.isReady}, hasStreams=${this.hasStreams}`);
      return;
    }
    if (this.vm.isPlaying) {
      this.controller.syncPause();
    } else {
      this.controller.syncPlay();
    }
    this.syncPlaybackStateFromController();
  }

  /**
   * 暂停时显示中央播放按钮（Bilibili 风格）：已就绪、未在播放/缓冲、
   * 非拖动进度条、无错误。ended 状态同样显示（点击 = 从头重播）。
   * 用户可以在「手势与操控」里关掉它，只保留"点画面"切换。
   */
  private showCenterPlayButton(): boolean {
    if (!this.uiConfig.showCenterPlayButton) {
      return false;
    }
    return this.vm.isReady && !this.vm.isPlaying && !this.vm.isBuffering
      && !this.isSliderDragging && !this.hasError;
  }

  /**
   * 判断这次点击是否落在中央播放按钮上。
   *
   * <p>中央按钮是容器里的子节点，而容器的单击手势是 parallelGesture：
   * 两者会同时收到同一次点击。若不去重，用户点中央按钮恢复播放时，
   * 容器单击又会"显隐控件"，控件反而在操作瞬间消失——这正是反馈里
   * "明明在点屏幕交互，UI 却主动消失"的成因。
   */
  private isCenterButtonTap(event: GestureEvent): boolean {
    if (!this.showCenterPlayButton()) {
      return false;
    }
    const x: number = event.fingerList[0]?.localX ?? -1;
    const y: number = event.fingerList[0]?.localY ?? -1;
    if (x < 0 || y < 0) {
      return false;
    }
    const cx: number = this.containerVpWidth / 2;
    const cy: number = this.containerVpHeight / 2;
    // 按钮 72vp 直径 + 容差，覆盖整个可点区域。
    return Math.abs(x - cx) <= CENTER_PLAY_BUTTON_HIT_RADIUS
      && Math.abs(y - cy) <= CENTER_PLAY_BUTTON_HIT_RADIUS;
  }

  @Builder
  SpeedMenu() {
    Menu() {
      ForEach([0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], (speed: number) => {
        MenuItem({
          content: speed + 'x',
          endIcon: this.vm.playbackSpeed === speed ? $r('sys.symbol.checkmark') : ''
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
          .backgroundColor(this.vm.playbackSpeed === speed
            ? this.getSelectedMenuBackground() : Color.Transparent)
          .onClick(() => {
            PlayerSession.getInstance().setSessionPlaybackSpeed(speed);
          })
      })
    }
    .onAppear(() => this.onControlMenuAppear())
    .onDisAppear(() => this.onControlMenuDisappear())
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .borderRadius(12)
    .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
    .width(180)
  }

  private closeSubtitleMenus(): void {
    this.showSubtitleMenu = false;
    this.showCollapsedSubtitleMenu = false;
  }

  @Builder
  SubtitleMenu() {
    Menu() {
      MenuItemGroup({ header: $r('app.string.yt_player_subtitle_primary') }) {
        if (this.vm.currentSubtitleUrl === '' && this.playbackConfig.subtitlePreferredTrack.length > 0
          && this.vm.subtitleTracks.length > 0) {
          MenuItem({
            content: $r('app.string.yt_player_subtitle_quick_on')
          })
            .contentFontColor(this.themePrimary)
            .contentFont({ size: 14, weight: FontWeight.Medium })
            .onClick(() => {
              this.closeSubtitleMenus();
              this.onQuickToggleSubtitle();
            })
        }
        MenuItem({
          content: $r('app.string.yt_player_subtitle_off'),
          endIcon: this.vm.currentSubtitleUrl === '' ? $r('sys.symbol.checkmark') : ''
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
          .backgroundColor(this.vm.currentSubtitleUrl === ''
            ? this.getSelectedMenuBackground() : Color.Transparent)
          .onClick(() => {
            // [DISABLED] P3 ASR 已禁用，关闭字幕无需停识别：AsrLiveCaptionService.getInstance().stop();
            this.closeSubtitleMenus();
            PlayerSession.getInstance().selectPrimarySubtitle(-1);
          })
        ForEach(this.getSortedSubtitleEntries(), (entry: SubtitleTrackMenuEntry) => {
          MenuItem({
            content: entry.label,
            endIcon: this.vm.currentSubtitleUrl === entry.track.url ? $r('sys.symbol.checkmark') : ''
          })
            .contentFontColor($r('sys.color.font_primary'))
            .contentFont({ size: 14 })
            .backgroundColor(this.vm.currentSubtitleUrl === entry.track.url
              ? this.getSelectedMenuBackground() : Color.Transparent)
            .onClick(() => {
              // [DISABLED] P3 ASR 已禁用：AsrLiveCaptionService.getInstance().stop();
              this.closeSubtitleMenus();
              PlayerSession.getInstance().selectPrimarySubtitle(entry.originalIndex);
            })
        }, (entry: SubtitleTrackMenuEntry) => `pri_${entry.originalIndex}_${entry.track.url}`)
      }

      if (this.vm.subtitleTracks.length >= 2) {
        MenuItemGroup({ header: $r('app.string.yt_player_subtitle_secondary') }) {
          MenuItem({
            content: $r('app.string.yt_player_subtitle_secondary_off'),
            endIcon: this.vm.secondarySubtitleIndex < 0 ? $r('sys.symbol.checkmark') : ''
          })
            .contentFontColor($r('sys.color.font_primary'))
            .contentFont({ size: 14 })
            .backgroundColor(this.vm.secondarySubtitleIndex < 0
              ? this.getSelectedMenuBackground() : Color.Transparent)
            .onClick(() => {
              this.closeSubtitleMenus();
              PlayerSession.getInstance().selectSecondarySubtitle(-1);
            })
          ForEach(this.getSecondarySubtitleEntries(), (entry: SubtitleTrackMenuEntry) => {
            MenuItem({
              content: entry.label,
              endIcon: this.vm.secondarySubtitleIndex === entry.originalIndex ? $r('sys.symbol.checkmark') : ''
            })
              .contentFontColor($r('sys.color.font_primary'))
              .contentFont({ size: 14 })
              .backgroundColor(this.vm.secondarySubtitleIndex === entry.originalIndex
                ? this.getSelectedMenuBackground() : Color.Transparent)
              .onClick(() => {
                this.closeSubtitleMenus();
                PlayerSession.getInstance().selectSecondarySubtitle(entry.originalIndex);
              })
          }, (entry: SubtitleTrackMenuEntry) => `sec_${entry.originalIndex}_${entry.track.url}`)
        }
      }
      // [DISABLED] AI 整轨字幕翻译（P2：gtx/LLM）——产品决定只保留 YouTube tlang
      // 官方自动翻译轨（本块上方 ForEach 已含），gtx 客户端翻译入口注释，代码保留。
      // if (this.vm.subtitleTracks.length > 0) {
      //   MenuItem({
      //     content: this.getAiTranslateLabel(),
      //     endIcon: this.vm.currentSubtitleUrl.startsWith('ai://') ? $r('sys.symbol.checkmark') : ''
      //   })
      //     .contentFontColor($r('sys.color.font_primary'))
      //     .contentFont({ size: 14 })
      //     .backgroundColor(this.vm.currentSubtitleUrl.startsWith('ai://')
      //       ? this.getSelectedMenuBackground() : Color.Transparent)
      //     .onClick(() => {
      //       this.onAiTranslateClick();
      //     })
      // }
      // [DISABLED] P3 AI 生成字幕（端侧流式 ASR）菜单项：产品只保留 P0 tlang 官方自动翻译轨。
      // 重新启用 = 取消本块及 AVPlayer 内其余 P3 [DISABLED] 注释块（import/监听器/标签与点击处理/注销）。
      // MenuItem({
      //   content: this.getAsrCaptionLabel(),
      //   endIcon: this.vm.currentSubtitleUrl.startsWith('asr://') ? $r('sys.symbol.checkmark') : ''
      // })
      //   .contentFontColor($r('sys.color.font_primary'))
      //   .contentFont({ size: 14 })
      //   .backgroundColor(this.vm.currentSubtitleUrl.startsWith('asr://')
      //     ? this.getSelectedMenuBackground() : Color.Transparent)
      //   .onClick(() => {
      //     this.onAsrCaptionClick();
      //   })
    }
    .onAppear(() => this.onControlMenuAppear())
    .onDisAppear(() => this.onControlMenuDisappear())
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .borderRadius(12)
    .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
    .width(240)
  }

  private hasChaptersOrSegments(): boolean {
    return !this.isLocalMode && (this.chapters.length > 0 || this.sponsorSegments.length > 0);
  }

  private hasMultipleAudioTracks(): boolean {
    return !this.curSource.isLive && !this.isLocalMode && this.controller.getAudioStreamList().length > 1;
  }

  private chaptersSheetTitle(): Resource {
    if (this.chapters.length > 0 && this.sponsorSegments.length > 0) {
      return $r('app.string.yt_player_chapters_and_segments');
    }
    if (this.chapters.length > 0) {
      return $r('app.string.yt_player_chapters');
    }
    return $r('app.string.yt_exp_sb_segments_title');
  }

  private formatSponsorSegmentRange(seg: SponsorSegment): string {
    const startText = secondToTime(Math.floor(Math.max(0, seg.startSec)));
    if (seg.actionType === 'poi' || seg.category === 'poi_highlight') {
      return startText;
    }
    const endText = secondToTime(Math.floor(Math.max(seg.startSec, seg.endSec)));
    return `${startText} - ${endText}`;
  }

  private jumpToSponsorSegment(seg: SponsorSegment): void {
    const targetSec = (seg.actionType === 'poi' || seg.category === 'poi_highlight')
      ? seg.startSec
      : (this.durationTime > 0 ? Math.min(seg.endSec, Math.max(0, this.durationTime - 0.2)) : seg.endSec);
    Logger.info(TAG, `SponsorBlock sheet jump category=${seg.category} action=${seg.actionType} target=${targetSec.toFixed(1)}s`);
    this.controller.syncSeek(targetSec * 1000);
    this.showChaptersSheet = false;
  }

  @Builder
  ChaptersAndSegmentsSheet() {
    Column({ space: 0 }) {
      Row({ space: 10 }) {
        Text(this.chaptersSheetTitle())
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.yourtube_text_primary'))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.canToggleChannelWhitelist()) {
          Button() {
            Row({ space: 4 }) {
              SymbolGlyph($r('sys.symbol.key_shield_fill'))
                .fontSize(13)
                .fontColor([this.experimentalConfig.isChannelWhitelisted(this.currentChannelId())
                  ? this.themePrimary
                  : $r('app.color.yourtube_text_secondary')])
              Text($r('app.string.yt_exp_sb_whitelist_channel'))
                .fontSize(12)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.experimentalConfig.isChannelWhitelisted(this.currentChannelId())
                  ? this.themePrimary
                  : $r('app.color.yourtube_text_primary'))
            }
          }
          .height(30)
          .padding({ left: 10, right: 10 })
          .borderRadius(15)
          .backgroundColor($r('app.color.yourtube_player_control_bg'))
          .onClick(() => this.toggleCurrentChannelWhitelist())
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 16, right: 16, top: 14, bottom: 10 })

      List({ space: 6 }) {
        if (this.chapters.length > 0) {
          ForEach(this.chapters, (chapter: ChapterInfo, index: number) => {
            ListItem() {
              Row({ space: 12 }) {
                if (chapter.thumbnailUrl && chapter.thumbnailUrl.length > 0) {
                  MediaThumb({
                    imageUrl: chapter.thumbnailUrl,
                    placeholderColor: '#222222',
                    widthVp: 88,
                    heightVp: 50,
                    fillParent: false,
                    useAspectRatio: false,
                    borderRadiusVp: 6
                  })
                    .flexShrink(0)
                }

                Column({ space: 4 }) {
                  Text(chapter.title)
                    .fontSize(14)
                    .fontWeight(this.getCurrentChapterIndex() === index ? FontWeight.Bold : FontWeight.Medium)
                    .fontColor(this.getCurrentChapterIndex() === index
                      ? this.themePrimary
                      : $r('app.color.yourtube_text_primary'))
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })

                  Text(secondToTime(Math.floor(Math.max(0, chapter.startTimeSeconds))))
                    .fontSize(12)
                    .fontColor(this.getCurrentChapterIndex() === index
                      ? this.themePrimary
                      : $r('app.color.yourtube_text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (this.getCurrentChapterIndex() === index) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(16)
                    .fontColor([this.themePrimary])
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .borderRadius(10)
              .backgroundColor(this.getCurrentChapterIndex() === index
                ? this.getSelectedMenuBackground()
                : $r('app.color.yourtube_bg_surface_muted'))
              .onClick(() => {
                Logger.info(TAG, `Chapter seek: index=${index} start=${chapter.startTimeSeconds}s`);
                this.controller.syncSeek(chapter.startTimeSeconds * 1000);
                this.showChaptersSheet = false;
              })
            }
          }, (chapter: ChapterInfo, index: number) => `ch_${chapter.startTimeSeconds}_${index}`)
        }

        if (this.sponsorSegments.length > 0) {
          ListItem() {
            Text($r('app.string.yt_exp_sb_segments_title'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.yourtube_text_secondary'))
              .width('100%')
              .padding({ left: 4, top: this.chapters.length > 0 ? 12 : 2, bottom: 4 })
          }

          ForEach(this.sponsorSegments, (seg: SponsorSegment, segIdx: number) => {
            ListItem() {
              Row({ space: 10 }) {
                Circle({ width: 10, height: 10 })
                  .fill(getSponsorCategoryColor(seg.category))
                  .flexShrink(0)

                Column({ space: 2 }) {
                  Text(this.skipCategoryLabel(seg.category))
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('app.color.yourtube_text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(this.formatSponsorSegmentRange(seg))
                    .fontSize(12)
                    .fontColor($r('app.color.yourtube_text_secondary'))
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Button((seg.actionType === 'poi' || seg.category === 'poi_highlight')
                  ? $r('app.string.yt_exp_sb_jump_highlight')
                  : $r('app.string.yt_exp_sb_jump_to_end'))
                  .height(30)
                  .padding({ left: 10, right: 10 })
                  .fontSize(12)
                  .fontColor(this.themePrimary)
                  .backgroundColor($r('app.color.yourtube_player_control_bg'))
                  .borderRadius(15)
                  .onClick(() => this.jumpToSponsorSegment(seg))
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ left: 12, right: 12, top: 10, bottom: 10 })
              .borderRadius(10)
              .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
              .onClick(() => this.jumpToSponsorSegment(seg))
            }
          }, (seg: SponsorSegment, segIdx: number) => `sb_${seg.category}_${seg.startSec}_${seg.endSec}_${segIdx}`)
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, bottom: 20 })
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }

  @Builder
  AudioMenu() {
    Menu() {
      ForEach(this.controller.getAudioStreamList(), (stream: StreamInfo, index: number) => {
        MenuItem({
          content: this.getAudioLabel(stream),
          endIcon: this.getSelectedAudioIndex() === index ? $r('sys.symbol.checkmark') : ''
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
          .backgroundColor(this.getSelectedAudioIndex() === index
            ? this.getSelectedMenuBackground() : Color.Transparent)
          .onClick(() => {
            this.controller.switchToAudioIndex(index);
          })
      }, (stream: StreamInfo, index: number) =>
        `${stream.itag ?? ''}_${stream.audioTrackId || ''}_${stream.sourceClient || ''}_${index}`)
    }
    .onAppear(() => this.onControlMenuAppear())
    .onDisAppear(() => this.onControlMenuDisappear())
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .borderRadius(12)
    .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
    .width(240)
  }

  @Builder
  VideoMenu() {
    Menu() {
      ForEach(this.controller.getMergedVideoList(), (entry: VideoEntry, index: number) => {
        MenuItem({
          content: this.getVideoLabel(entry.stream),
          endIcon: this.getSelectedVideoIndex() === index ? $r('sys.symbol.checkmark') : ''
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
          .backgroundColor(this.getSelectedVideoIndex() === index
            ? this.getSelectedMenuBackground() : Color.Transparent)
          .onClick(() => {
            this.controller.switchToVideoEntry(entry);
          })
      }, (entry: VideoEntry, index: number) =>
        `${entry.stream.itag ?? ''}_${entry.stream.audioTrackId || ''}_${entry.stream.sourceClient || ''}_${index}`)
    }
    .onAppear(() => this.onControlMenuAppear())
    .onDisAppear(() => this.onControlMenuDisappear())
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .borderRadius(12)
    .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
    .width(220)
  }

  private getSelectedVideoIndex(): number {
    const list = this.controller.getMergedVideoList();
    const current = this.vm.playerModel.currentVideoStream;
    const idx = list.findIndex((e: VideoEntry) => e.stream === current);
    return idx >= 0 ? idx : 0;
  }

  private normalizeSubtitleLangTag(code: string): string {
    const raw = (code || '').trim().toLowerCase().replace(/_/g, '-');
    if (raw.length === 0) {
      return '';
    }
    if (raw === 'zh-cn' || raw === 'zh-sg' || raw.startsWith('zh-hans')) {
      return 'zh-hans';
    }
    if (raw === 'zh-tw' || raw === 'zh-hk' || raw === 'zh-mo' || raw.startsWith('zh-hant')) {
      return 'zh-hant';
    }
    return raw;
  }

  private subtitlePrimaryLangTag(code: string): string {
    const norm = this.normalizeSubtitleLangTag(code);
    const dash = norm.indexOf('-');
    return dash > 0 ? norm.substring(0, dash) : norm;
  }

  private toDisplayLocaleCode(code: string): string {
    const norm = this.normalizeSubtitleLangTag(code);
    if (norm === 'zh-hans') {
      return 'zh-Hans';
    }
    if (norm === 'zh-hant') {
      return 'zh-Hant';
    }
    return (code || '').trim();
  }

  private stripSubtitleNoise(rawName: string): string {
    return rawName
      .replace(/\s*[（(][^()（）]*(?:auto[- ]?generated|自动生成|自動生成|自動產生|自動翻訳|自动翻译|自動翻譯|auto[- ]?translated|자동\s*생성|автосоздание|automatisch|généré|generado|generato|gerado|تلقائي)[^()（）]*[）)]\s*/gi, '')
      .replace(/\s*[-·]\s*(?:asr|auto[- ]?generated)\s*$/i, '')
      .trim();
  }

  private getSubtitleBaseName(track: SubtitleTrack, displayLocale: string): string {
    const code = (track.languageCode || '').trim();
    if (code.length > 0) {
      const queryCode = this.toDisplayLocaleCode(code);
      try {
        const localized = i18n.System.getDisplayLanguage(queryCode, displayLocale);
        if (localized && localized.trim().length > 0 && localized.toLowerCase() !== queryCode.toLowerCase()) {
          return localized.trim();
        }
      } catch (_e) {
        // Fallback to cleaned track.name below
      }
    }
    const cleaned = this.stripSubtitleNoise(track.name || '');
    if (cleaned.length > 0) {
      return cleaned;
    }
    return code || 'CC';
  }

  private getSubtitleLabel(track: SubtitleTrack): string {
    const displayLocale = LanguageManager.resolveAppliedLanguage(this.uiConfig);
    const baseName = this.getSubtitleBaseName(track, displayLocale);
    const rm = this.getUIContext().getHostContext()?.resourceManager ?? getContext().resourceManager;
    if (track.isAutoTranslated) {
      try {
        return rm.getStringSync($r('app.string.yt_player_subtitle_label_auto_translated').id, baseName);
      } catch (_e) {
        return baseName;
      }
    }
    if (track.isAutoGenerated || track.kind === 'asr') {
      try {
        return rm.getStringSync($r('app.string.yt_player_subtitle_label_auto_generated').id, baseName);
      } catch (_e) {
        return baseName;
      }
    }
    return baseName;
  }

  private getSubtitleTrackKindRank(track: SubtitleTrack): number {
    if (track.isAutoTranslated) {
      return 2;
    }
    if (track.isAutoGenerated || track.kind === 'asr') {
      return 1;
    }
    return 0;
  }

  private getSubtitleTrackLangRank(track: SubtitleTrack, preferredLangs: string[]): number {
    const trackNorm = this.normalizeSubtitleLangTag(track.languageCode);
    const trackPrimary = this.subtitlePrimaryLangTag(track.languageCode);
    if (trackNorm.length > 0) {
      for (let i = 0; i < preferredLangs.length; i++) {
        const prefNorm = this.normalizeSubtitleLangTag(preferredLangs[i]);
        if (prefNorm.length > 0 && prefNorm === trackNorm) {
          return 0;
        }
      }
      for (let i = 0; i < preferredLangs.length; i++) {
        const prefPrimary = this.subtitlePrimaryLangTag(preferredLangs[i]);
        if (prefPrimary.length > 0 && prefPrimary === trackPrimary) {
          return 1;
        }
      }
    }
    if (track.isDefault) {
      return 2;
    }
    return 3;
  }

  private getSortedSubtitleEntries(): SubtitleTrackMenuEntry[] {
    const tracks = this.vm.subtitleTracks;
    if (!tracks || tracks.length === 0) {
      return [];
    }
    const preferredLangs: string[] = [];
    const prefRaw = this.playbackConfig.subtitlePreferredTrack.trim();
    if (prefRaw.length > 0 && prefRaw !== 'original') {
      const pipeIdx = prefRaw.indexOf('|');
      const prefCode = pipeIdx > 0 ? prefRaw.substring(0, pipeIdx).trim() : prefRaw;
      if (prefCode.length > 0) {
        preferredLangs.push(prefCode);
      }
    }
    const subTarget = TranslationService.subtitleTargetLanguage();
    if (subTarget.length > 0) {
      preferredLangs.push(subTarget);
    }
    const appLang = LanguageManager.resolveAppliedLanguage(this.uiConfig);
    if (appLang.length > 0) {
      preferredLangs.push(appLang);
    }

    const entries: SubtitleTrackMenuEntry[] = [];
    const labelCounts: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < tracks.length; i++) {
      const t = tracks[i];
      const lbl = this.getSubtitleLabel(t);
      labelCounts.set(lbl, (labelCounts.get(lbl) ?? 0) + 1);
      entries.push({ originalIndex: i, track: t, label: lbl });
    }

    // Disambiguate colliding concise labels (e.g. en-US vs en-GB) without adding raw noise
    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      if ((labelCounts.get(entry.label) ?? 0) > 1) {
        const cleaned = this.stripSubtitleNoise(entry.track.name || '');
        if (cleaned.length > 0 && cleaned !== entry.label) {
          entry.label = cleaned;
        } else if (entry.track.languageCode.trim().length > 0) {
          entry.label = `${entry.label} (${entry.track.languageCode.trim()})`;
        }
      }
    }

    entries.sort((a: SubtitleTrackMenuEntry, b: SubtitleTrackMenuEntry): number => {
      const langDiff = this.getSubtitleTrackLangRank(a.track, preferredLangs)
        - this.getSubtitleTrackLangRank(b.track, preferredLangs);
      if (langDiff !== 0) {
        return langDiff;
      }
      const kindDiff = this.getSubtitleTrackKindRank(a.track) - this.getSubtitleTrackKindRank(b.track);
      if (kindDiff !== 0) {
        return kindDiff;
      }
      const nameDiff = a.label.localeCompare(b.label);
      if (nameDiff !== 0) {
        return nameDiff;
      }
      return a.originalIndex - b.originalIndex;
    });
    return entries;
  }

  private getSecondarySubtitleEntries(): SubtitleTrackMenuEntry[] {
    const primaryUrl = this.vm.currentSubtitleUrl;
    return this.getSortedSubtitleEntries().filter(
      (entry: SubtitleTrackMenuEntry): boolean => entry.track.url !== primaryUrl
    );
  }

  private getCurrentSubtitleSummaryLabel(): ResourceStr {
    if (this.vm.currentSubtitleUrl.length === 0) {
      return $r('app.string.yt_player_subtitle_off');
    }
    const active = this.vm.subtitleTracks.find(
      (t: SubtitleTrack): boolean => t.url === this.vm.currentSubtitleUrl
    );
    if (!active) {
      return $r('app.string.yt_player_subtitle_off');
    }
    return this.getSubtitleLabel(active);
  }

  private onQuickToggleSubtitle(): void {
    this.registerControlActivity();
    const enabled = PlayerSession.getInstance().toggleSubtitleEnabled();
    try {
      if (enabled) {
        const active = this.vm.subtitleTracks.find(
          (t: SubtitleTrack): boolean => t.url === this.vm.currentSubtitleUrl
        );
        if (active) {
          this.getUIContext().getPromptAction().showToast({
            message: this.getSubtitleLabel(active),
            duration: 1500
          });
        }
      } else {
        this.getUIContext().getPromptAction().showToast({
          message: $r('app.string.yt_player_subtitle_off'),
          duration: 1500
        });
      }
    } catch (_e) {
      // Non-blocking toast
    }
  }

  private splitSubtitleLines(text: string): string[] {
    if (!text || text.length === 0) {
      return [];
    }
    const raw = text.split('\n');
    const lines: string[] = [];
    for (let i = 0; i < raw.length; i++) {
      const trimmed = raw[i].trim();
      if (trimmed.length > 0) {
        lines.push(trimmed);
      }
    }
    return lines;
  }

  private getPrimarySubtitleLines(): string[] {
    if (this.vm.currentSubtitleUrl.length === 0 || this.vm.subtitleText.length === 0) {
      return [];
    }
    return this.splitSubtitleLines(this.vm.subtitleText);
  }

  private getSecondarySubtitleLines(): string[] {
    if (this.vm.secondarySubtitleUrl.length === 0 || this.vm.secondarySubtitleText.length === 0) {
      return [];
    }
    return this.splitSubtitleLines(this.vm.secondarySubtitleText);
  }

  private getPrimarySubtitleFontSize(): number {
    return (this.isFullLandscapeScreen ? 18 : 14) * Number(this.playbackConfig.subtitleFontScale);
  }

  private getSecondarySubtitleFontSize(): number {
    return Math.max(10, Math.round(this.getPrimarySubtitleFontSize() * 0.82 * 10) / 10);
  }

  private getPrimarySubtitleColor(): string {
    return SUBTITLE_FONT_COLOR_VALUES[this.playbackConfig.subtitleFontColor] || '#FFFFFF';
  }

  private getSecondarySubtitleColor(): string {
    const colorKey = this.playbackConfig.subtitleFontColor;
    if (colorKey === 'yellow') {
      return '#FFF59D';
    }
    if (colorKey === 'green') {
      return '#A5D6A7';
    }
    if (colorKey === 'cyan') {
      return '#B2EBF2';
    }
    return '#E8E8E8';
  }

  private getSubtitlePillBackground(): string {
    const opacity = normalizeSubtitleBgOpacity(this.playbackConfig.subtitleBgOpacity);
    if (opacity <= 0) {
      return 'rgba(0, 0, 0, 0)';
    }
    return `rgba(0, 0, 0, ${opacity})`;
  }

  private getSubtitleLineHeight(fontSize: number): number {
    return Math.round(fontSize * 1.32);
  }

  private getSubtitlePillPadding(fontSize: number): Padding {
    const h = Math.max(8, Math.round(fontSize * 0.55));
    const v = Math.max(2, Math.round(fontSize * 0.18));
    return { left: h, right: h, top: v, bottom: v };
  }

  private getSubtitlePillRadius(fontSize: number): number {
    return Math.max(4, Math.round(fontSize * 0.28));
  }

  private getSubtitleTextShadow(): ShadowOptions | ShadowOptions[] {
    const style: SubtitleEdgeStyle = this.playbackConfig.subtitleEdgeStyle;
    if (style === 'none') {
      return { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 };
    }
    if (style === 'shadow') {
      return [{ radius: 4, color: '#CC000000', offsetX: 0, offsetY: 1.5 }];
    }
    if (style === 'outline') {
      return [
        { radius: 1.5, color: '#E6000000', offsetX: -1.2, offsetY: -1.2 },
        { radius: 1.5, color: '#E6000000', offsetX: 1.2, offsetY: -1.2 },
        { radius: 1.5, color: '#E6000000', offsetX: -1.2, offsetY: 1.2 },
        { radius: 1.5, color: '#E6000000', offsetX: 1.2, offsetY: 1.2 }
      ];
    }
    return [
      { radius: 1.5, color: '#E6000000', offsetX: -1.2, offsetY: -1.2 },
      { radius: 1.5, color: '#E6000000', offsetX: 1.2, offsetY: -1.2 },
      { radius: 1.5, color: '#E6000000', offsetX: -1.2, offsetY: 1.2 },
      { radius: 1.5, color: '#E6000000', offsetX: 1.2, offsetY: 1.2 },
      { radius: 4, color: '#B3000000', offsetX: 0, offsetY: 1.5 }
    ];
  }

  // ── AI 字幕翻译（P2）──

  private aiTranslateProgressListener = (p: SubtitleTranslateProgress | null): void => {
    if (!p) {
      this.aiTranslateProgress = '';
      return;
    }
    this.aiTranslateProgress = `${p.doneBatches}/${p.totalBatches}`;
  }

  private getAiTranslateLabel(): string {
    const base = getContext().resourceManager.getStringSync($r('app.string.yt_ai_translate_menu').id);
    if (this.aiTranslateProgress.length > 0) {
      return `${base} ${this.aiTranslateProgress}`;
    }
    const target = TranslationService.targetLanguage();
    let langName = target;
    try {
      langName = i18n.System.getDisplayLanguage(target, target);
    } catch (_e) {
      // 回退为语言码
    }
    return `${base} · ${langName}`;
  }

  private onAiTranslateClick(): void {
    const service = SubtitleTranslationService.getInstance();
    // 翻译中点击 = 取消任务（不应用、不写缓存）
    if (service.isRunning()) {
      service.cancel();
      this.aiTranslateProgress = '';
      return;
    }
    const videoId = this.curSource.videoId ?? '';
    if (videoId.length === 0 || this.vm.subtitleTracks.length === 0) {
      return;
    }
    const cfg = LlmTranslateConfig.get();
    if (cfg.engine === 'llm' && !cfg.isLlmReady()) {
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.yt_ai_translate_llm_not_configured'),
        duration: 2500
      });
      return;
    }
    const target = TranslationService.targetLanguage();
    service.translateAndApply(videoId, this.vm.subtitleTracks, this.vm.currentSubtitleUrl, this.controller)
      .then((res) => {
        if (res.ok) {
          // 记忆 AI 翻译偏好：新视频自动触发翻译（缓存命中时瞬时完成）
          PreferencesStore.setString('cfg_subtitle_preferred_lang', `ai:${target}`);
          if (res.partial) {
            this.getUIContext().getPromptAction().showToast({
              message: $r('app.string.yt_ai_translate_partial_fail'),
              duration: 2500
            });
          }
        } else if (!res.cancelled) {
          const detail = res.error ? TranslationService.formatError(res.error) : '';
          Logger.warn(TAG, `AI translate failed: ${detail || '-'}`);
          const hostCtx = this.getUIContext().getHostContext();
          const baseMsg = hostCtx?.resourceManager
            ? hostCtx.resourceManager.getStringSync($r('app.string.yt_ai_translate_failed').id)
            : '';
          this.getUIContext().getPromptAction().showToast({
            message: (baseMsg.length > 0 && detail.length > 0)
              ? `${baseMsg}: ${detail}`
              : $r('app.string.yt_ai_translate_failed'),
            duration: 3000
          });
        }
      });
  }

  // ── [DISABLED] AI 生成字幕（P3，端侧实时 ASR，PCM tap）——随菜单项禁用，代码保留 ──
  //
  // @State asrProgress: string = '';
  //
  // private getAsrCaptionLabel(): string {
  //   const base = getContext().resourceManager.getStringSync($r('app.string.yt_asr_menu').id);
  //   return this.asrProgress.length > 0 ? `${base} · ${this.asrProgress}` : base;
  // }
  //
  // private asrLiveProgressListener = (p: AsrLiveProgress | null): void => {
  //   if (!p) {
  //     this.asrProgress = '';
  //     return;
  //   }
  //   if (p.phase === 'model') {
  //     let phase: string = p.phase;
  //     try {
  //       phase = getContext().resourceManager.getStringSync($r('app.string.yt_asr_phase_model').id);
  //     } catch (_e) {
  //       // 资源读取失败退回原始 phase 名
  //     }
  //     this.asrProgress = `${phase} ${p.percent}%`;
  //     return;
  //   }
  //   try {
  //     this.asrProgress = getContext().resourceManager.getStringSync($r('app.string.yt_asr_live_progress').id);
  //   } catch (_e) {
  //     this.asrProgress = '';
  //   }
  // }
  //
  // private asrLiveErrorListener = (err: string): void => {
  //   Logger.warn(TAG, `ASR live caption failed: ${err}`);
  //   this.asrProgress = '';
  //   this.getUIContext().getPromptAction().showToast({
  //     message: $r('app.string.yt_asr_failed'),
  //     duration: 2500
  //   });
  // }
  //
  // private onAsrCaptionClick(): void {
  //   const live = AsrLiveCaptionService.getInstance();
  //   if (live.isActive()) {
  //     // 关闭路径：停 tap + 清掉 asr:// overlay 选中态
  //     live.stop();
  //     this.asrProgress = '';
  //     this.controller.switchSubtitle('');
  //     return;
  //   }
  //   const videoId = this.curSource.videoId ?? '';
  //   if (videoId.length === 0) {
  //     return;
  //   }
  //   // 唯一定位：调用本地模型对当前播放实时生成字幕（MPV PCM tap）
  //   live.start(videoId, this.controller)
  //     .then((ok: boolean) => {
  //       if (!ok) {
  //         Logger.warn(TAG, `ASR live caption start failed video=${videoId}`);
  //         this.getUIContext().getPromptAction().showToast({
  //           message: $r('app.string.yt_asr_failed'),
  //           duration: 2500
  //         });
  //       }
  //     });
  // }

  private getAudioLabel(stream: StreamInfo): string {
    return stream.audioTrackName?.trim()
      || stream.audioLanguage?.trim()
      || stream.audioTrackId?.trim()
      || stream.codecs?.trim()
      || 'Audio';
  }

  private getVideoLabel(stream: StreamInfo): string | Resource {
    // Live "Auto" entry = master playlist (localized string).
    if ((stream.kind || '') === 'manifest_hls') {
      return $r('app.string.yt_quality_auto');
    }
    const values: string[] = [];
    if (stream.quality?.trim()) values.push(stream.quality);
    if (stream.codecs?.trim()) values.push(stream.codecs);
    return values.join(' · ');
  }

  private getSelectedMenuBackground(): string {
    return ThemeColorUtil.selectedBackground(this.themePrimary);
  }

  private getSelectedAudioIndex(): number {
    return this.controller.getCurrentAudioIndex();
  }

  private getCurrentChapterIndex(): number {
    let selected = -1;
    for (let i = 0; i < this.chapters.length; i++) {
      if (this.chapters[i].startTimeSeconds > this.currentTime) {
        break;
      }
      selected = i;
    }
    return selected;
  }

  private getControlComfortSidePad(): number {
    return Math.min(CONTROL_SIDE_MAX,
      Math.max(CONTROL_SIDE_MIN, Math.round(this.containerVpWidth * 0.035)));
  }

  private getControlLeftPad(): number {
    const comfort = this.getControlComfortSidePad();
    return this.isFullLandscapeScreen
      ? Math.max(comfort, this.playerControlAvoidLeft + CONTROL_SAFE_GAP)
      : comfort;
  }

  private getControlRightPad(): number {
    const comfort = this.getControlComfortSidePad();
    return this.isFullLandscapeScreen
      ? Math.max(comfort, this.playerControlAvoidRight + CONTROL_SAFE_GAP)
      : comfort;
  }

  private getControlTopPad(): number {
    return this.isFullLandscapeScreen
      ? Math.max(FULLSCREEN_VERTICAL_INSET, this.playerControlAvoidTop + CONTROL_SAFE_GAP)
      : CONTROL_VERTICAL_INSET;
  }

  private getControlBottomPad(): number {
    return this.isFullLandscapeScreen
      ? Math.max(FULLSCREEN_VERTICAL_INSET, this.navBarHeight + CONTROL_SAFE_GAP,
        this.playerControlAvoidBottom + CONTROL_SAFE_GAP)
      : CONTROL_VERTICAL_INSET;
  }

  private getControlItemGap(): number {
    return this.containerVpWidth > 0 && this.containerVpWidth < COMPACT_CONTROL_WIDTH ? 4 : 8;
  }

  /** 章节 / 字幕 / 音轨 / 画质 / 倍速 是否作为顶部独立图标展示 */
  private getTopToolCount(): number {
    let count = this.curSource.isLive ? 0 : 1; // 倍速点播常驻，直播禁用
    if (this.hasChaptersOrSegments()) {
      count++;
    }
    // 字幕菜单对 VOD 常驻：无原生轨时仍有 AI 翻译（P2）/ AI 生成字幕（P3）入口
    // 本地文件没有在线字幕轨与 AI 翻译入口，不计入。
    if (!this.curSource.isLive && !this.isLocalMode) {
      count++;
    }
    if (this.hasMultipleAudioTracks()) {
      count++;
    }
    if (!this.isLocalMode && this.controller.getMergedVideoList().length > 0
      && (!this.curSource.isLive || this.vm.playerModel.liveQualityReady)) {
      count++;
    }
    count++; // 画面比例按钮常驻
    count++; // 更多菜单（详细统计信息 / 停止播放）常驻
    return count;
  }

  private estimateTopToolsWidthVp(): number {
    const gap = this.getControlItemGap();
    const count = this.getTopToolCount();
    if (count <= 0) {
      return 0;
    }
    return count * SPEED_CONTROL_WIDTH + Math.max(0, count - 1) * gap;
  }

  /**
   * 非沉浸全屏，或右侧工具预估宽度 > 播放区一半 → 收成三横杠总菜单。
   */
  private shouldCollapseTopTools(): boolean {
    if (!this.isFullLandscapeScreen) {
      return true;
    }
    if (this.containerVpWidth <= 0) {
      return false;
    }
    const usable = Math.max(0, this.containerVpWidth - this.getControlLeftPad()
      - this.getControlRightPad() - CONTROL_SLOT_SIZE);
    return this.estimateTopToolsWidthVp() > usable * TOP_TOOLS_HALF_RATIO;
  }

  private getTimeLabelWidth(): number {
    const durationText = secondToTime(Math.floor(Math.max(0, this.durationTime)));
    if (durationText.length > 8) {
      return 86;
    }
    if (durationText.length > 5) {
      return 70;
    }
    return 54;
  }

  private getCombinedTimeLabelWidth(): number {
    return this.getTimeLabelWidth() * 2 + 14;
  }

  private isTvOrLargeScreen(): boolean {
    return deviceInfo.deviceType === 'tv' || this.containerVpWidth >= 1000;
  }

  private controlBarSlotSize(): number {
    return this.isTvOrLargeScreen() ? 50 : 42;
  }

  private controlBarIconSize(): number {
    return this.isTvOrLargeScreen() ? 26 : 24;
  }

  private controlBarTextSize(): number {
    return this.isTvOrLargeScreen() ? 16 : 14;
  }

  private shouldShowTopTitleBar(): boolean {
    return this.isFullLandscapeScreen || this.containerVpWidth >= 600;
  }

  private getTopBarTitle(): string {
    const selectedTitle = (this.selectedVideo?.title || '').trim();
    if (selectedTitle.length > 0) {
      return selectedTitle;
    }
    if (typeof this.curSource.description === 'string') {
      const desc = this.curSource.description.trim();
      if (desc.length > 0) {
        return desc;
      }
    }
    return '';
  }

  private getTopBarAuthor(): string {
    return (this.selectedVideo?.author || '').trim();
  }

  private formatResolutionBadge(resolutionString: string): string {
    const raw = (resolutionString || '').trim();
    if (raw.length === 0) {
      return '';
    }
    const match = /^(\d+)p/i.exec(raw);
    if (!match) {
      return raw.toUpperCase();
    }
    const p = parseInt(match[1], 10);
    if (p >= 4320) {
      return '8K';
    }
    if (p >= 2160) {
      return '4K';
    }
    if (p >= 1440) {
      return '2K';
    }
    return `${p}P`;
  }

  private getTopBarSpecBadge(): string {
    if (this.curSource.isLive) {
      return 'LIVE';
    }
    let res = '';
    let fpsNum = 0;

    // 权威来源（对齐 PipePipe / NewPipeExtractor）：始终优先按视频流 itag 查 ItagItem 表，
    // 避免 21:9 宽银幕电影按 videoHeight 被降级误判、或 9:16 竖屏按 videoHeight 被升级误判。
    const itag = this.vm.currentVideoItag;
    if (itag > 0 && ItagItem.isSupported(itag)) {
      const itagItem = ItagItem.getItag(itag);
      res = this.formatResolutionBadge(itagItem.getResolutionString() || '');
      if (itagItem.getFps() >= 48) {
        fpsNum = itagItem.getFps();
      }
    }

    // 仅本地无 itag 文件或未知 itag 时按短边兜底（防止竖屏 1080×1920 误判为 2K）。
    if (res.length === 0) {
      const shortSide = (this.vm.videoWidth > 0 && this.vm.videoHeight > 0)
        ? Math.min(this.vm.videoWidth, this.vm.videoHeight)
        : this.vm.videoHeight;
      if (shortSide >= 4320) {
        res = '8K';
      } else if (shortSide >= 2160) {
        res = '4K';
      } else if (shortSide >= 1440) {
        res = '2K';
      } else if (shortSide >= 1080) {
        res = '1080P';
      } else if (shortSide >= 720) {
        res = '720P';
      } else if (shortSide >= 480) {
        res = '480P';
      } else if (shortSide > 0) {
        res = `${shortSide}P`;
      }
    }

    if (fpsNum <= 0 && this.vm.frameRate >= 48) {
      fpsNum = Math.round(this.vm.frameRate);
    }
    const fps = fpsNum >= 48 ? `${fpsNum}fps` : '';
    if (res && fps) {
      return `${res} ${fps}`;
    }
    return res || fps;
  }

  private buildCenterPlayPointLight(): VisualEffect | undefined {
    if (!MaterialUtil.supportsImmersive()) {
      return undefined;
    }
    try {
      return new hdsEffect.HdsEffectBuilder()
        .pointLight({
          sourceType: hdsEffect.PointLightSourceType.SOFT,
          illuminatedType: hdsEffect.PointLightIlluminatedType.BORDER_CONTENT,
          options: {
            color: '#4DFFFFFF',
            intensity: 0.65,
            height: 48,
            bloom: 0.25
          }
        })
        .buildEffect();
    } catch (_e) {
      return undefined;
    }
  }

  private handlePlayerKeyEvent(event: KeyEvent): void {
    if (event.type !== KeyType.Down) {
      return;
    }
    const code = event.keyCode;
    if (code === KeyCode.KEYCODE_SPACE
      || code === KeyCode.KEYCODE_ENTER
      || code === KeyCode.KEYCODE_DPAD_CENTER
      || code === KeyCode.KEYCODE_MEDIA_PLAY_PAUSE) {
      this.registerControlActivity();
      this.togglePlayback();
      return;
    }
    if (code === KeyCode.KEYCODE_DPAD_LEFT || code === KeyCode.KEYCODE_DPAD_RIGHT) {
      if (!this.showControls && !this.curSource.isLive && this.durationTime > 0) {
        const step = Math.max(5, this.playbackConfig.doubleTapSeekSeconds || 15);
        const delta = code === KeyCode.KEYCODE_DPAD_RIGHT ? step : -step;
        const target = Math.max(0, Math.min(this.durationTime, this.currentTime + delta));
        this.controller.syncSeekFast(target * 1000);
      }
      this.registerControlActivity();
      return;
    }
    if (code === KeyCode.KEYCODE_DPAD_UP || code === KeyCode.KEYCODE_DPAD_DOWN) {
      this.registerControlActivity();
      return;
    }
    if (code === KeyCode.KEYCODE_ESCAPE) {
      if (this.showControls) {
        this.showControls = false;
      } else if (this.isFullLandscapeScreen && this.onFullScreenClick) {
        this.onFullScreenClick(false);
      }
    }
  }

  /**
   * Timeline labels are optional chrome. Base compact mode on the player
   * surface itself, not the physical device/window, so split-screen, folding
   * and embedded portrait players all give their limited width to the slider.
   */
  private shouldShowTimelineText(): boolean {
    return !this.curSource.isLive
      && this.containerVpWidth >= TIMELINE_TEXT_MIN_WIDTH
      && this.containerVpHeight >= TIMELINE_TEXT_MIN_HEIGHT;
  }

  @Builder
  AudioOnlyCoverLayer() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.selectedVideo) {
        MediaThumb({
          imageUrl: this.selectedVideo.thumbnailUrl || '',
          placeholderColor: this.selectedVideo.thumbnailColor || '#000000',
          thumbId: 'audio_only_thumb_' + this.selectedVideo.id,
          fillParent: true,
          borderRadiusVp: 0
        })
          .brightness(0.4)
      } else {
        Rect()
          .width('100%')
          .height('100%')
          .fill(Color.Black)
      }
      SymbolGlyph($r('sys.symbol.earphone'))
        .fontSize(48)
        .fontColor([Color.White])
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
    .zIndex(CommonConstants.Z_INDEX_BASE + 0.5)
  }

  @Builder
  SponsorSkipNoticeLayer() {
    if (this.skipNotice) {
      Column() {
        if (this.skipNotice.mode === 'undo') {
          Row({ space: 10 }) {
            Text(getContext().resourceManager.getStringSync(
              $r('app.string.yt_exp_sb_skipped').id,
              this.skipCategoryLabel(this.skipNotice!.category)))
              .fontSize(13)
              .fontColor(Color.White)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            Text($r('app.string.yt_exp_sb_undo'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.themePrimary)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          }
          .padding({ left: 14, right: 8, top: 6, bottom: 6 })
          .backgroundColor('#E6000000')
          .borderRadius(18)
          // 整条提示都可点撤销；Block 命中会挡住下层手势层，避免撤销点击被
          // 播放器的单击手势（收起控件）抢走。
          .hitTestBehavior(HitTestMode.Block)
          .onClick(() => this.undoSponsorSkip())
        } else {
          Row({ space: 4 }) {
            Text(this.sponsorActionNoticeText(this.skipNotice!))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .padding({ left: 14, right: 8, top: 8, bottom: 8 })
              .hitTestBehavior(HitTestMode.Block)
              .onClick(() => {
                if (this.skipNotice?.mode === 'poi') {
                  this.jumpToPoiHighlight();
                } else {
                  this.skipManualSponsorSegment();
                }
              })

            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(13)
                .fontColor(['#CCFFFFFF'])
            }
            .width(30)
            .height(30)
            .margin({ right: 4 })
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => this.dismissSponsorNotice())
          }
          .backgroundColor('#E6000000')
          .borderRadius(18)
          .alignItems(VerticalAlign.Center)
          .hitTestBehavior(HitTestMode.Default)
          .onClick(() => {})
        }
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(HorizontalAlign.Center)
      .padding({ bottom: this.overlayPillBottomVp() })
      .hitTestBehavior(HitTestMode.Transparent)
      .zIndex(CommonConstants.Z_INDEX_MAX + 1)
    }
  }

  @Builder
  JumpAheadLayer() {
    if (this.experimentalConfig.heatmapPluginEnabled && this.experimentalConfig.heatmapJumpAhead
      && this.jumpAheadTargetSec !== null && !this.skipNotice && !this.curSource.isLive && !this.hasError) {
      Column() {
        Row({ space: 4 }) {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.forward_end_fill'))
              .fontSize(14)
              .fontColor([this.themePrimary])
            Text($r('app.string.yt_player_jump_ahead'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .maxLines(1)
            Text(secondToTime(Math.floor(this.jumpAheadTargetSec!)))
              .fontSize(12)
              .fontColor('#CCFFFFFF')
              .maxLines(1)
          }
          .padding({ left: 14, right: 8, top: 8, bottom: 8 })
          .hitTestBehavior(HitTestMode.Block)
          .onClick(() => this.jumpAheadToPeak())

          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(13)
              .fontColor(['#CCFFFFFF'])
          }
          .width(30)
          .height(30)
          .margin({ right: 4 })
          .hitTestBehavior(HitTestMode.Block)
          .onClick(() => this.clearJumpAheadPill())
        }
        .backgroundColor('#E6000000')
        .borderRadius(18)
        .border({ width: 0.5, color: '#33FFFFFF' })
        .alignItems(VerticalAlign.Center)
        .hitTestBehavior(HitTestMode.Default)
        .onClick(() => {})
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.End)
      .alignItems(HorizontalAlign.Center)
      .padding({ bottom: this.overlayPillBottomVp() })
      .hitTestBehavior(HitTestMode.Transparent)
      .zIndex(CommonConstants.Z_INDEX_MAX + 0.8)
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 1. 渲染层（XComponent SURFACE 直渲）
      // XComponent 在 build() 内联，.onLoad() 触发时节点已上树、surface 几何有效，
      // MPV setVideoSurfaceId 即可拿到宽高。进入 PiP 时系统把同一 surface 投到悬浮窗，
      // surfaceId 不变，引擎无需重绑。
      XComponent({
        id: 'PlayerXComponent',
        type: XComponentType.SURFACE,
        controller: this.x_componentController
      })
        .onLoad(() => {
          const surfaceId = this.x_componentController.getXComponentSurfaceId();
          Logger.info(TAG, `XComponent onLoad, surfaceId=${surfaceId}`);
          this.controller.setSurfaceID(surfaceId);
          if (this.onSurfaceReady) {
            this.onSurfaceReady(this.x_componentController);
          }
        })
        .onDestroy(() => {
          Logger.info(TAG, 'XComponent onDestroy');
        })
        // 0.5.1 / 9150bd0: layout by video aspect, NOT 100%×100%.
        // Full-bleed surface makes width/height thrash on rotate/fullscreen and
        // rebuilds NativeWindow (black frames + janky PiP geometry).
        .aspectRatio(this.curSource.width && this.curSource.height
          ? this.curSource.width / this.curSource.height : 16 / 9)
        // 画面比例/双指缩放/平移：纯 UI 变换（scale+translate），surface 不重建。
        // fill/stretch 溢出由 PlayerContainer clip(true) 裁切。
        .scale({ x: this.videoScaleXY().sx, y: this.videoScaleXY().sy, centerX: '50%', centerY: '50%' })
        .translate({ x: this.videoPanXVp, y: this.videoPanYVp })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const pxWidth = Math.round(this.getUIContext().vp2px(Number(newArea.width)));
          const pxHeight = Math.round(this.getUIContext().vp2px(Number(newArea.height)));
          if (pxWidth > 0 && pxHeight > 0) {
            Logger.debug(TAG, `XComponent onAreaChange: ${pxWidth}x${pxHeight} px`);
            this.controller.resizeSurface(pxWidth, pxHeight);
          }
        })
        .zIndex(CommonConstants.Z_INDEX_BASE)

      // One stable startup cover spans extraction, MPV probing, startup seek
      // and automatic recovery. Stream URLs alone are not proof of a frame.
      if (!this.playbackStarted && !this.hasError) {
        Stack({ alignContent: Alignment.Center }) {
          MediaThumb({
            imageUrl: this.curSource.thumbnailUrl || this.selectedVideo?.thumbnailUrl || '',
            placeholderColor: this.selectedVideo?.thumbnailColor || '#000000',
            fillParent: true,
            useAspectRatio: false,
            borderRadiusVp: 0
          })
            .brightness(0.4)

          Column() {
            LoadingProgress()
              .width(48)
              .height(48)
              .color(Color.White)

            SabrBackoffNotice({
              videoId: this.curSource.videoId || this.selectedVideo?.videoId || '',
              onOpenPlaybackAuthSettings: this.onOpenOptionsTarget ? () => {
                this.onOpenOptionsTarget!('data_account', 'playback_auth');
              } : undefined
            })
          }
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Black)
        .zIndex(CommonConstants.Z_INDEX_BASE + 1)
      }

      // 仅音频封面：叠在 surface 上、播控下；None 穿透保证进度条/双击可点
      if (this.isAudioOnlyMode) {
        this.AudioOnlyCoverLayer()
      }

      // 加载中/缓冲提示层（含清晰度/音轨切换：isSourceSwitching 一点击就亮）
      if (this.playbackStarted && (this.vm.isBuffering || this.vm.isSourceSwitching)) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(Color.White)

          SabrBackoffNotice({
            videoId: this.curSource.videoId || this.selectedVideo?.videoId || '',
            onOpenPlaybackAuthSettings: this.onOpenOptionsTarget ? () => {
              this.onOpenOptionsTarget!('data_account', 'playback_auth');
            } : undefined
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.Transparent)
        .zIndex(CommonConstants.Z_INDEX_BASE + 1)
      }

      // SponsorBlock 跳过提示（toast 模式，可撤销）
      this.SponsorSkipNoticeLayer()

      // Most Replayed 热力图 Jump Ahead 胶囊（仅在无 SponsorBlock 提示时显示，绝不重叠）
      this.JumpAheadLayer()

      // 拖动进度条 / 横滑 Seek 预览气泡（故事板雪碧图 + 目标时间 + 实时章节名）
      if ((this.isSliderDragging || this.isGestureSeek) && !this.curSource.isLive && this.durationTime > 0) {
        SeekPreviewBubble({
          storyboard: this.storyboard,
          chapters: this.chapters,
          previewSec: this.isSliderDragging ? this.sliderDragValue : this.gestureSeekTime,
          durationSec: this.durationTime,
          containerWidthVp: this.containerVpWidth,
          trackLeftVp: this.sliderTrackLeftVp,
          trackWidthVp: this.sliderTrackWidthVp,
          isGestureMode: !this.isSliderDragging && this.isGestureSeek
        })
          .position({ bottom: this.previewBubbleBottomVp() })
          .zIndex(CommonConstants.Z_INDEX_MAX + 0.5)
      }

      // 错误提示层（任一播放器出错都会显示）
      if (this.curSource.error || this.hasError) {
        Column({ space: 16 }) {
          SymbolGlyph($r('sys.symbol.exclamationmark_triangle_fill'))
            .fontSize(56)
            .fontColor([Color.White])
            .opacity(0.9)

          Text($r('app.string.yt_error_play_failed_title'))
            .fontColor(Color.White)
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .textAlign(TextAlign.Center)

          Text(this.getErrorDisplay(this.curSource.error || this.vm.userVisibleErrorMsg))
            .fontColor('#CCFFFFFF')
            .fontSize(13)
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 32, right: 32 })

          Row({ space: 12 }) {
            Button($r('app.string.yt_action_retry'))
              .height(36)
              .padding({ left: 20, right: 20 })
              .backgroundColor(this.themePrimary)
              .borderRadius(18)
              .onClick(() => {
                this.registerControlActivity();
                this.hasError = false;
                this.isWaitingForDualBuffer = false;
                if (this.onRetry) {
                  // 通知父组件重新获取流（YouTube URL 有过期时间，必须重新请求）
                  this.onRetry();
                } else {
                  // Fallback: 直接复用旧流重试（仅适用于 URL 不过期的场景）
                  this.curSource.error = undefined;
                  this.vm.errorMsg = '';
                  this.controller.updateVideoSource(this.curSource);
                }
              })

            if (this.onOpenOptionsTarget) {
              Button($r('app.string.yt_error_action_endpoint_settings'))
                .height(36)
                .padding({ left: 16, right: 16 })
                .backgroundColor('#4DFFFFFF')
                .fontColor(Color.White)
                .borderRadius(18)
                .onClick(() => {
                  this.registerControlActivity();
                  this.onOpenOptionsTarget!('playback', 'endpoint_section');
                })

              Button($r('app.string.yt_error_action_account_settings'))
                .height(36)
                .padding({ left: 16, right: 16 })
                .backgroundColor('#4DFFFFFF')
                .fontColor(Color.White)
                .borderRadius(18)
                .onClick(() => {
                  this.registerControlActivity();
                  this.onOpenOptionsTarget!('data_account', 'playback_auth');
                })
            }
          }
          .margin({ top: 8 })
          .justifyContent(FlexAlign.Center)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#B3000000')
        .justifyContent(FlexAlign.Center)
        .zIndex(CommonConstants.Z_INDEX_BASE + 2)
      }

      // 字幕拖动取景框：拖动时显示视频显示区域的虚线边界，提示可放置范围
      if (this.subtitleDragging) {
        Column()
          .width('92%')
          .height(Math.max(0, this.displayLayoutVp().videoHVp - 16))
          .position({ x: this.containerVpWidth * 0.04, y: this.displayLayoutVp().letterboxVp + 8 })
          .border({ width: 1, color: '#80FFFFFF', style: BorderStyle.Dashed, radius: 8 })
          .zIndex(CommonConstants.Z_INDEX_BASE + 2.4)
          .hitTestBehavior(HitTestMode.None)
      }

      // 字幕显示层（ArkUI 覆盖层字幕：json3/VTT 由 mediaservice 解析成 vm.subtitleText / vm.secondarySubtitleText；
      // 按行紧贴圆角胶囊渲染 + 多方向真描边 + 粗体/透明度 + 双语副字幕；
      // 拖动仅在控制层显示时允许，全向自由移动（比例化存储），拖动期间控制层保活，mpv 不再烧录字幕进画面）
      if ((this.vm.currentSubtitleUrl.length > 0 && this.vm.subtitleText.length > 0)
        || (this.vm.secondarySubtitleUrl.length > 0 && this.vm.secondarySubtitleText.length > 0)) {
        Column() {
          Column({ space: 4 }) {
            if (this.vm.currentSubtitleUrl.length > 0 && this.vm.subtitleText.length > 0) {
              Column({ space: 3 }) {
                ForEach(this.getPrimarySubtitleLines(), (line: string, lineIdx: number) => {
                  Text(line)
                    .fontColor(this.getPrimarySubtitleColor())
                    .fontSize(this.getPrimarySubtitleFontSize())
                    .lineHeight(this.getSubtitleLineHeight(this.getPrimarySubtitleFontSize()))
                    .fontWeight(this.playbackConfig.subtitleBold ? FontWeight.Bold : FontWeight.Medium)
                    .textAlign(TextAlign.Center)
                    .constraintSize({ maxWidth: '90%' })
                    .textShadow(this.getSubtitleTextShadow())
                    .padding(this.getSubtitlePillPadding(this.getPrimarySubtitleFontSize()))
                    .backgroundColor(this.getSubtitlePillBackground())
                    .borderRadius(this.getSubtitlePillRadius(this.getPrimarySubtitleFontSize()))
                }, (line: string, lineIdx: number) => `p_${lineIdx}_${line}`)
              }
              .alignItems(HorizontalAlign.Center)
            }

            if (this.vm.secondarySubtitleUrl.length > 0 && this.vm.secondarySubtitleText.length > 0) {
              Column({ space: 3 }) {
                ForEach(this.getSecondarySubtitleLines(), (secLine: string, secIdx: number) => {
                  Text(secLine)
                    .fontColor(this.getSecondarySubtitleColor())
                    .fontSize(this.getSecondarySubtitleFontSize())
                    .lineHeight(this.getSubtitleLineHeight(this.getSecondarySubtitleFontSize()))
                    .fontWeight(this.playbackConfig.subtitleBold ? FontWeight.Bold : FontWeight.Medium)
                    .textAlign(TextAlign.Center)
                    .constraintSize({ maxWidth: '90%' })
                    .textShadow(this.getSubtitleTextShadow())
                    .padding(this.getSubtitlePillPadding(this.getSecondarySubtitleFontSize()))
                    .backgroundColor(this.getSubtitlePillBackground())
                    .borderRadius(this.getSubtitlePillRadius(this.getSecondarySubtitleFontSize()))
                }, (secLine: string, secIdx: number) => `s_${secIdx}_${secLine}`)
              }
              .alignItems(HorizontalAlign.Center)
            }
          }
          .alignItems(HorizontalAlign.Center)
          .padding(this.subtitleDragging ? 6 : 0)
          .backgroundColor(this.subtitleDragging ? '#66000000' : Color.Transparent)
          .borderRadius(this.subtitleDragging ? 12 : 0)
          .border({
            width: this.subtitleDragging ? 1.5 : 0,
            color: this.subtitleDragging ? this.themePrimary : Color.Transparent,
            radius: 12
          })
          .scale({ x: this.subtitleDragging ? 1.03 : 1, y: this.subtitleDragging ? 1.03 : 1 })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .position({ bottom: this.subtitleBottomVp() })
        .offset({ x: this.subtitleDragOffsetXRatio * this.containerVpWidth, y: 0 })
        .zIndex(CommonConstants.Z_INDEX_BASE + 2.5)
        // Transparent 命中：拖动用自身 PanGesture 处理，点按/双击穿透到下方的手势层
        // （Block 会让整条横带吞掉点击，和「单击点亮 UI」的总闸门冲突）。
        // 手势层已下沉到本层之下（BASE+2.2 < BASE+2.5），所以本层的拖动
        // 不会再和画面手势抢同一次触摸——旧的「根容器 parallelGesture 同时收到
        // 拖动、由 subtitleDragging 早退」的补丁已不再需要。
        // 控制层隐藏时整个播放器手势体系是锁定的（需先点按点亮 UI），这里同步锁定。
        .hitTestBehavior(HitTestMode.Transparent)
        .gesture(
          PanGesture({ direction: PanDirection.All, fingers: 1, distance: 4 })
            .onActionStart(() => {
              if (!this.showControls) return;
              this.subtitleDragging = true;
              this.subtitleDragStartLiftRatio = this.subtitleDragLiftRatio;
              this.subtitleDragStartOffsetXRatio = this.subtitleDragOffsetXRatio;
              // 拖动期间控制层保活：清掉自动隐藏计时，结束后重新排程
              this.clearHideTimer();
            })
            .onActionUpdate((e: GestureEvent) => {
              if (!this.subtitleDragging) return;
              const videoH = Math.max(1, this.displayLayoutVp().videoHVp);
              const containerW = Math.max(1, this.containerVpWidth);
              // GestureEvent 偏移单位就是 vp（与根手势 seek 一致），不要再 px2vp
              const lift = this.subtitleDragStartLiftRatio - e.offsetY / videoH;
              const offsetX = this.subtitleDragStartOffsetXRatio + e.offsetX / containerW;
              this.subtitleDragLiftRatio = Math.min(Math.max(lift, -0.5), SUBTITLE_DRAG_MAX_RATIO);
              this.subtitleDragOffsetXRatio = Math.min(Math.max(offsetX, -SUBTITLE_DRAG_X_MAX_RATIO), SUBTITLE_DRAG_X_MAX_RATIO);
            })
            .onActionEnd(() => {
              if (!this.subtitleDragging) return;
              this.subtitleDragging = false;
              this.scheduleHideControls();
            })
            .onActionCancel(() => {
              if (!this.subtitleDragging) return;
              this.subtitleDragging = false;
              this.scheduleHideControls();
            })
        )
      }

      // [DISABLED] 系统 AI 字幕面板（P1，Speech Kit AICaptionComponent）——实测面板
      // 强制占据大片画面区域、体验不佳，产品阶段禁用挂载；设置项同步隐藏
      // （OptionsPlaybackPage），代码保留。重新启用：恢复下方 if 块与设置行即可。
      // if (this.playbackConfig.systemAiCaption && this.aiCaptionSupported) {
      //   AICaptionComponent({
      //     isShown: this.aiCaptionShown,
      //     controller: this.aiCaptionController,
      //     options: this.aiCaptionOptions
      //   })
      //     .width('92%')
      //     .height(120)
      //     .position({ x: '4%', bottom: this.subtitleBottomVp() + 72 })
      //     .zIndex(CommonConstants.Z_INDEX_BASE + 2.6)
      // }

      // 2. 手势提示层
      RelativeContainer() {
        if (this.isGestureSeek && (this.curSource.isLive || this.durationTime <= 0)) {
          Text(`${secondToTime(Math.floor(this.gestureSeekTime))} / ${secondToTime(Math.floor(this.durationTime))}`)
            .fontColor(Color.White).fontSize(26).fontWeight(FontWeight.Medium)
            .textShadow({ radius: 8, color: Color.Black })
            .alignRules({ middle: { anchor: '__container__', align: HorizontalAlign.Center }, center: { anchor: '__container__', align: VerticalAlign.Center } })
        }
        if (this.showBackwardHint) {
          Column() {
            // 步长可配（YouTube 5–60s），提示必须显示真实步长
            Text(`‹ ${this.playbackConfig.doubleTapSeekSeconds}s`)
              .fontColor(Color.White).fontSize(26).fontWeight(FontWeight.Medium)
              .textShadow({ radius: 8, color: Color.Black })
          }
          .width('50%').height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .alignRules({ top: { anchor: '__container__', align: VerticalAlign.Top }, start: { anchor: '__container__', align: HorizontalAlign.Start } })
        }
        if (this.showForwardHint) {
          Column() {
            Text(`${this.playbackConfig.doubleTapSeekSeconds}s ›`)
              .fontColor(Color.White).fontSize(26).fontWeight(FontWeight.Medium)
              .textShadow({ radius: 8, color: Color.Black })
          }
          .width('50%').height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .alignRules({ top: { anchor: '__container__', align: VerticalAlign.Top }, end: { anchor: '__container__', align: HorizontalAlign.End } })
        }
        if (this.showSpeedBoostHint) {
          Text(`${this.speedBoostTarget}x`)
            .fontColor(Color.White).fontSize(22).fontWeight(FontWeight.Medium)
            .padding({ left: 16, right: 16, top: 6, bottom: 6 })
            .backgroundColor('#80000000')
            .borderRadius(16)
            .margin({ top: 24 })
            .alignRules({ middle: { anchor: '__container__', align: HorizontalAlign.Center },
              top: { anchor: '__container__', align: VerticalAlign.Top } })
        }
        if (this.showBrightnessHint) {
          Row({ space: 10 }) {
            SymbolGlyph(this.gestureBrightnessIcon)
              .fontSize(20)
              .fontColor([Color.White])
            Progress({
              value: Math.round(Math.max(0, Math.min(1, this.gestureBrightnessValue)) * 100),
              total: 100,
              type: ProgressType.Linear
            })
              .width(116)
              .color(Color.White)
              .backgroundColor('#4DFFFFFF')
              .style({ strokeWidth: 5, enableSmoothEffect: false })
            Text(`${Math.round(Math.max(0, Math.min(1, this.gestureBrightnessValue)) * 100)}%`)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .fontFeature('"tnum" 1')
              .width(36)
              .textAlign(TextAlign.End)
          }
          .height(44)
          .padding({ left: 16, right: 16 })
          .borderRadius(22)
          .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
          .backgroundColor('#4D000000')
          .border({ width: 1, color: '#33FFFFFF' })
          .alignItems(VerticalAlign.Center)
          .hitTestBehavior(HitTestMode.None)
          .alignRules({
            middle: { anchor: '__container__', align: HorizontalAlign.Center },
            center: { anchor: '__container__', align: VerticalAlign.Center }
          })
        }
        if (this.showVolumeHint) {
          Row({ space: 10 }) {
            SymbolGlyph(this.gestureVolumeIcon)
              .fontSize(20)
              .fontColor([Color.White])
            Progress({
              value: Math.round(Math.max(0, Math.min(1, this.gestureVolumeValue)) * 100),
              total: 100,
              type: ProgressType.Linear
            })
              .width(116)
              .color(Color.White)
              .backgroundColor('#4DFFFFFF')
              .style({ strokeWidth: 5, enableSmoothEffect: false })
            Text(`${Math.round(Math.max(0, Math.min(1, this.gestureVolumeValue)) * 100)}%`)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(Color.White)
              .fontFeature('"tnum" 1')
              .width(36)
              .textAlign(TextAlign.End)
          }
          .height(44)
          .padding({ left: 16, right: 16 })
          .borderRadius(22)
          .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
          .backgroundColor('#4D000000')
          .border({ width: 1, color: '#33FFFFFF' })
          .alignItems(VerticalAlign.Center)
          .hitTestBehavior(HitTestMode.None)
          .alignRules({
            middle: { anchor: '__container__', align: HorizontalAlign.Center },
            center: { anchor: '__container__', align: VerticalAlign.Center }
          })
        }
      }
      .width('100%').height('100%')
      // HitTestMode.None only exempts THIS node; its children still respond
      // (SDK: "Self not respond ... but children respond"). The left/right hint
      // Columns cover 50% x 100% each, so while a +/-step hint was visible they
      // swallowed the next double-tap. Keep the whole visual hint layer BELOW
      // the gesture layer (2.2) but above the buffering overlay (2.0): the
      // transparent gesture layer is the top hit target and draws nothing, so
      // the hint stays visible while taps always reach the gesture layer.
      .zIndex(CommonConstants.Z_INDEX_BASE + 2.1)

      // 2.4 独立 4 段非线性缓动羽化阴影（Scrim）：位于手势层之下且全树 HitTestMode.None，
      // 绝不拦截点击/双击/滑动手势，消除旧版单行 Row 硬黑边截断。
      Column() {
        Row()
          .width('100%')
          .height(this.isTvOrLargeScreen() ? 160 : 120)
          .hitTestBehavior(HitTestMode.None)
          .linearGradient({
            direction: GradientDirection.Bottom,
            colors: [
              ['#B8000000', 0.0],
              ['#73000000', 0.35],
              ['#2B000000', 0.7],
              ['#00000000', 1.0]
            ]
          })
        Blank().layoutWeight(1).hitTestBehavior(HitTestMode.None)
        Row()
          .width('100%')
          .height(this.isTvOrLargeScreen() ? 170 : 136)
          .hitTestBehavior(HitTestMode.None)
          .linearGradient({
            direction: GradientDirection.Bottom,
            colors: [
              ['#00000000', 0.0],
              ['#22000000', 0.3],
              ['#66000000', 0.65],
              ['#A6000000', 1.0]
            ]
          })
      }
      .width('100%')
      .height('100%')
      .opacity(this.showControls ? 1 : 0)
      .animation(this.uiConfig.isAnimation
        ? { duration: 220, curve: Curve.FastOutSlowIn }
        : { duration: 0 })
      .hitTestBehavior(HitTestMode.None)

      // 2.6 手势层：透明全屏，承载画面手势（单击/双击/滑动/长按）
      //
      // **必须独立成层、且位于播控层之下。** 之前手势挂在容器上（播控层的
      // 祖先），而播控层整层是 HitTestMode.Transparent —— 控件上的点击会一并
      // 落进画面的手势组：按播放键的瞬间控件被收走、连点按钮触发双击快进
      // （±15s 跳转）。独立成层后，控件点击的命中路径里根本没有这一层，
      // 泄漏从根上消失；画面空白处仍然命中本层，手势照常。
      this.GestureLayer()

      // 2.5 中央播放按钮（暂停时）：毛玻璃 + 点光源质感 + 弹簧入出场动效
      if (this.showCenterPlayButton()) {
        Stack({ alignContent: Alignment.Center }) {
          Stack({ alignContent: Alignment.Center }) {
            // 播放结束用"重播"图标，避免和"继续播放"混淆。
            SymbolGlyph(this.vm.isEnded
              ? $r('sys.symbol.arrow_clockwise')
              : $r('sys.symbol.play_fill'))
              .fontSize(this.isTvOrLargeScreen() ? 40 : 34)
              .fontColor([Color.White])
          }
          .width(this.isTvOrLargeScreen() ? 84 : 72)
          .height(this.isTvOrLargeScreen() ? 84 : 72)
          .borderRadius(this.isTvOrLargeScreen() ? 42 : 36)
          .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
          .backgroundColor('#33000000')
          .border({ width: 1, color: '#40FFFFFF' })
          .visualEffect(this.buildCenterPlayPointLight())
          .focusable(true)
          .focusBox({
            margin: LengthMetrics.vp(3),
            strokeColor: ColorMetrics.resourceColor(this.themePrimary),
            strokeWidth: LengthMetrics.vp(2.5)
          })
          .onClick(() => {
            this.togglePlayback();
          })
        }
        .width('100%')
        .height('100%')
        // Transparent：空白处仍可命中下层（单击显隐控件/手势组），按钮自身优先响应
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(this.uiConfig.isAnimation
          ? TransitionEffect.OPACITY
            .combine(TransitionEffect.scale({ x: 0.85, y: 0.85 }))
            .animation({ curve: curves.springMotion(0.35, 0.8) })
          : TransitionEffect.IDENTITY)
        .zIndex(CommonConstants.Z_INDEX_MAX)
      }

      // 3. 播控层
      Column() {
        this.TopControl()
        // Middle spacer must not be a hit target: when the controls are visible
        // it would sit above the gesture layer and eat the second/third
        // double-tap (the buttons themselves stay interactive).
        Blank().width('100%').layoutWeight(1).hitTestBehavior(HitTestMode.None)
        this.PlayControl()
      }
      .width('100%').height('100%')
      .opacity(this.showControls ? 1 : 0)
      .animation(this.uiConfig.isAnimation
        ? { duration: 220, curve: Curve.FastOutSlowIn }
        : { duration: 0 })
      // 隐藏时用 BLOCK_DESCENDANTS：HitTestMode.None 只禁用 Column 自身，
      // 后代按钮（顶栏/进度条/菜单）不可见但仍可点到；BLOCK_DESCENDANTS 整棵子树禁用
      .hitTestBehavior(this.showControls ? HitTestMode.Transparent : HitTestMode.BLOCK_DESCENDANTS)
      .zIndex(CommonConstants.Z_INDEX_MAX)
    }
    .width(CommonConstants.WIDTH_FULL_PERCENT)
    .height(CommonConstants.HEIGHT_FULL_PERCENT)
    .id('PlayerContainer')
    .backgroundColor(Color.Black)
    .clip(true)
    .focusable(true)
    .onKeyEvent((event: KeyEvent) => {
      this.handlePlayerKeyEvent(event);
    })
    .onSizeChange((_old: SizeOptions, newSize: SizeOptions) => {
      const w = newSize.width as number;
      const h = newSize.height as number;
      if (this.containerVpWidth > 0 && this.containerVpHeight > 0 &&
        (this.containerVpWidth !== w || this.containerVpHeight !== h)) {
        this.resetTransientUi('container-size-change');
        this.resetSubtitleDrag();
        // 与字幕策略一致：容器形态变化后缩放/平移也归零重来
        this.resetVideoZoom();
      }
      this.containerVpWidth = w;
      this.containerVpHeight = h;
      this.clampVideoPan();
      Logger.debug(TAG, `Control layout size=${Math.round(w)}x${Math.round(h)} fullscreen=${this.isFullLandscapeScreen}`);
    })

    // 双指缩放在触摸层处理（PinchGesture 在 Exclusive 组内会被单指 pan 竞争掉）
    .onTouch((event: TouchEvent) => this.onPinchTouch(event))
    .bindSheet($$this.showChaptersSheet, this.ChaptersAndSegmentsSheet(), {
      detents: [SheetSize.MEDIUM, SheetSize.LARGE],
      dragBar: true,
      backgroundColor: $r('app.color.yourtube_bg_page'),
      preferType: SheetType.CENTER,
      showClose: false,
      onAppear: () => this.onControlMenuAppear(),
      onWillDisappear: () => this.onControlMenuDisappear()
    })
  }

  /**
   * 画面手势层：透明全屏，承载单击 / 双击 / 滑动 / 长按。
   *
   * <p>**独立成层、位于播控层之下**是这套交互可靠的关键。播控层整层是
   * `HitTestMode.Transparent`，如果手势挂在容器（播控层的祖先）上，控件上
   * 的每一次点击都会一并落进画面的手势组：
   * <ul>
   *   <li>按一下播放键 → 单击手势把控件收走（正在操作却 UI 消失）；</li>
   *   <li>连点按钮两下 → 双击手势触发快进/快退（±15s 跳转）。</li>
   * </ul>
   * 独立成层之后，控件点击的命中路径里根本没有这一层，泄漏从根上消失；
   * 画面空白处仍然命中本层，手势照常。控件层的点击只由控件自己处理。
   */
  @Builder
  GestureLayer() {
    Column() {
    }
      .width('100%')
      .height('100%')
      // 透明背景：让本层成为画面空白处的命中目标（不透明层会挡住视频画面）。
      .backgroundColor(Color.Transparent)
      // 层级：必须在**字幕拖动层（BASE+2.5）之下**——字幕层用自己的 PanGesture
      // 处理拖动，被手势层压在上面会抢走命中、字幕就拖不动了；又必须在
      // 缓冲提示层（BASE+2.0）之上，否则那个全屏层会挡住画面空白处的命中。
      .zIndex(CommonConstants.Z_INDEX_BASE + 2.2)
      .parallelGesture(
        GestureGroup(GestureMode.Exclusive,
          // 只用 count:1，单击/双击都在这一个回调里按时间窗计数（见
          // onCenterTap）：ArkUI 的 count:2 识别器在一次成功双击后要等
          // 多击窗口结束才会重新计数，连续双击会被吞掉。
          TapGesture({ count: 1, fingers: 1 })
            .onAction((event: GestureEvent) => {
              this.onCenterTap(event);
            }),
          PanGesture({ direction: PanDirection.All, fingers: 1, distance: 8 })
            .onActionStart((_e: GestureEvent) => {
              this.onPlayerPanStart(_e);
            })
            .onActionUpdate((event: GestureEvent) => {
              this.onPlayerPanUpdate(event);
            })
            .onActionEnd((_e: GestureEvent) => {
              this.onPlayerPanEnd(false);
            })
            .onActionCancel((_e: GestureEvent) => {
              this.onPlayerPanEnd(true);
            }),
          LongPressGesture({ fingers: 1, duration: this.playbackConfig.holdSpeedDelayMs, repeat: false })
            .onAction((_e: GestureEvent) => {
              this.onHoldSpeedStart();
            })
            .onActionEnd((_e: GestureEvent) => {
              this.onHoldSpeedEnd('release');
            })
            .onActionCancel((_e: GestureEvent) => {
              this.onHoldSpeedEnd('cancel');
            })
        )
      )
  }

  private setStatsOverlayVisible(visible: boolean): void {
    this.showStatsOverlay = visible;
    if (visible) {
      this.startStatsOverlayPolling();
    } else {
      this.stopStatsOverlayPolling();
      this.overlayStats = null;
    }
    Logger.info(TAG, `Stats for Nerds overlay toggled visible=${visible}`);
  }

  private startStatsOverlayPolling(): void {
    this.stopStatsOverlayPolling();
    if (this.controller) {
      this.controller.acquireStatsObservation();
      this.statsObservationController = this.controller;
    }
    this.pollStatsOverlay();
    this.statsOverlayTimerId = setInterval(() => {
      this.pollStatsOverlay();
    }, 500);
  }

  private stopStatsOverlayPolling(): void {
    if (this.statsOverlayTimerId >= 0) {
      clearInterval(this.statsOverlayTimerId);
      this.statsOverlayTimerId = -1;
    }
    if (this.statsObservationController) {
      this.statsObservationController.releaseStatsObservation();
      this.statsObservationController = null;
    }
  }

  private pollStatsOverlay(): void {
    if (!this.controller) {
      return;
    }
    this.overlayStats = this.controller.getPlaybackStats();
  }

  private statsOverlayTopVp(): number {
    if (this.showControls) {
      return this.getControlTopPad() + CONTROL_SLOT_SIZE + 4;
    }
    return this.isFullLandscapeScreen
      ? Math.max(12, this.playerControlAvoidTop + CONTROL_SAFE_GAP)
      : 8;
  }

  private statsOverlayLeftVp(): number {
    return this.isFullLandscapeScreen
      ? Math.max(12, this.playerControlAvoidLeft + CONTROL_SAFE_GAP)
      : 8;
  }

  private getStatsOverlayLabels(): StreamStatsLabels {
    return resolveStreamStatsLabels(this.getUIContext().getHostContext()?.resourceManager);
  }

  private getOverlayVideoId(): string {
    return (this.curSource.videoId || this.selectedVideo?.videoId || '').trim();
  }

  private hudIdTransportLine(): string {
    const parts: string[] = [];
    const vid: string = this.getOverlayVideoId();
    if (vid.length > 0) {
      parts.push(vid);
    }
    const transport: string = formatTransportSummary(
      this.overlayStats ? this.overlayStats.transportKind : '',
      this.vm.currentStreamEndpoint,
      this.vm.currentVideoItag,
      this.vm.currentAudioItag,
      this.getStatsOverlayLabels()
    );
    if (transport.length > 0) {
      parts.push(transport);
    }
    return parts.length > 0 ? parts.join(' · ') : '--';
  }

  private hudResFpsLine(): string {
    const fpsStr: string = formatFrameRateSummary(
      this.vm.frameRate,
      this.overlayStats ? this.overlayStats.measuredFps : 0
    );
    if (this.vm.videoWidth > 0 && this.vm.videoHeight > 0) {
      return fpsStr.length > 0
        ? `${this.vm.videoWidth}×${this.vm.videoHeight} @ ${fpsStr}`
        : `${this.vm.videoWidth}×${this.vm.videoHeight}`;
    }
    return fpsStr.length > 0 ? fpsStr : '--';
  }

  private hudVideoLine(): string {
    const parts: string[] = [];
    if (this.vm.videoCodec.length > 0) {
      const br: string = formatBitrateBps(this.vm.videoBitRate);
      parts.push(br.length > 0 ? `${this.vm.videoCodec} (${br})` : this.vm.videoCodec);
    }
    const hw: string = formatHwdec(this.vm.hwdec, this.getStatsOverlayLabels().softwareDecode);
    if (hw.length > 0) {
      parts.push(hw);
    }
    const color: string = formatColorInfo(
      this.vm.pixelFormat,
      this.vm.colorSpace,
      this.vm.colorPrimaries,
      this.vm.colorGamma
    );
    if (color.length > 0) {
      parts.push(color);
    }
    return parts.length > 0 ? parts.join(' · ') : '--';
  }

  private hudAudioLine(): string {
    const parts: string[] = [];
    if (this.vm.audioCodec.length > 0) {
      const br: string = formatBitrateBps(this.vm.audioBitRate);
      parts.push(br.length > 0 ? `${this.vm.audioCodec} (${br})` : this.vm.audioCodec);
    }
    if (this.vm.audioSampleRate > 0) {
      parts.push(`${(this.vm.audioSampleRate / 1000).toFixed(1)} kHz`);
    }
    const ch: string = formatAudioChannelsShort(this.vm.audioChannels, this.vm.audioChannelLayout);
    if (ch.length > 0) {
      parts.push(ch);
    }
    return parts.length > 0 ? parts.join(' · ') : '--';
  }

  private hudAvSyncText(): string {
    return formatAvSync(this.overlayStats ? this.overlayStats.avSyncMs : undefined);
  }

  private hudAvSyncColor(): ResourceColor {
    const severity = getAvSyncSeverity(this.overlayStats ? this.overlayStats.avSyncMs : undefined);
    if (severity === 'bad') {
      return '#FF5252';
    }
    if (severity === 'warn') {
      return '#FFA726';
    }
    return '#E6FFFFFF';
  }

  private hudDroppedText(): string {
    if (!this.overlayStats) {
      return '0';
    }
    return formatDroppedFrames(
      this.overlayStats.droppedFrames,
      this.overlayStats.decoderDroppedFrames,
      this.overlayStats.totalFrames
    );
  }

  private hudBufferSpeedLine(): string {
    const buf: string = this.overlayStats
      ? formatBufferSummary(this.overlayStats.demuxerCacheDurationSec, this.overlayStats.bufferedBytes)
      : '0.0 s';
    const spd: string = formatSpeedBps(this.overlayStats ? (this.overlayStats.networkSpeedBps ?? 0) : 0);
    return `${buf} · ${spd}`;
  }

  private hudAudioFxLine(): string {
    return formatAudioFxSummary(
      this.overlayStats ? this.overlayStats.activeAudioFilters : '',
      this.playbackConfig.audioDelayMs,
      this.getStatsOverlayLabels()
    );
  }

  private copyOverlayDiagnostics(): void {
    const liveStats: PlaybackStats = this.controller ? this.controller.getPlaybackStats() : {
      cacheSpeedBps: 0,
      networkSpeedBps: 0,
      demuxerCacheDurationSec: 0,
      droppedFrames: 0,
      decoderDroppedFrames: 0,
      totalFrames: 0,
      avSyncMs: undefined,
      measuredFps: 0,
      bufferedBytes: 0,
      activeAudioFilters: '',
      transportKind: ''
    };
    const report: string = buildDiagnosticReport({
      videoId: this.getOverlayVideoId(),
      vm: this.vm,
      stats: liveStats,
      audioDelayMs: this.playbackConfig.audioDelayMs,
      labels: this.getStatsOverlayLabels()
    });
    copyDiagnosticsToClipboard(this.getUIContext(), report, 'AVPlayer');
  }

  @Builder
  StatsForNerdsOverlay() {
    Column({ space: 2 }) {
      // Header row: title + Copy button + Close button (buttons capture taps; card body passes through)
      Row({ space: 4 }) {
        Text($r('app.string.yt_player_stats_for_nerds'))
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .hitTestBehavior(HitTestMode.None)

        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.doc_plaintext'))
            .fontSize(13)
            .fontColor(['#E6FFFFFF'])
        }
          .width(24)
          .height(24)
          .borderRadius(12)
          .backgroundColor('#33FFFFFF')
          .accessibilityText($r('app.string.yt_action_copy'))
          .onClick(() => {
            this.copyOverlayDiagnostics();
          })

        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(13)
            .fontColor(['#E6FFFFFF'])
        }
          .width(24)
          .height(24)
          .borderRadius(12)
          .backgroundColor('#33FFFFFF')
          .accessibilityText($r('app.string.yt_action_close'))
          .onClick(() => {
            this.setStatsOverlayVisible(false);
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: 2 })
      .hitTestBehavior(HitTestMode.None)

      // Crisp 11fp stats rows (non-blocking body so video gestures keep working)
      Column({ space: 2 }) {
        Text(this.hudIdTransportLine())
          .fontSize(11)
          .lineHeight(14)
          .fontColor('#E6FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.vm.videoWidth > 0 || (this.overlayStats !== null && this.overlayStats.measuredFps > 0.5)) {
          Text(`Res ${this.hudResFpsLine()}`)
            .fontSize(11)
            .lineHeight(14)
            .fontColor('#E6FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Text(`Vid ${this.hudVideoLine()}`)
            .fontSize(11)
            .lineHeight(14)
            .fontColor('#E6FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        if (this.vm.audioCodec.length > 0 || this.vm.audioSampleRate > 0) {
          Text(`Aud ${this.hudAudioLine()}`)
            .fontSize(11)
            .lineHeight(14)
            .fontColor('#E6FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        Text() {
          Span('A/V ')
            .fontColor('#B3FFFFFF')
          Span(this.hudAvSyncText())
            .fontColor(this.hudAvSyncColor())
            .fontWeight(getAvSyncSeverity(this.overlayStats ? this.overlayStats.avSyncMs : undefined) !== 'normal'
              ? FontWeight.Bold : FontWeight.Normal)
          Span(` · Drop ${this.hudDroppedText()}`)
            .fontColor('#E6FFFFFF')
        }
          .fontSize(11)
          .lineHeight(14)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(`Buf ${this.hudBufferSpeedLine()}`)
          .fontSize(11)
          .lineHeight(14)
          .fontColor('#E6FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.hudAudioFxLine().length > 0) {
          Text(`FX ${this.hudAudioFxLine()}`)
            .fontSize(11)
            .lineHeight(14)
            .fontColor('#CCFFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .hitTestBehavior(HitTestMode.BLOCK_DESCENDANTS)
    }
    .alignItems(HorizontalAlign.Start)
    .constraintSize({ maxWidth: 270 })
    .padding(10)
    .borderRadius(10)
    .backgroundColor('#B8000000')
    .position({ x: this.statsOverlayLeftVp(), y: this.statsOverlayTopVp() })
    .hitTestBehavior(HitTestMode.None)
    .zIndex(CommonConstants.Z_INDEX_MAX + 0.2)
  }

  private menuSymbol(icon: Resource): SymbolGlyphModifier {
    return new SymbolGlyphModifier(icon).fontSize('22vp');
  }

  @Builder
  TopToolsCollapsedMenu() {
    // 折叠总菜单：symbolStartIcon 显示与展开态相同的系统图标；倍速用 labelInfo 显示当前 Nx。
    Menu() {
      // 全屏/分屏/挤压铺满态：信息面板不挂载，提供"视频信息"入口打开 sheet
      if (this.isFullLandscapeScreen && this.onShowInfoPanel) {
        MenuItem({
          symbolStartIcon: this.menuSymbol($r('sys.symbol.info_circle')),
          content: $r('app.string.yt_player_info_panel')
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
          .onClick(() => this.onShowInfoPanel?.())
      }
      if (this.hasChaptersOrSegments()) {
        MenuItem({
          symbolStartIcon: this.menuSymbol($r('sys.symbol.list_bullet_square')),
          content: this.chaptersSheetTitle()
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
          .onClick(() => {
            this.showChaptersSheet = true;
          })
      }
      if (!this.curSource.isLive && !this.isLocalMode) {
        MenuItem({
          symbolStartIcon: this.menuSymbol($r('sys.symbol.AI_subtitles')),
          content: $r('app.string.yt_player_subtitles'),
          labelInfo: this.getCurrentSubtitleSummaryLabel(),
          builder: (): void => {
            this.SubtitleMenu()
          }
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
          .labelFont({ size: 13 })
          .labelFontColor(this.vm.currentSubtitleUrl.length > 0
            ? this.themePrimary : $r('sys.color.font_secondary'))
      }
      if (this.hasMultipleAudioTracks()) {
        MenuItem({
          symbolStartIcon: this.menuSymbol($r('sys.symbol.speaker_wave_2')),
          content: $r('app.string.yt_player_audio_track'),
          builder: (): void => {
            this.AudioMenu()
          }
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
      }
      if (this.canToggleChannelWhitelist()) {
        MenuItem({
          symbolStartIcon: this.menuSymbol($r('sys.symbol.key_shield_fill')),
          content: $r('app.string.yt_exp_sb_whitelist_channel'),
          endIcon: this.experimentalConfig.isChannelWhitelisted(this.currentChannelId())
            ? $r('sys.symbol.checkmark') : ''
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
          .backgroundColor(this.experimentalConfig.isChannelWhitelisted(this.currentChannelId())
            ? this.getSelectedMenuBackground() : Color.Transparent)
          .onClick(() => {
            this.toggleCurrentChannelWhitelist();
          })
      }
      if (!this.isLocalMode && this.controller.getMergedVideoList().length > 0
      && (!this.curSource.isLive || this.vm.playerModel.liveQualityReady)) {
        MenuItem({
          symbolStartIcon: this.menuSymbol($r('sys.symbol.resolution_video')),
          content: $r('app.string.yt_player_video_quality'),
          builder: (): void => {
            this.VideoMenu()
          }
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
      }
      if (!this.curSource.isLive) {
        MenuItem({
          symbolStartIcon: this.menuSymbol($r('sys.symbol.play_circle')),
          content: $r('app.string.yt_player_playback_speed'),
          labelInfo: `${this.vm.playbackSpeed}x`,
          builder: (): void => {
            this.SpeedMenu()
          }
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
          .labelFont({ size: 14, weight: FontWeight.Medium })
          .labelFontColor($r('sys.color.font_primary'))
      }
      MenuItem({
        symbolStartIcon: this.menuSymbol($r('sys.symbol.resolution_video')),
        content: $r('app.string.yt_player_aspect_mode'),
        labelInfo: this.aspectModeLabel(),
        builder: (): void => {
          this.AspectMenu()
        }
      })
        .contentFontColor($r('sys.color.font_primary'))
        .contentFont({ size: 14 })
        .labelFont({ size: 14, weight: FontWeight.Medium })
        .labelFontColor($r('sys.color.font_primary'))
      // 显式停止：后台播放时通知栏只有「暂停」，用户真正想要的是彻底停掉。
      MenuItem({
        symbolStartIcon: this.menuSymbol($r('sys.symbol.xmark_circle')),
        content: $r('app.string.yt_player_stop_playback')
      })
        .contentFontColor($r('sys.color.font_primary'))
        .contentFont({ size: 14 })
        .onClick(() => {
          // 停止播放并离开播放页：留在播放页只会看到一个已释放的空壳。
          PlayerSession.getInstance().stopPlayback();
          this.actionHub.closePage();
        })
    }
    .onAppear(() => this.onControlMenuAppear())
    .onDisAppear(() => this.onControlMenuDisappear())
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .borderRadius(12)
    .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
    // 嵌套展开：二级嵌在一级里，不侧滑另开层，避免立刻消失
    .subMenuExpandingMode(SubMenuExpandingMode.EMBEDDED_EXPAND)
    .width(260)
  }

  @Builder
  MoreMenu() {
    Menu() {
      if (this.canToggleChannelWhitelist()) {
        MenuItem({
          symbolStartIcon: this.menuSymbol($r('sys.symbol.key_shield_fill')),
          content: $r('app.string.yt_exp_sb_whitelist_channel'),
          endIcon: this.experimentalConfig.isChannelWhitelisted(this.currentChannelId())
            ? $r('sys.symbol.checkmark') : ''
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
          .backgroundColor(this.experimentalConfig.isChannelWhitelisted(this.currentChannelId())
            ? this.getSelectedMenuBackground() : Color.Transparent)
          .onClick(() => {
            this.toggleCurrentChannelWhitelist();
          })
      }
      MenuItem({
        symbolStartIcon: this.menuSymbol($r('sys.symbol.xmark_circle')),
        content: $r('app.string.yt_player_stop_playback')
      })
        .contentFontColor($r('sys.color.font_primary'))
        .contentFont({ size: 14 })
        .onClick(() => {
          PlayerSession.getInstance().stopPlayback();
          this.actionHub.closePage();
        })
    }
    .onAppear(() => this.onControlMenuAppear())
    .onDisAppear(() => this.onControlMenuDisappear())
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .borderRadius(12)
    .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
    .width(240)
  }

  @Builder
  TopToolsExpandedRow() {
    Row({ space: 2 }) {
      // 全屏/分屏/挤压铺满态：信息面板 sheet 入口
      if (this.isFullLandscapeScreen && this.onShowInfoPanel) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.info_circle'))
            .fontSize(this.controlBarIconSize())
            .fontColor([Color.White])
        }
          .width(this.controlBarSlotSize())
          .height(this.controlBarSlotSize())
          .accessibilityText($r('app.string.yt_player_info_panel'))
          .onClick(() => this.onShowInfoPanel?.())
      }

      if (this.hasChaptersOrSegments()) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.list_bullet_square'))
            .fontSize(this.controlBarIconSize())
            .fontColor([Color.White])
        }
          .width(this.controlBarSlotSize())
          .height(this.controlBarSlotSize())
          .accessibilityText(this.chaptersSheetTitle())
          .onClick(() => {
            this.registerControlActivity();
            this.showChaptersSheet = true;
          })
      }

      if (!this.curSource.isLive && !this.isLocalMode) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.AI_subtitles'))
            .fontSize(this.controlBarIconSize())
            .fontColor([this.vm.currentSubtitleUrl.length > 0 ? this.themePrimary : Color.White])
        }
          .width(this.controlBarSlotSize())
          .height(this.controlBarSlotSize())
          .accessibilityText($r('app.string.yt_player_subtitles'))
          .onClick(() => {
            this.registerControlActivity();
            this.showSubtitleMenu = true;
          })
          .gesture(
            LongPressGesture({ fingers: 1, duration: 400, repeat: false })
              .onAction(() => {
                this.onQuickToggleSubtitle();
              })
          )
          .bindMenu(this.showSubtitleMenu, this.SubtitleMenu(), {
            onDisappear: () => {
              this.showSubtitleMenu = false;
            }
          })
      }

      if (this.hasMultipleAudioTracks()) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.speaker_wave_2'))
            .fontSize(this.controlBarIconSize())
            .fontColor([Color.White])
        }
          .width(this.controlBarSlotSize())
          .height(this.controlBarSlotSize())
          .accessibilityText($r('app.string.yt_player_audio_track'))
          .bindMenu(this.AudioMenu())
      }

      if (!this.isLocalMode && this.controller.getMergedVideoList().length > 0
      && (!this.curSource.isLive || this.vm.playerModel.liveQualityReady)) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.resolution_video'))
            .fontSize(this.controlBarIconSize())
            .fontColor([Color.White])
        }
          .width(this.controlBarSlotSize())
          .height(this.controlBarSlotSize())
          .bindMenu(this.VideoMenu())
      }

      if (!this.curSource.isLive) {
        Text(this.vm.playbackSpeed + 'x')
          .fontSize(this.controlBarTextSize())
          .fontColor(Color.White)
          .fontWeight(FontWeight.Medium)
          .fontFeature('"tnum" 1')
          .height(this.controlBarSlotSize())
          .padding({ left: 10, right: 10 })
          .maxLines(1)
          .textAlign(TextAlign.Center)
          .bindMenu(this.SpeedMenu())
      }

      // 画面比例：下拉菜单选择（与其他选项一致的交互），菜单打开期间 UI 保活
      Text(this.aspectModeLabel())
        .fontSize(this.controlBarTextSize())
        .fontColor(Color.White)
        .fontWeight(FontWeight.Medium)
        .height(this.controlBarSlotSize())
        .padding({ left: 10, right: 10 })
        .textAlign(TextAlign.Center)
        .accessibilityText($r('app.string.yt_player_aspect_mode'))
        .bindMenu(this.AspectMenu())

      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.line_3_horizontal'))
          .fontSize(this.controlBarIconSize())
          .fontColor([Color.White])
      }
        .width(this.controlBarSlotSize())
        .height(this.controlBarSlotSize())
        .accessibilityText($r('app.string.yt_player_more_tools'))
        .bindMenu(this.MoreMenu())
    }
    .height(this.controlBarSlotSize())
    .padding({ left: 4, right: 4 })
    .borderRadius(this.controlBarSlotSize() / 2)
    .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
    .backgroundColor('#47000000')
    .border({ width: 1, color: '#33FFFFFF' })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  TopControl() {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(this.controlBarIconSize())
          .fontWeight(FontWeight.Medium)
          .fontColor([Color.White])
      }
        .width(this.controlBarSlotSize())
        .height(this.controlBarSlotSize())
        .borderRadius(this.controlBarSlotSize() / 2)
        .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
        .backgroundColor('#47000000')
        .border({ width: 1, color: '#33FFFFFF' })
        .focusable(true)
        .focusBox({
          margin: LengthMetrics.vp(3),
          strokeColor: ColorMetrics.resourceColor(this.themePrimary),
          strokeWidth: LengthMetrics.vp(2.5)
        })
        .onClick(() => {
          // Explicit close button: force teardown so the page pop never leaves
          // an invisible dangling playback session behind.
          PlayerSession.getInstance().release(true);
          this.actionHub.closePage();
        })

      if (this.shouldShowTopTitleBar() && this.getTopBarTitle().length > 0) {
        Column({ space: 2 }) {
          Text(this.getTopBarTitle())
            .fontSize(this.isTvOrLargeScreen() ? 20 : 16)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .textOverflow({ overflow: TextOverflow.MARQUEE })
            .marqueeOptions({
              start: this.showControls && this.uiConfig.isAnimation,
              fromStart: true,
              step: 4,
              loop: -1,
              delay: 1200,
              fadeout: true,
              spacing: LengthMetrics.vp(48)
            })
            .textShadow({ radius: 6, color: '#99000000', offsetY: 1 })
            .width('100%')

          if (this.getTopBarAuthor().length > 0 || this.getTopBarSpecBadge().length > 0) {
            Row({ space: 8 }) {
              if (this.getTopBarAuthor().length > 0) {
                Text(this.getTopBarAuthor())
                  .fontSize(this.isTvOrLargeScreen() ? 13 : 12)
                  .fontColor('#E6FFFFFF')
                  .textShadow({ radius: 4, color: '#80000000', offsetY: 1 })
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .flexShrink(1)
              }
              if (this.getTopBarSpecBadge().length > 0) {
                Text(this.getTopBarSpecBadge())
                  .fontSize(10)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Color.White)
                  .padding({ left: 6, right: 6, top: 1, bottom: 1 })
                  .borderRadius(4)
                  .backgroundColor(this.curSource.isLive ? this.themePrimary : '#59000000')
                  .border({ width: 0.5, color: '#33FFFFFF' })
              }
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10, right: 12 })
      } else {
        Blank()
      }

      if (this.shouldCollapseTopTools()) {
        Row({ space: 2 }) {
          if (!this.curSource.isLive && !this.isLocalMode && this.vm.subtitleTracks.length > 0) {
            Stack({ alignContent: Alignment.Center }) {
              SymbolGlyph($r('sys.symbol.AI_subtitles'))
                .fontSize(this.controlBarIconSize())
                .fontColor([this.vm.currentSubtitleUrl.length > 0 ? this.themePrimary : Color.White])
            }
              .width(this.controlBarSlotSize())
              .height(this.controlBarSlotSize())
              .accessibilityText($r('app.string.yt_player_subtitles'))
              .onClick(() => {
                this.onQuickToggleSubtitle();
              })
              .gesture(
                LongPressGesture({ fingers: 1, duration: 400, repeat: false })
                  .onAction(() => {
                    this.registerControlActivity();
                    this.showCollapsedSubtitleMenu = true;
                  })
              )
              .bindMenu(this.showCollapsedSubtitleMenu, this.SubtitleMenu(), {
                onDisappear: () => {
                  this.showCollapsedSubtitleMenu = false;
                }
              })
          }

          Stack({ alignContent: Alignment.Center }) {
            SymbolGlyph($r('sys.symbol.line_3_horizontal'))
              .fontSize(this.controlBarIconSize())
              .fontColor([Color.White])
          }
            .width(this.controlBarSlotSize())
            .height(this.controlBarSlotSize())
            .accessibilityText($r('app.string.yt_player_more_tools'))
            .bindMenu(this.TopToolsCollapsedMenu())
        }
        .height(this.controlBarSlotSize())
        .padding({ left: 4, right: 4 })
        .borderRadius(this.controlBarSlotSize() / 2)
        .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
        .backgroundColor('#47000000')
        .border({ width: 1, color: '#33FFFFFF' })
        .alignItems(VerticalAlign.Center)
      } else {
        this.TopToolsExpandedRow()
      }
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // 非沉浸模式由 PlayerPage 负责状态栏安全区，这里保留舒适边距。
    // 沉浸全屏只使用当前挖孔避让值，不复用缓存的竖屏状态栏高度。
    .padding({
      left: this.getControlLeftPad(),
      right: this.getControlRightPad(),
      top: this.getControlTopPad(),
      bottom: CONTROL_VERTICAL_INSET
    })
    .translate({ y: this.showControls ? 0 : -12 })
    .animation(this.uiConfig.isAnimation
      ? { duration: 220, curve: Curve.FastOutSlowIn }
      : { duration: 0 })
  }

  @Builder
  PlayControl() {
    Row() {
      Row({ space: this.getControlItemGap() }) {
        // 播放/暂停按鈕：正在播放或缓冲中时显示暂停图标，其他状态显示播放图标
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph(this.vm.isPlaying ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
            .fontSize(this.controlBarIconSize())
            .fontColor([Color.White])
        }
          .width(this.controlBarSlotSize())
          .height(this.controlBarSlotSize())
          .borderRadius(this.controlBarSlotSize() / 2)
          .focusable(true)
          .focusBox({
            margin: LengthMetrics.vp(3),
            strokeColor: ColorMetrics.resourceColor(this.themePrimary),
            strokeWidth: LengthMetrics.vp(2.5)
          })
          .opacity(this.vm.isReady && this.hasStreams ? 1 : 0.4)
          // 缓冲中也要能暂停：缓冲是网络侧的问题，不该把用户的停止手段也锁掉。
          .enabled(this.vm.isReady && this.hasStreams)
        .onClick(() => this.togglePlayback())

      if (this.curSource.isLive) {
        Row({ space: 6 }) {
          Circle({ width: 8, height: 8 }).fill($r('app.color.yourtube_rec_indicator'))
          Text($r('app.string.yt_label_live'))
            .fontColor(Color.White).fontSize(13).fontWeight(FontWeight.Medium)
        }
        .layoutWeight(1)
        .height(CONTROL_SLOT_SIZE)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      } else {
        Stack({ alignContent: Alignment.Center }) {
          // 轨道底层：透明 Slider 提供轨道几何（起点缩进、高度等），仅用于对齐
          Slider({ value: 0, max: 100, style: this.sliderStyle })
            .width('100%')
            .height(CONTROL_SLOT_SIZE)
            .trackColor('#33FFFFFF')       // 未缓存区底色（20%白）
            .selectedColor(Color.Transparent)
            .blockColor(Color.Transparent)
            .trackThickness(this.trackThicknessSize)
            .hitTestBehavior(HitTestMode.None)

          // 多段缓存条：onReady 是 VoidCallback，context 通过构造时传入的 cacheCanvasCtx 引用获得
          Canvas(this.cacheCanvasCtx)
            .width('100%')
            .height(this.trackThicknessSize)
            .hitTestBehavior(HitTestMode.None)
            .onReady(() => {
              this.drawCacheRanges();
            })

          // 已播放进度（顶层交互 Slider）
          Slider({
              value: this.isSliderDragging ? this.sliderDragValue
                   : this.isGestureSeek    ? this.gestureSeekTime
                   : this.currentTime,
              max: this.durationTime,
              style: this.sliderStyle
            })
            .width('100%').height(CONTROL_SLOT_SIZE)
            .trackColor(Color.Transparent).selectedColor(Color.White)
            .trackThickness(this.trackThicknessSize).enabled(!!(this.vm.isReady && this.hasStreams))
            .animation(this.uiConfig.isAnimation ? { duration: 150, curve: Curve.EaseOut } : { duration: 0 })
            .onTouch((event: TouchEvent) => this.onSliderTouch(event))
            .onChange((value: number, mode: SliderChangeMode) => this.sliderOnchange(value, mode))

          // 四合一进度条叠加层（热力图曲线 + SponsorBlock 彩色片段 + 章节刻度线；HitTestMode.None 不拦截拖动）
          SeekBarTrackOverlay({
            heatmap: (this.experimentalConfig.heatmapPluginEnabled && this.experimentalConfig.heatmapShowGraph)
              ? this.heatmap : [],
            segments: this.sponsorSegments,
            chapters: this.chapters,
            durationSec: this.durationTime,
            trackThicknessVp: this.trackThicknessSize,
            isLive: false
          })
        }
        .layoutWeight(1)
        .height(CONTROL_SLOT_SIZE)
        .constraintSize({ minWidth: PROGRESS_MIN_WIDTH })
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          this.sliderTrackLeftVp = Number(newArea.position.x);
          this.sliderTrackWidthVp = Number(newArea.width);
        })
      }

      if (this.shouldShowTimelineText()) {
        Text(`${secondToTime(Math.floor(
          this.isSliderDragging ? this.sliderDragValue
            : this.isGestureSeek ? this.gestureSeekTime
            : this.currentTime
        ))} / ${secondToTime(Math.floor(this.durationTime))}`)
          .fontColor('#F2FFFFFF')
          .fontSize(this.controlBarTextSize())
          .fontWeight(FontWeight.Medium)
          .fontFeature('"tnum" 1')
          .width(this.getCombinedTimeLabelWidth())
          .height(this.controlBarSlotSize())
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Clip })
          .textAlign(TextAlign.Center)
          .flexShrink(0)
      }

      // 全屏按鈕 — 统一槽位与图标尺寸
      if (this.showFullscreenButton) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph(this.isFullLandscapeScreen ? $r('sys.symbol.arrow_down_right_and_arrow_up_left') : $r('sys.symbol.arrow_up_left_and_arrow_down_right'))
            .fontSize(this.controlBarIconSize())
            .fontColor([Color.White])
        }
          .width(this.controlBarSlotSize())
          .height(this.controlBarSlotSize())
          .borderRadius(this.controlBarSlotSize() / 2)
          .focusable(true)
          .focusBox({
            margin: LengthMetrics.vp(3),
            strokeColor: ColorMetrics.resourceColor(this.themePrimary),
            strokeWidth: LengthMetrics.vp(2.5)
          })
          .onClick(() => {
            this.registerControlActivity();
            this.onFullScreenClick?.(!this.isFullLandscapeScreen);
          })
      }
      }
      .width('100%')
      .height(this.controlBarSlotSize() + 6)
      .padding({ left: 6, right: 6 })
      .borderRadius((this.controlBarSlotSize() + 6) / 2)
      .backgroundBlurStyle(BlurStyle.BACKGROUND_THIN)
      .backgroundColor('#4D000000')
      .border({ width: 1, color: '#2EFFFFFF' })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // 非沉浸模式保留舒适边距；沉浸全屏叠加当前导航区和底部避让值。
    .padding({
      left: this.getControlLeftPad(),
      right: this.getControlRightPad(),
      bottom: this.getControlBottomPad()
    })
    .translate({ y: this.showControls ? 0 : 12 })
    .animation(this.uiConfig.isAnimation
      ? { duration: 220, curve: Curve.FastOutSlowIn }
      : { duration: 0 })
    // 实测控制条高度喂给字幕上浮计算（隐藏时仅 opacity=0，仍在树上持续上报）
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      this.bottomControlBarVpH = Number(newArea.height);
    })
  }

  private sliderOnchange(value: number, mode: SliderChangeMode) {
    switch (mode) {
      case SliderChangeMode.Begin:
        this.sliderTouchCanceled = false;
        this.gestureMode = PlayerGestureMode.IGNORED;
        this.beginInteraction(PlayerInteractionKind.SLIDER);
        this.isSliderDragging = true;
        this.sliderDragValue = Number.isFinite(value) ? value : this.currentTime;
        this.trackThicknessSize = CommonConstants.TRACK_SIZE_MAX;
        this.sliderStyle = SliderStyle.InSet;
        break;
      case SliderChangeMode.Moving:
        this.sliderDragValue = value; // 同步更新本地值，立即反映到 UI
        this.isSliderDragging = true;
        this.trackThicknessSize = CommonConstants.TRACK_SIZE_MAX;
        this.sliderStyle = SliderStyle.InSet;
        // Moving期间仅更新UI，不发送seek命令
        break;
      case SliderChangeMode.End:
        // 使用快速seek模式（keyframe）提升响应速度
        if (!this.sliderTouchCanceled) {
          const prevSec = this.currentTime;
          this.controller.syncSeekFast(value * 1000);
          if (value > prevSec + 3) {
            this.maybeShowJumpAhead(value);
          }
        } else {
          Logger.debug(TAG, 'Slider seek canceled; final value not committed');
        }
        this.isSliderDragging = false;
        this.sliderDragValue = value;
        this.trackThicknessSize = CommonConstants.TRACK_SIZE_MIN;
        this.sliderStyle = SliderStyle.NONE;
        this.gestureMode = PlayerGestureMode.IDLE;
        this.activeInteraction = PlayerInteractionKind.NONE;
        this.sliderTouchCanceled = false;
        this.scheduleHideControls();
        break;
    }
  }

  private onSliderTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      this.sliderTouchCanceled = false;
    } else if (event.type === TouchType.Cancel) {
      this.sliderTouchCanceled = true;
      this.isSliderDragging = false;
      this.trackThicknessSize = CommonConstants.TRACK_SIZE_MIN;
      this.sliderStyle = SliderStyle.NONE;
      this.gestureMode = PlayerGestureMode.IDLE;
      if (this.activeInteraction === PlayerInteractionKind.SLIDER) {
        this.activeInteraction = PlayerInteractionKind.NONE;
      }
      Logger.debug(TAG, 'Slider touch canceled');
      this.scheduleHideControls();
    }
  }

  aboutToDisappear(): void {
    this.stopStatsOverlayPolling();
    this.resetTransientUi('component-disappear');
    this.controller.removeStateListener(this.keepScreenListener);
    this.envService.release();
    this.controller.unsubscribeProgress(this.progressListener);
    SponsorBlockSkipper.getInstance().setNoticeListener(null);
    SponsorBlockSkipper.getInstance().unsubscribeSegments(this.sponsorSegmentsListener);
    PlayerSession.getInstance().unsubscribePlaybackExtras(this.playbackExtrasListener);
    this.clearJumpAheadPill();
    if (this.skipNoticeTimerId >= 0) {
      clearTimeout(this.skipNoticeTimerId);
      this.skipNoticeTimerId = -1;
    }
    this.skipNotice = null;
    this.controller.unsubscribePlaybackState(this.playbackStateListener);
    this.controller.removeErrorListener(this.errorListener);
    this.controller.removeWaitingForBufferListener(this.waitingForBufferListener);
    this.controller.removeSeekableRangesListener(this.seekableRangesListener);
    this.controller.setSubtitleErrorListener(undefined);
    SubtitleTranslationService.getInstance().removeProgressListener(this.aiTranslateProgressListener);
    // [DISABLED] P3 ASR：监听器注销随注册一起禁用
    // AsrLiveCaptionService.getInstance().removeProgressListener(this.asrLiveProgressListener);
    // AsrLiveCaptionService.getInstance().removeErrorListener(this.asrLiveErrorListener);
  }
}

class KeepScreenOnStateListener implements StateChangeListener {
  private readonly owner: VideoPlayer;
  constructor(owner: VideoPlayer) {
    this.owner = owner;
  }
  onStateChange(_from: PlayerState, to: PlayerState): void {
    this.owner._onKeepScreenStateChanged(to);
  }
}
