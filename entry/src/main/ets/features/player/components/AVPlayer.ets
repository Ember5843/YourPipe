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

import { componentUtils, LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { audio, AVVolumePanel } from '@kit.AudioKit';
import { i18n } from '@kit.LocalizationKit';
import { AICaptionComponent, AICaptionController, AICaptionOptions } from '@kit.SpeechKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { Logger, CommonConstants, secondToTime } from 'mediaservice';
import { ThemeColorUtil } from '../../../common/ThemeColorUtil';
import {
  AvPlayerController,
  VideoData,
  StreamInfo,
  PlayerState,
  PlaybackState,
  StateChangeListener,
  VideoEntry,
  ChapterInfo,
  SubtitleTrack
} from 'mediaservice';
import { PlayerEnvironmentService } from '../PlayerEnvironmentService';
import { ActionHub } from '../../../common/ActionHub';
import { PlayerSession } from '../../../common/PlayerSession';
import { PlayerPresentation } from '../../../common/PlayerPresentation';
import { PiPManager } from '../pip/PiPManager';
import { PlayerUiViewModel } from 'mediaservice';
import { MediaThumb } from '../../../common/components/MediaThumb';
import { VideoItem } from 'youtube_core';
import { PlaybackConfig, SUBTITLE_FONT_COLOR_VALUES, SUBTITLE_BACKGROUND_VALUES } from '../../../common/PlaybackConfig';
import { PreferencesStore } from '../../../common/PreferencesStore';
import { LlmTranslateConfig } from '../../../common/LlmTranslateConfig';
import { TranslationService } from '../../../common/TranslationService';
import {
  SubtitleTranslationService,
  SubtitleTranslateProgress
} from '../translate/SubtitleTranslationService';
// [DISABLED] P3 端侧 ASR 实时识别：产品只保留 P0 tlang 官方自动翻译轨（代码保留）
// import { AsrLiveCaptionService, AsrLiveProgress } from '../asr/AsrLiveCaptionService';

const TAG: string = '[PlayerLog][VideoPlayer]';
const GESTURE_LOCK_DISTANCE: number = 12;
const GESTURE_AXIS_DOMINANCE: number = 1.25;
const CONTROLS_HIDE_DELAY: number = 3000;
const SIDE_HINT_HIDE_DELAY: number = 800;
const SEEK_HINT_HIDE_DELAY: number = 200;
const DOUBLE_TAP_HINT_HIDE_DELAY: number = 800;
const CONTROL_SLOT_SIZE: number = 40;
const CONTROL_ICON_SIZE: number = 24;
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
  @StorageProp('playerPageVisible') @Watch('onPageVisibilityChange') isPageShow: boolean = false;
  @StorageProp('isAppBackground') @Watch('onPageVisibilityChange') isAppBackground: boolean = false;
  /** 会话级仅音频：封面层在播控之下，不挡进度条/手势 */
  @StorageLink('isAudioOnlyMode') isAudioOnlyMode: boolean = false;
  @StorageLink('playbackConfig') playbackConfig: PlaybackConfig = new PlaybackConfig();
  @StorageProp('selectedVideo') selectedVideo: VideoItem | null = null;
  @Prop index: number = 0;
  @Link @Watch('onSourceChange') curSource: VideoData;
  @Prop chapters: ChapterInfo[] = [];
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
  onSurfaceReady?: (xc: XComponentController) => void;

  onSourceChange(): void {
    this.resetTransientUi('source-change');
    // Source submission is owned exclusively by PlayerSession.play() ->
    // controller.updateVideoSource(). This watcher only mirrors UI state.
    this.hasStreams = !!(this.curSource.streams && this.curSource.streams.length > 0);
    this.playbackStarted = false;

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
    }

    // 2. 向新 controller 注册监听器
    if (this.controller) {
      this.controller.subscribeProgress(this.progressListener);
      this.controller.subscribePlaybackState(this.playbackStateListener);
      this.controller.addErrorListener(this.errorListener);
      this.controller.addWaitingForBufferListener(this.waitingForBufferListener);
      this.controller.addSeekableRangesListener(this.seekableRangesListener);

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
      this.resetTransientUi('page-hidden');
      return;
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
    this.controller.subscribePlaybackState(this.playbackStateListener);
    // 错误与特殊状态监听
    this.controller.addErrorListener(this.errorListener);
    this.controller.addWaitingForBufferListener(this.waitingForBufferListener);
    this.controller.addSeekableRangesListener(this.seekableRangesListener);
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

  private onCenterTap(): void {
    this.interactionEpoch++;
    this.clearHideTimer();
    if (!this.canAutoHideControls()) {
      this.showControls = true;
      return;
    }
    this.showControls = !this.showControls;
    if (this.showControls) { this.scheduleHideControls(); } else { this.clearHideTimer(); this.clearGestureHints(); }
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
    // 拖动中途的全屏切换/换源/页面隐藏必须复位，否则标志卡住会永久门禁根手势
    this.subtitleDragging = false;
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
    // 用户显式拖动过的位置优先于控制条避让；未拖动时才按需上浮
    const hasDrag = this.subtitleDragLiftRatio !== 0 || this.subtitleDragOffsetXRatio !== 0;
    const clearance = (!hasDrag && this.showControls) ? this.bottomControlBarVpH + SUBTITLE_BAR_GAP_VP : 0;
    const lifted = Math.max(rest, clearance);
    // 拖动值按比例存储，乘回当前视频显示高度——大小屏/折叠切换位置观感不变
    return Math.min(
      Math.max(lifted + this.subtitleDragLiftRatio * layout.videoHVp, layout.letterboxVp + 8),
      layout.letterboxVp + layout.videoHVp * SUBTITLE_DRAG_MAX_RATIO);
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

  private registerDoubleTapActivity(): number {
    this.beginInteraction(PlayerInteractionKind.NONE);
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
            this.controller.setPlaybackSpeed(speed);
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

  @Builder
  SubtitleMenu() {
    Menu() {
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
          this.controller.switchSubtitle('');
          // 记忆字幕偏好：显式关闭记为空串，后续新视频不再自动开字幕
          PreferencesStore.setString('cfg_subtitle_preferred_lang', '');
        })
      ForEach(this.vm.subtitleTracks, (track: SubtitleTrack) => {
        MenuItem({
          content: this.getSubtitleLabel(track),
          endIcon: this.vm.currentSubtitleUrl === track.url ? $r('sys.symbol.checkmark') : ''
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
          .backgroundColor(this.vm.currentSubtitleUrl === track.url
            ? this.getSelectedMenuBackground() : Color.Transparent)
          .onClick(() => {
            // [DISABLED] P3 ASR 已禁用：AsrLiveCaptionService.getInstance().stop();
            this.controller.switchSubtitle(track.url);
            PreferencesStore.setString('cfg_subtitle_preferred_lang', track.languageCode || '');
          })
      }, (track: SubtitleTrack) => track.url)
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
    .width(220)
  }

  @Builder
  ChapterMenu() {
    Menu() {
      ForEach(this.chapters, (chapter: ChapterInfo, index: number) => {
        MenuItem({
          content: `${secondToTime(Math.floor(chapter.startTimeSeconds))} · ${chapter.title}`,
          endIcon: this.getCurrentChapterIndex() === index ? $r('sys.symbol.checkmark') : ''
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
          .backgroundColor(this.getCurrentChapterIndex() === index
            ? this.getSelectedMenuBackground() : Color.Transparent)
          .onClick(() => {
            Logger.info(TAG, `Chapter seek: index=${index} start=${chapter.startTimeSeconds}s`);
            this.controller.syncSeek(chapter.startTimeSeconds * 1000);
          })
      }, (chapter: ChapterInfo, index: number) => `${chapter.startTimeSeconds}_${index}`)
    }
    .onAppear(() => this.onControlMenuAppear())
    .onDisAppear(() => this.onControlMenuDisappear())
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .borderRadius(12)
    .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
    .width(280)
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
    .width(220)
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

  private getSubtitleLabel(track: SubtitleTrack): string {
    if (track.isAutoTranslated) {
      // 虚拟自动翻译轨（tlang）：显示目标语言的原生名称 + 本地化标记
      let langName = track.languageCode;
      try {
        langName = i18n.System.getDisplayLanguage(track.languageCode, track.languageCode);
      } catch (_e) {
        // 系统无法展示该语言码时回退为原始码
      }
      const marker = getContext().resourceManager.getStringSync($r('app.string.yt_player_subtitle_auto_translated').id);
      return `${langName} · ${marker}`;
    }
    return [track.name, track.languageCode, track.kind]
      .filter((value: string | undefined): boolean => !!value && value.trim().length > 0)
      .join(' · ');
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
          Logger.warn(TAG, `AI translate failed: ${res.error || '-'}`);
          this.getUIContext().getPromptAction().showToast({
            message: $r('app.string.yt_ai_translate_failed'),
            duration: 2500
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
    if (this.chapters.length > 0) {
      count++;
    }
    // 字幕菜单对 VOD 常驻：无原生轨时仍有 AI 翻译（P2）/ AI 生成字幕（P3）入口
    if (!this.curSource.isLive) {
      count++;
    }
    if (!this.curSource.isLive && this.controller.getAudioStreamList().length > 1) {
      count++;
    }
    if (this.controller.getMergedVideoList().length > 0
      && (!this.curSource.isLive || this.vm.playerModel.liveQualityReady)) {
      count++;
    }
    count++; // 画面比例按钮常驻
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
      return 80;
    }
    if (durationText.length > 5) {
      return 64;
    }
    return 48;
  }

  private getCombinedTimeLabelWidth(): number {
    return this.getTimeLabelWidth() * 2 + 12;
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

          LoadingProgress()
            .width(48)
            .height(48)
            .color(Color.White)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Black)
        .hitTestBehavior(HitTestMode.None)
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
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .hitTestBehavior(HitTestMode.None)
        .zIndex(CommonConstants.Z_INDEX_BASE + 1)
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

          Button($r('app.string.yt_action_retry'))
            .height(36)
            .padding({ left: 20, right: 20 })
            .backgroundColor(this.themePrimary)
            .borderRadius(18)
            .margin({ top: 8 })
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

      // 字幕显示层（ArkUI 覆盖层字幕：VTT 由 mediaservice 解析成 vm.subtitleText；
      // 字号/颜色/背景/底部间距跟随设置项，控制栏显示时按需上浮；
      // 拖动仅在控制层显示时允许，全向自由移动（比例化存储），拖动期间控制层保活，
      // 拖回底部/中线附近自动吸附回默认，mpv 不再烧录字幕进画面）
      if (this.vm.currentSubtitleUrl.length > 0 && this.vm.subtitleText.length > 0) {
        Column() {
          Text(this.vm.subtitleText)
            .fontColor(SUBTITLE_FONT_COLOR_VALUES[this.playbackConfig.subtitleFontColor])
            .fontSize((this.isFullLandscapeScreen ? 18 : 14) * Number(this.playbackConfig.subtitleFontScale))
            .textAlign(TextAlign.Center)
            .constraintSize({ maxWidth: '90%' })
            .textShadow({ radius: 4, color: Color.Black })
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })
            .backgroundColor(this.subtitleDragging
              ? '#B3000000'
              : SUBTITLE_BACKGROUND_VALUES[this.playbackConfig.subtitleBackground])
            .borderRadius(this.subtitleDragging ? 12 : 4)
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
        // Transparent 命中：拖动用自身 PanGesture 处理，点按/双击穿透到根手势
        // （Block 会让整条横带吞掉点击，和「单击点亮 UI」的总闸门冲突）。
        // 根容器是 parallelGesture 会同时收到本次拖动，由 subtitleDragging 标志早退。
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
        if (this.isGestureSeek) {
          Text(`${secondToTime(Math.floor(this.gestureSeekTime))} / ${secondToTime(Math.floor(this.durationTime))}`)
            .fontColor(Color.White).fontSize(26).fontWeight(FontWeight.Medium)
            .textShadow({ radius: 8, color: Color.Black })
            .alignRules({ middle: { anchor: '__container__', align: HorizontalAlign.Center }, center: { anchor: '__container__', align: VerticalAlign.Center } })
        }
        if (this.showBackwardHint) {
          Column() {
            SymbolGlyph($r('sys.symbol.gobackward_15')).fontSize(48).fontColor([Color.White])
          }
          .width('50%').height('100%')
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
          .alignRules({ top: { anchor: '__container__', align: VerticalAlign.Top }, start: { anchor: '__container__', align: HorizontalAlign.Start } })
        }
        if (this.showForwardHint) {
          Column() {
            SymbolGlyph($r('sys.symbol.goforward_15')).fontSize(48).fontColor([Color.White])
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
          Stack({ alignContent: Alignment.Bottom }) {
            Slider({ value: this.gestureBrightnessValue, max: 1, min: 0, reverse: true, style: SliderStyle.NONE, direction: Axis.Vertical })
              .trackThickness(40).selectedColor(Color.White).height(160).width(40)
            SymbolGlyph(this.gestureBrightnessIcon).fontColor([Color.Gray]).margin({ bottom: 8 }).fontSize(22)
          }
          .width('auto').height('auto')
          .alignRules({ center: { anchor: '__container__', align: VerticalAlign.Center }, start: { anchor: '__container__', align: HorizontalAlign.Start }, end: { anchor: '__container__', align: HorizontalAlign.Center } })
        }
        if (this.showVolumeHint) {
          Stack({ alignContent: Alignment.Bottom }) {
            Slider({ value: this.gestureVolumeValue, max: 1, min: 0, reverse: true, style: SliderStyle.NONE, direction: Axis.Vertical })
              .trackThickness(40).selectedColor(Color.White).height(160).width(40)
            SymbolGlyph(this.gestureVolumeIcon).fontColor([Color.Gray]).margin({ bottom: 8 }).fontSize(22)
          }
          .width('auto').height('auto')
          .alignRules({ center: { anchor: '__container__', align: VerticalAlign.Center }, start: { anchor: '__container__', align: HorizontalAlign.Center }, end: { anchor: '__container__', align: HorizontalAlign.End } })
        }
      }
      .width('100%').height('100%').hitTestBehavior(HitTestMode.None).zIndex(CommonConstants.Z_INDEX_BASE + 3)

      // 3. 播控层
      Column() {
        this.TopControl()
        Blank().width('100%').layoutWeight(1)
        this.PlayControl()
      }
      .width('100%').height('100%')
      .opacity(this.showControls ? 1 : 0)
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
    .parallelGesture(
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 2, fingers: 1 })
          .onAction((event: GestureEvent) => {
            // 双击 ±15s 属于「隐藏态也放行」的进度控制（会顺手点亮 UI）
            this.registerDoubleTapActivity();
            const x: number = event.fingerList[0]?.localX ?? 0;
            if (x > this.containerVpWidth / 2) {
              Logger.info(TAG, 'Double-tap forward +15s');
              this.controller.syncSeek(Math.min(this.currentTime + 15, this.durationTime) * 1000);
              this.showForwardHint = true;
              this.forwardHintTimerId = setTimeout(() => {
                this.forwardHintTimerId = -1;
                this.showForwardHint = false;
              }, DOUBLE_TAP_HINT_HIDE_DELAY);
            } else {
              Logger.info(TAG, 'Double-tap backward -15s');
              this.controller.syncSeek(Math.max(this.currentTime - 15, 0) * 1000);
              this.showBackwardHint = true;
              this.backwardHintTimerId = setTimeout(() => {
                this.backwardHintTimerId = -1;
                this.showBackwardHint = false;
              }, DOUBLE_TAP_HINT_HIDE_DELAY);
            }
          }),
        TapGesture({ count: 1, fingers: 1 })
          .onAction((_event: GestureEvent) => {
            this.onCenterTap();
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
    // 双指缩放在触摸层处理（PinchGesture 在 Exclusive 组内会被单指 pan 竞争掉）
    .onTouch((event: TouchEvent) => this.onPinchTouch(event))
  }

  private menuSymbol(icon: Resource): SymbolGlyphModifier {
    return new SymbolGlyphModifier(icon).fontSize('22vp');
  }

  @Builder
  TopToolsCollapsedMenu() {
    // 折叠总菜单：symbolStartIcon 显示与展开态相同的系统图标；倍速用 labelInfo 显示当前 Nx。
    Menu() {
      if (this.chapters.length > 0) {
        MenuItem({
          symbolStartIcon: this.menuSymbol($r('sys.symbol.list_bullet_square')),
          content: $r('app.string.yt_player_chapters'),
          builder: (): void => {
            this.ChapterMenu()
          }
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
      }
      if (!this.curSource.isLive) {
        MenuItem({
          symbolStartIcon: this.menuSymbol($r('sys.symbol.AI_subtitles')),
          content: $r('app.string.yt_player_subtitles'),
          builder: (): void => {
            this.SubtitleMenu()
          }
        })
          .contentFontColor($r('sys.color.font_primary'))
          .contentFont({ size: 14 })
      }
      if (!this.curSource.isLive && this.controller.getAudioStreamList().length > 1) {
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
      if (this.controller.getMergedVideoList().length > 0
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
  TopToolsExpandedRow() {
    Row({ space: this.getControlItemGap() }) {
      if (this.chapters.length > 0) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.list_bullet_square'))
            .fontSize(CONTROL_ICON_SIZE)
            .fontColor([Color.White])
        }
          .width(SPEED_CONTROL_WIDTH)
          .height(CONTROL_SLOT_SIZE)
          .accessibilityText($r('app.string.yt_player_chapters'))
          .bindMenu(this.ChapterMenu())
      }

      if (!this.curSource.isLive) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.AI_subtitles'))
            .fontSize(CONTROL_ICON_SIZE)
            .fontColor([Color.White])
        }
          .width(SPEED_CONTROL_WIDTH)
          .height(CONTROL_SLOT_SIZE)
          .bindMenu(this.SubtitleMenu())
      }

      if (!this.curSource.isLive && this.controller.getAudioStreamList().length > 1) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.speaker_wave_2'))
            .fontSize(CONTROL_ICON_SIZE)
            .fontColor([Color.White])
        }
          .width(SPEED_CONTROL_WIDTH)
          .height(CONTROL_SLOT_SIZE)
          .bindMenu(this.AudioMenu())
      }

      if (this.controller.getMergedVideoList().length > 0
      && (!this.curSource.isLive || this.vm.playerModel.liveQualityReady)) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.resolution_video'))
            .fontSize(CONTROL_ICON_SIZE)
            .fontColor([Color.White])
        }
          .width(SPEED_CONTROL_WIDTH)
          .height(CONTROL_SLOT_SIZE)
          .bindMenu(this.VideoMenu())
      }

      if (!this.curSource.isLive) {
        Text(this.vm.playbackSpeed + 'x')
          .fontSize(16)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Medium)
          .width(SPEED_CONTROL_WIDTH)
          .height(CONTROL_SLOT_SIZE)
          .maxLines(1)
          .textAlign(TextAlign.Center)
          .bindMenu(this.SpeedMenu())
      }

      // 画面比例：下拉菜单选择（与其他选项一致的交互），菜单打开期间 UI 保活
      Text(this.aspectModeLabel())
        .fontSize(13)
        .fontColor(Color.White)
        .fontWeight(FontWeight.Medium)
        .height(CONTROL_SLOT_SIZE)
        .padding({ left: 8, right: 8 })
        .textAlign(TextAlign.Center)
        .accessibilityText($r('app.string.yt_player_aspect_mode'))
        .bindMenu(this.AspectMenu())
    }
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  TopControl() {
    Row() {
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(CONTROL_ICON_SIZE)
          .fontWeight(FontWeight.Medium)
          .fontColor([Color.White])
      }
        .width(CONTROL_SLOT_SIZE)
        .height(CONTROL_SLOT_SIZE)
        .onClick(() => {
          // Explicit close button: force teardown so the page pop never leaves
          // an invisible dangling playback session behind.
          PlayerSession.getInstance().release(true);
          this.actionHub.closePage();
        })

      Blank()

      if (this.shouldCollapseTopTools()) {
        Stack({ alignContent: Alignment.Center }) {
          SymbolGlyph($r('sys.symbol.line_3_horizontal'))
            .fontSize(CONTROL_ICON_SIZE)
            .fontColor([Color.White])
        }
          .width(CONTROL_SLOT_SIZE)
          .height(CONTROL_SLOT_SIZE)
          .accessibilityText($r('app.string.yt_player_more_tools'))
          .bindMenu(this.TopToolsCollapsedMenu())
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
    .linearGradient({
      direction: GradientDirection.Bottom,
      colors: [
        ['#66000000', 0.0],
        ['#00000000', 1.0]
      ]
    })
  }

  @Builder
  PlayControl() {
    Row({ space: this.getControlItemGap() }) {
      // 播放/暂停按鈕：正在播放或缓冲中时显示暂停图标，其他状态显示播放图标
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(this.vm.isPlaying ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
          .fontSize(CONTROL_ICON_SIZE)
          .fontColor([Color.White])
      }
        .width(CONTROL_SLOT_SIZE)
        .height(CONTROL_SLOT_SIZE)
        .opacity(this.vm.isReady && this.hasStreams ? 1 : 0.4)
        .enabled(this.vm.isReady && this.hasStreams && !this.vm.isBuffering)
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

          // 已播放进度（顶层）
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
            .onTouch((event: TouchEvent) => this.onSliderTouch(event))
            .onChange((value: number, mode: SliderChangeMode) => this.sliderOnchange(value, mode))
        }
        .layoutWeight(1)
        .height(CONTROL_SLOT_SIZE)
        .constraintSize({ minWidth: PROGRESS_MIN_WIDTH })
      }

      if (this.shouldShowTimelineText()) {
        Text(`${secondToTime(Math.floor(
          this.isSliderDragging ? this.sliderDragValue
            : this.isGestureSeek ? this.gestureSeekTime
            : this.currentTime
        ))} / ${secondToTime(Math.floor(this.durationTime))}`)
          .fontColor('#DDFFFFFF')
          .fontSize(13)
          .width(this.getCombinedTimeLabelWidth())
          .height(CONTROL_SLOT_SIZE)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Clip })
          .textAlign(TextAlign.Center)
          .flexShrink(0)
      }

      // 全屏按鈕 — fontSize 统一用 vp，移除冲突的 height(24)限制
      Stack({ alignContent: Alignment.Center }) {
        SymbolGlyph(this.isFullLandscapeScreen ? $r('sys.symbol.arrow_down_right_and_arrow_up_left') : $r('sys.symbol.arrow_up_left_and_arrow_down_right'))
          .fontSize(CONTROL_ICON_SIZE)
          .fontColor([Color.White])
      }
        .width(CONTROL_SLOT_SIZE)
        .height(CONTROL_SLOT_SIZE)
        .onClick(() => {
          this.registerControlActivity();
          this.onFullScreenClick?.(!this.isFullLandscapeScreen);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    // 非沉浸模式保留舒适边距；沉浸全屏叠加当前导航区和底部避让值。
    .padding({
      left: this.getControlLeftPad(),
      right: this.getControlRightPad(),
      bottom: this.getControlBottomPad()
    })
    .linearGradient({ direction: GradientDirection.Bottom, colors: [['#00000000', 0.0], ['#66000000', 1.0]] })
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
        this.sliderDragValue = this.currentTime; // 初始化为当前位置
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
          this.controller.syncSeekFast(value * 1000);
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
    this.resetTransientUi('component-disappear');
    this.controller.removeStateListener(this.keepScreenListener);
    this.envService.release();
    this.controller.unsubscribeProgress(this.progressListener);
    this.controller.unsubscribePlaybackState(this.playbackStateListener);
    this.controller.removeErrorListener(this.errorListener);
    this.controller.removeWaitingForBufferListener(this.waitingForBufferListener);
    this.controller.removeSeekableRangesListener(this.seekableRangesListener);
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
