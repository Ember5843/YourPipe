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

import { componentUtils, SymbolGlyphModifier } from '@kit.ArkUI';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { audio, AVVolumePanel } from '@kit.AudioKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { Logger, CommonConstants, secondToTime } from 'mediaservice';
import { AvPlayerController, VideoData, StreamInfo, PlayerState, StateChangeListener, VideoEntry, SubtitleTrack } from 'mediaservice';
import { PlayerEnvironmentService } from '../PlayerEnvironmentService';
import { ActionHub } from '../../../common/ActionHub';
import { PlayerSession } from '../../../common/PlayerSession';
import { PlayerPresentation } from '../../../common/PlayerPresentation';
import { PiPManager } from '../pip/PiPManager';
import { PlayerUiViewModel } from 'mediaservice';

const TAG: string = '[PlayerLog][VideoPlayer]';

interface MySurfaceRect {
  offsetX: number;
  offsetY: number;
  surfaceWidth: number;
  surfaceHeight: number;
}

@Preview
@Component
export struct VideoPlayer {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @Consume('actionHub') actionHub: ActionHub;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('currentColorMode') currentColorMode: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  @Prop @Watch('calculateSurfaceSize') isFullLandscapeScreen: boolean = false;
  @StorageProp('playerPageVisible') @Watch('onPageVisibilityChange') isPageShow: boolean = false;
  @StorageProp('isAppBackground') @Watch('onPageVisibilityChange') isAppBackground: boolean = false;
  @Prop index: number = 0;
  @Link @Watch('onSourceChange') curSource: VideoData;
  @Prop @Watch('onIndexChange') curIndex: number = CommonConstants.CURINDEX_DEFAULT_NUM;
  @State surfaceWidth: number = CommonConstants.SURFACE_WIDTH;
  @State surfaceHeight: number = CommonConstants.SURFACE_HEIGHT;
  @State containerWidthPX: number = 0;
  @State containerHeightPX: number = 0;
  // 预计算的渲染矩形缓存，用于调试和性能优化
  @State portraitRect: MySurfaceRect = { offsetX: 0, offsetY: 0, surfaceWidth: 0, surfaceHeight: 0 };
  @State landscapeRect: MySurfaceRect = { offsetX: 0, offsetY: 0, surfaceWidth: 0, surfaceHeight: 0 };
  
  @State trackThicknessSize: number = CommonConstants.TRACK_SIZE_MIN;
  @Link @Watch('onControllerChanged') controller: AvPlayerController;
  // ArkUI V1 的 @Track 不会穿透到嵌套 @Observed，因此 vm 必须由组件自己 @Link，
  // 才能让 vm 内部字段（isPlaying / isReady / ...）的变化触发 UI 重渲染。
  @Link vm: PlayerUiViewModel;
  private lastController?: AvPlayerController;
  private qualityArrowModifier: SymbolGlyphModifier = new SymbolGlyphModifier();
  @State hasStreams: boolean = false;
  @State hasError: boolean = false;
  @State isWaitingForDualBuffer: boolean = false;
  // currentTime/durationTime 通过节流后的 ProgressSubscriber 更新（避免高频 @Track 触发 UI 重渲染）
  @State currentTime: number = 0;
  @State durationTime: number = 0;

  // 投屏状态
  @State isCasting: boolean = false;
  @State castDeviceName: string = '';

  /**
   * 状态机监听器：在 PLAYING/BUFFERING/READY 时保持屏幕常亮，
   * 其余状态（PAUSED/COMPLETED/ERROR/IDLE/RELEASED）释放常亮，让系统正常息屏。
   *
   * 旧实现把 onPlayingChanged 写成 "@Watch" 风格但从未注册，
   * 导致 setWindowKeepScreenOn 永远不会被调用、播放中息屏。
   */
  private keepScreenListener: StateChangeListener = new KeepScreenOnStateListener(this);

  /**
   * PiP 播放/暂停按钮同步监听器：把 MPV 状态机的状态变化同步给画中画面板，
   * 使 PiP 控件显示与真实播放状态一致。
   * 缓冲(BUFFERING)不切换，避免按钮抖动；其余按 isPlaying 语义推送。
   */
  private pipSyncListener: StateChangeListener = new PiPPlayPauseSyncListener(this);

  // 由 KeepScreenOnStateListener 调用，集中管理屏幕常亮策略。
  public _onKeepScreenStateChanged(to: PlayerState): void {
    const shouldKeepOn: boolean = to === PlayerState.PLAYING
      || to === PlayerState.BUFFERING
      || to === PlayerState.READY;
    this.envService.setKeepScreenOn(shouldKeepOn);
    if (shouldKeepOn) {
      this.scheduleHideControls();
    } else {
      this.clearHideTimer();
    }
  }

  // 由 PiPPlayPauseSyncListener 调用：把 MPV 状态同步到画中画播放/暂停按钮。
  // PLAYING → PLAY（显示暂停按钮）；PAUSED/COMPLETED/READY/IDLE/ERROR/RELEASED → PAUSE（显示播放按钮）；
  // BUFFERING 跳过，避免缓冲时按钮来回抖动。
  public _onPiPStateChanged(to: PlayerState): void {
    if (to === PlayerState.BUFFERING) {
      return;
    }
    const isPlaying: boolean = to === PlayerState.PLAYING;
    PiPManager.getInstance().updatePlayPauseStatus(isPlaying);
  }

  private progressListener = (currentTime: number, durationTime: number) => {
    this.currentTime = currentTime;
    this.durationTime = durationTime;
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
  @State isSliderGesture: boolean = false;
  private panGestureIgnoredForSlider: boolean = false; // 在 onActionStart 时记录，避免 End 时的竞争条件
  private sliderChangeDebounceTimer: number = -1; // Seek防抖定时器
  // UI auto-hide
  @State showControls: boolean = true;
  private controlsHideTimerId: number = -1;
  @State containerVpWidth: number = 0;
  // 基于容器实际尺寸计算的比例間距（单位 vp）
  // 手机(360vp宽): H≈ 16  V≈ 14
  // 平板(1000vp+宽): H≈ 28  V≈ 20+
  @State ctrlHPad: number = 20;  // 播控层左右 padding
  @State ctrlVPad: number = 14;  // 播控层上下基础 padding
  // horizontal seek gesture
  @State isGestureSeek: boolean = false;
  @State gestureSeekTime: number = 0;
  private gestureSeekStartTime: number = 0;
  private panEndTime: number = 0;
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
  private verticalGestureDir: string = 'none';
  // double-tap hints
  // Canvas context for multi-segment cache bar rendering.
  // HarmonyOS Canvas onReady 是 VoidCallback（无参数），context 通过构造时传入的对象引用获得。
  private cacheCanvasSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private cacheCanvasCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.cacheCanvasSettings);
  private seekableRangesListener = () => { this.drawCacheRanges(); };
  private isHandlingEnded: boolean = false;
  private onEnded = () => {
    if (this.isHandlingEnded) {
      return;
    }
    this.isHandlingEnded = true;
    const autoPlay = AppStorage.get<boolean>('autoPlayQueue') ?? true;
    if (!autoPlay) {
      this.isHandlingEnded = false;
      return;
    }
    PlayerSession.getInstance().playNextFromQueue().finally(() => { this.isHandlingEnded = false; });
  };
  // 屏幕实件订阅者：监听 SCREEN_OFF / SCREEN_ON 以关闭/恢复视频输出
  private screenEventSubscriber: commonEventManager.CommonEventSubscriber | null = null;
  @State showForwardHint: boolean = false;
  @State showBackwardHint: boolean = false;
  private forwardHintTimerId: number = -1;
  private backwardHintTimerId: number = -1;

  
  // 播放页渲染用的 XComponentController。也作为 PiP 的 componentController：
  // XComponent 方式的 PiP 不迁移节点，进/出 PiP 时同一个 surface 直接投到悬浮窗，
  // surfaceId 不变，MPV 无需 detach/re-attach，避免黑帧与几何丢失。
  private x_componentController: XComponentController = new XComponentController();
  private screenHeight: number = 0;
  private envService: PlayerEnvironmentService = new PlayerEnvironmentService();

  // 手势控制相关的私有变量
  private panStartX: number = 0;
  private panStartTime: number = 0;

  onFullScreenClick: (isLandscape?: boolean) => void = () => {};
  /** 当播放器内部发生不可恢复错误时，通知父组件重新获取流信息 */
  onRetry: () => void = () => {};
  onSurfaceReady?: (xc: XComponentController) => void;

  /**
   * 核心预计算逻辑：提前算出竖屏和横屏下的 Surface 渲染区域
   */
  private preCalculateRects(): void {
    if (!this.curSource.width || !this.curSource.height) {
      Logger.warn(TAG, 'Cannot pre-calculate: video dimensions missing');
      return;
    }
    
    const videoRatio = this.curSource.width / this.curSource.height;
    const dw = AppStorage.get<number>('deviceWidth') || 0;
    const dh = AppStorage.get<number>('deviceHeight') || 0;
    
    if (dw <= 0 || dh <= 0) {
      Logger.warn(TAG, 'Cannot pre-calculate: device dimensions missing');
      return;
    }

    // 1. 预计算竖屏 (假设当前宽度为短边)
    const pW = Math.min(dw, dh);
    const pH = pW / videoRatio; 
    this.portraitRect = this.getFitRect(pW, pH, videoRatio);

    // 2. 预计算横屏 (全屏，假设宽度为长边)
    const lW = Math.max(dw, dh);
    const lH = Math.min(dw, dh);
    this.landscapeRect = this.getFitRect(lW, lH, videoRatio);
    
    Logger.debug(TAG, `DEBUG - Pre-calculated Portrait: ${JSON.stringify(this.portraitRect)}`);
    Logger.debug(TAG, `DEBUG - Pre-calculated Landscape: ${JSON.stringify(this.landscapeRect)}`);
  }

  private getFitRect(cw: number, ch: number, vr: number): MySurfaceRect {
    let sw = 0;
    let sh = 0;
    if (vr > (cw / ch)) {
      sw = cw;
      sh = cw / vr;
    } else {
      sh = ch;
      sw = ch * vr;
    }
    return {
      offsetX: Math.round((cw - sw) / 2),
      offsetY: Math.round((ch - sh) / 2),
      surfaceWidth: Math.round(sw),
      surfaceHeight: Math.round(sh)
    };
  }

  async onSourceChange(): Promise<void> {
    // 切换源时更新本地流状态标记
    this.hasStreams = !!(this.curSource.streams && this.curSource.streams.length > 0);

    Logger.info(TAG, `Source changed to: ${this.curSource.name}. hasStreams: ${this.hasStreams}. Triggering updateVideoSource.`);
    await this.controller.updateVideoSource(this.curSource);
    this.syncPlaybackStateFromController();

    this.preCalculateRects();
    this.calculateSurfaceSize();
  }

  /**
   * Controller 实例被替换时（如 session.release + resetSession 后）自动迁移监听器
   * 并重新绑定 Surface ID，防止切视频后出现黑屏或 UI 无响应。
   */
  private onControllerChanged(): void {
    // 1. 从旧 controller 移除监听器
    if (this.lastController && this.lastController !== this.controller) {
      this.lastController.unsubscribeProgress(this.progressListener);
      this.lastController.unsubscribeEnded(this.onEnded);
      this.lastController.removeErrorListener(this.errorListener);
      this.lastController.removeWaitingForBufferListener(this.waitingForBufferListener);
      this.lastController.removeSeekableRangesListener(this.seekableRangesListener);
    }

    // 2. 向新 controller 注册监听器
    if (this.controller) {
      this.controller.subscribeProgress(this.progressListener);
      this.controller.subscribeEnded(this.onEnded);
      this.controller.addErrorListener(this.errorListener);
      this.controller.addWaitingForBufferListener(this.waitingForBufferListener);
      this.controller.addSeekableRangesListener(this.seekableRangesListener);

      // 3. 立即同步 UI 状态
      this.currentTime = this.vm.currentTime;
      this.durationTime = this.vm.durationTime;
      this.hasError = this.vm.errorMsg.length > 0;
      const pm = this.vm.playerModel;
      this.hasStreams = pm ? (pm.categorizedStreams.audio.length + pm.categorizedStreams.video.length +
                              pm.categorizedStreams.dashManifest.length + pm.categorizedStreams.hlsManifest.length +
                              pm.categorizedStreams.progressive.length) > 0 : false;
      this.isCasting = this.vm.isCasting;
      this.castDeviceName = this.vm.castDeviceName;
      this.syncPlaybackStateFromController();

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
  }

  async aboutToAppear(): Promise<void> {
    const context: Context = this.getUIContext().getHostContext() as Context;

    // 清理错误状态（包括 PlayerPage 设置的 API 层错误和 Controller 设置的播放错误）
    this.vm.errorMsg = '';
    this.hasError = false;
    this.isWaitingForDualBuffer = false;
    this.curSource.error = undefined;

    // 注册进度监听（节流后的 currentTime/durationTime）
    this.controller.subscribeProgress(this.progressListener);
    this.controller.subscribeEnded(this.onEnded);
    // 错误与特殊状态监听
    this.controller.addErrorListener(this.errorListener);
    this.controller.addWaitingForBufferListener(this.waitingForBufferListener);
    this.controller.addSeekableRangesListener(this.seekableRangesListener);
    // 屏幕常亮：跟随播放状态机驱动
    this.controller.addStateListener(this.keepScreenListener);
    // PiP 播放/暂停按钮同步：跟随 MPV 状态机驱动
    this.controller.addStateListener(this.pipSyncListener);
    // 立即按当前 vm 状态同步一次（避免错过初始 PLAYING / 引擎已就绪）
    this.envService.setKeepScreenOn(this.vm.isPlaying || this.vm.isBuffering);
    // 立即同步一次 PiP 播放/暂停按钮状态（页面恢复/复用时按钮即时对齐）
    PiPManager.getInstance().updatePlayPauseStatus(this.vm.isPlaying);

    // 同步投屏状态
    this.isCasting = this.vm.isCasting;
    this.castDeviceName = this.vm.castDeviceName;

    // 初始化流状态
    this.hasStreams = !!(this.curSource.streams && this.curSource.streams.length > 0);

    // 初始化环境服务
    await this.envService.init(context);
    const brightness = await this.envService.getBrightness(context);
    this.gestureBrightnessValue = brightness;
    const volInfo = this.envService.getVolume();
    this.gestureVolumeValue = volInfo.volume / volInfo.maxVolume;
    this.screenHeight = AppStorage.get<number>('deviceHeight') || 0;

    this.qualityArrowModifier.fontSize(13).fontColor(['#CCCCCC']);

    this.preCalculateRects();
    this.calculateSurfaceSize();

    // 确保播放引擎已初始化（不再需要传递 XComponentController）
    const session = PlayerSession.getInstance();
    await session.ensureInitialized();

    // 主动注入 componentController：aboutToAppear 每次组件创建必跑，比 onLoad 可靠。
    // 冷启动 destroy 清空了 PiPManager.componentController，若仅靠 onLoad 重注入，
    // 节点复用不重跑 onLoad 时会导致 pendingInit 永远挂起、PiP 不可用。这里兜底注入。
    PiPManager.getInstance().setComponentController(this.x_componentController);

    // XComponent.onLoad 时会自动绑定 surfaceId

    // 订阅屏幕锁定/亮屏事件
    this.envService.subscribeScreenEvents(
      () => { /* screen off — globally disabled */ },
      () => {
        Logger.info(TAG, 'Screen on → restore playback');
        if (this.vm.isReady && !this.vm.isPlaying) {
          this.controller.syncPlay();
        }
      }
    );
  }

  // ── 多段缓存条绘制 ──
  // 当 seekableRanges 更新时由 @Watch 触发，在 Canvas onReady 保存的 ctx 上绘制。
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
    this.controlsHideTimerId = setTimeout(() => {
      this.showControls = false;
      this.controlsHideTimerId = -1;
    }, 3000);
  }

  private clearHideTimer(): void {
    if (this.controlsHideTimerId >= 0) {
      clearTimeout(this.controlsHideTimerId);
      this.controlsHideTimerId = -1;
    }
  }

  private onCenterTap(): void {
    this.showControls = !this.showControls;
    if (this.showControls) { this.scheduleHideControls(); } else { this.clearHideTimer(); }
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
        MenuItem({ content: speed + 'x' })
          .onClick(() => {
            this.controller.setPlaybackSpeed(speed);
          })
      })
    }
  }

  @Builder
  SubtitleMenu() {
    Menu() {
      MenuItem({
        content: (this.vm.currentSubtitleUrl === '' ? '\u2713 ' : '') + '关闭字幕'
      })
        .onClick(() => {
          this.controller.switchSubtitle('');
        })
      ForEach(this.vm.subtitleTracks, (track: SubtitleTrack) => {
        MenuItem({
          content: (this.vm.currentSubtitleUrl === track.url ? '\u2713 ' : '') + track.name
        })
          .onClick(() => {
            this.controller.switchSubtitle(track.url);
          })
      }, (track: SubtitleTrack) => track.url)
    }
  }

  private getSelectedVideoIndex(): number {
    const list = this.controller.getMergedVideoList();
    const current = this.vm.playerModel.currentVideoStream;
    const idx = list.findIndex((e: VideoEntry) => e.stream === current);
    return idx >= 0 ? idx : 0;
  }

  private getCurrentQualityLabel(): string {
    const list = this.controller.getMergedVideoList();
    const idx = this.getSelectedVideoIndex();
    if (idx >= 0 && idx < list.length) {
      return `${list[idx].resolutionLabel} (${list[idx].codecLabel})`;
    }
    return 'Auto';
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
        .aspectRatio(this.curSource.width && this.curSource.height ? this.curSource.width / this.curSource.height : 16 / 9)
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const pxWidth = Math.round(this.getUIContext().vp2px(Number(newArea.width)));
          const pxHeight = Math.round(this.getUIContext().vp2px(Number(newArea.height)));
          if (pxWidth > 0 && pxHeight > 0) {
            Logger.debug(TAG, `XComponent onAreaChange: ${pxWidth}x${pxHeight} px`);
            this.controller.resizeSurface(pxWidth, pxHeight);
          }
        })
        .zIndex(CommonConstants.Z_INDEX_BASE)

      // 加载中/缓冲提示层
      if (this.vm.isBuffering) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(Color.White)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
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

          Text(this.getErrorDisplay(this.curSource.error || this.vm.errorMsg))
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

      // 字幕显示层
      if (this.vm.currentSubtitleUrl.length > 0 && this.vm.subtitleText.length > 0) {
        Column() {
          Text(this.vm.subtitleText)
            .fontColor(Color.White)
            .fontSize(this.isFullLandscapeScreen ? 18 : 14)
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 12, right: 12, top: 4, bottom: 4 })
            .backgroundColor('#80000000')
            .borderRadius(4)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .position({ bottom: this.isFullLandscapeScreen ? 64 : 48 })
        .zIndex(CommonConstants.Z_INDEX_BASE + 2.5)
        .hitTestBehavior(HitTestMode.None)
      }

      // 左右垂直手势层（独立绑定，避免与 Horizontal PanGesture 竞争）
      Row() {
        Column()
          .width('50%').height('100%')
          .gesture(
            PanGesture({ direction: PanDirection.Vertical })
              .onActionStart((_event: GestureEvent) => {
                this.scheduleHideControls();
                this.verticalGestureDir = 'brightness';
                try {
                  const context: Context = this.getUIContext().getHostContext() as Context;
                  this.gestureBrightnessValue = this.envService.getBrightnessSync(context);
                } catch (_e) {
                  // 读取失败时保留上次缓存值，不影响手势逻辑
                }
                this.gestureInitValue = this.gestureBrightnessValue;
                this.showBrightnessHint = true;
              })
              .onActionUpdate((event: GestureEvent) => {
                const v: number = Math.min(1, Math.max(0, this.gestureInitValue + (-event.offsetY / 200)));
                this.gestureBrightnessValue = v;
                this.envService.setBrightness(v);
                this.gestureBrightnessIcon = v > 0.3 ? $r('sys.symbol.sun_max_fill') : $r('sys.symbol.moon_fill');
              })
              .onActionEnd((_e: GestureEvent) => {
                clearTimeout(this.brightnessHideTimerId);
                this.brightnessHideTimerId = setTimeout(() => { this.showBrightnessHint = false; }, 2000);
                this.verticalGestureDir = 'none';
              })
          )
        Column()
          .width('50%').height('100%')
          .gesture(
            PanGesture({ direction: PanDirection.Vertical })
              .onActionStart((_event: GestureEvent) => {
                this.scheduleHideControls();
                this.verticalGestureDir = 'volume';
                try {
                  const volInfo = this.envService.getVolume();
                  this.gestureVolumeValue = volInfo.volume / volInfo.maxVolume;
                } catch (_e) {
                  // 读取失败时保留上次缓存值，不影响手势逻辑
                }
                this.gestureInitValue = this.gestureVolumeValue;
                this.showVolumeHint = true;
              })
              .onActionUpdate((event: GestureEvent) => {
                const v: number = Math.min(1, Math.max(0, this.gestureInitValue + (-event.offsetY / 200)));
                this.gestureVolumeValue = v;
                this.envService.setVolume(Math.round(v * this.envService.getVolume().maxVolume));
                this.gestureVolumeIcon = v > 0.5 ? $r('sys.symbol.speaker_wave_3_fill') : (v > 0 ? $r('sys.symbol.speaker_wave_1_fill') : $r('sys.symbol.speaker_slash_fill'));
              })
              .onActionEnd((_e: GestureEvent) => {
                clearTimeout(this.volHideTimerId);
                this.volHideTimerId = setTimeout(() => { this.showVolumeHint = false; }, 2000);
                this.verticalGestureDir = 'none';
              })
          )
      }
      .width('100%').height('100%')
      .hitTestBehavior(HitTestMode.Transparent)
      .zIndex(10)

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
      .hitTestBehavior(this.showControls ? HitTestMode.Transparent : HitTestMode.None)
      .zIndex(CommonConstants.Z_INDEX_MAX)
    }
    .width(CommonConstants.WIDTH_FULL_PERCENT)
    .height(CommonConstants.HEIGHT_FULL_PERCENT)
    .id('PlayerContainer')
    .backgroundColor(Color.Black)
    .onSizeChange((_old: SizeOptions, newSize: SizeOptions) => {
      const w = newSize.width as number;
      const h = newSize.height as number;
      this.containerVpWidth = w;
      // 按容器实际尺寸计算比例間距，手机和平板自适应
      // 横向：3% 宽度，不超过 32vp，不小于 16vp
      this.ctrlHPad = Math.min(32, Math.max(16, Math.round(w * 0.03)));
      // 竖向：3% 高度，不超过 16vp，不小于 8vp
      this.ctrlVPad = Math.min(16, Math.max(8, Math.round(h * 0.03)));
    })
    .parallelGesture(
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 2, fingers: 1 })
          .onAction((event: GestureEvent) => {
            this.scheduleHideControls();
            const x: number = event.fingerList[0]?.localX ?? 0;
            if (x > this.containerVpWidth / 2) {
              Logger.info(TAG, 'Double-tap forward +15s');
              this.controller.syncSeek(Math.min(this.currentTime + 15, this.durationTime) * 1000);
              clearTimeout(this.forwardHintTimerId);
              this.showForwardHint = true;
              this.forwardHintTimerId = setTimeout(() => { this.showForwardHint = false; }, 800);
            } else {
              Logger.info(TAG, 'Double-tap backward -15s');
              this.controller.syncSeek(Math.max(this.currentTime - 15, 0) * 1000);
              clearTimeout(this.backwardHintTimerId);
              this.showBackwardHint = true;
              this.backwardHintTimerId = setTimeout(() => { this.showBackwardHint = false; }, 800);
            }
          }),
        TapGesture({ count: 1, fingers: 1 })
          .onAction((_event: GestureEvent) => {
            this.onCenterTap();
          }),
        PanGesture({ direction: PanDirection.Horizontal })
          .onActionStart((_e: GestureEvent) => {
            // 在 Start 时记录是否因 Slider 拖动而忙略，该标记会持续到 End
            if (this.isSliderDragging) {
              this.panGestureIgnoredForSlider = true;
              return;
            }
            this.panGestureIgnoredForSlider = false;
            this.scheduleHideControls();
            this.isGestureSeek = true;
            this.gestureSeekStartTime = this.currentTime;
          })
          .onActionUpdate((event: GestureEvent) => {
            if (this.panGestureIgnoredForSlider) { return; }
            const seekWidth = Math.max(1, this.containerVpWidth);
            const t = this.gestureSeekStartTime + (event.offsetX / seekWidth) * this.durationTime;
            this.gestureSeekTime = Math.min(Math.max(0, t), this.durationTime);
            this.panEndTime = this.gestureSeekTime;
          })
          .onActionEnd((_e: GestureEvent) => {
            if (this.panGestureIgnoredForSlider) {
              // 本次 PanGesture 属于 Slider 拖动的伴随手势，不执行 seek
              this.panGestureIgnoredForSlider = false;
              this.isGestureSeek = false;
              return;
            }
            // 空白区域横滑：独立调用 syncSeek
            this.controller.syncSeek(this.panEndTime * 1000);
            this.isGestureSeek = false;
          })
      )
    )
  }

  @Builder
  TopControl() {
    Row() {
      SymbolGlyph($r('sys.symbol.xmark'))
        .width(24)
        .height(24)
        .fontColor([Color.White])
        .onClick(() => {
          PlayerSession.getInstance().release();
          this.actionHub.closePage();
        })

      // 字幕按钮（仅在可用字幕轨道时显示）
      if (this.vm.subtitleTracks.length > 0) {
        Text('CC')
          .fontSize(16)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Medium)
          .bindMenu(this.SubtitleMenu())
      }

      Blank()

      // 右侧操作栏 (字幕 + 清晰度 + 播放速度)
      Row({ space: 20 }) {
        // 清晰度选择（直播时隐藏）
        if (!this.curSource.isLive) {
          Select(
            this.controller.getMergedVideoList().map((e: VideoEntry) =>
              ({ value: `${e.resolutionLabel} (${e.codecLabel})` } as SelectOption)
            )
          )
            .selected(this.getSelectedVideoIndex())
            .value(this.getCurrentQualityLabel())
            .font({ size: 13 })
            .fontColor(this.currentColorMode === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT ? '#1A1A1A' : Color.White)
            .selectedOptionFont({ size: 14, weight: FontWeight.Bold })
            .selectedOptionFontColor(this.themePrimary)
            .selectedOptionBgColor('#1AD32F2F')
            .optionFont({ size: 14 })
            .optionFontColor($r('app.color.yourtube_text_secondary'))
            .menuBackgroundColor($r('app.color.yourtube_bg_surface'))
            .backgroundColor(Color.Transparent)
            .arrowModifier(this.qualityArrowModifier)
            .onSelect((index: number) => {
              const entry = this.controller.getMergedVideoList()[index];
              if (entry) {
                this.controller.switchToVideoEntry(entry);
              }
            })
        }

        // 播放速度
        Text(this.vm.playbackSpeed + 'x')
          .fontSize(16)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Medium)
          .bindMenu(this.SpeedMenu())
      }
    }
    .width('100%')
    // 顶部間距策略：
    // 竖屏——VideoPlayer 在 statusBarHeight 占位下方，ctrlVPad 保证视觉平衡
    // 横屏全屏——从屏幕物理顶部开始，额外加 statusBarHeight 避开刘海
    .padding({
      left: this.ctrlHPad,
      right: this.ctrlHPad,
      top: this.isFullLandscapeScreen
           ? this.statusBarHeight + this.ctrlVPad
           : this.ctrlVPad,
      bottom: this.ctrlVPad
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
    Row({ space: 8 }) {
      // 播放/暂停按鈕：正在播放或缓冲中时显示暂停图标，其他状态显示播放图标
      SymbolGlyph(this.vm.isPlaying ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
        .fontSize(24).width(24).height(24)
        .fontColor([Color.White])
        .opacity(this.vm.isReady && this.hasStreams ? 1 : 0.4)
        .enabled(this.vm.isReady && this.hasStreams && !this.vm.isBuffering)
        .onClick(() => this.togglePlayback())

      Text(secondToTime(Math.floor(
        this.isSliderDragging ? this.sliderDragValue
          : this.isGestureSeek ? this.gestureSeekTime
          : this.currentTime
      )))
        .fontColor(Color.White).fontSize(13).width(48).textAlign(TextAlign.Center)
        .visibility(this.curSource.isLive ? Visibility.None : Visibility.Visible)

      if (this.curSource.isLive) {
        Row({ space: 6 }) {
          Circle({ width: 8, height: 8 }).fill('#FF3B30')
          Text('LIVE')
            .fontColor(Color.White).fontSize(13).fontWeight(FontWeight.Medium)
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Stack({ alignContent: Alignment.Start }) {
          // 轨道底层：透明 Slider 提供轨道几何（起点缩进、高度等），仅用于对齐
          Slider({ value: 0, max: 100, style: this.sliderStyle })
            .width('100%')
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
            .width('100%').trackColor(Color.Transparent).selectedColor(Color.White)
            .trackThickness(this.trackThicknessSize).enabled(!!(this.vm.isReady && this.hasStreams))
            .onChange((value: number, mode: SliderChangeMode) => this.sliderOnchange(value, mode))
        }.layoutWeight(1)
      }

      Text(secondToTime(Math.floor(this.durationTime)))
        .fontColor('#AAFFFFFF').fontSize(13).width(48).textAlign(TextAlign.Center)
        .visibility(this.curSource.isLive ? Visibility.None : Visibility.Visible)

      // 全屏按鈕 — fontSize 统一用 vp，移除冲突的 height(24)限制
      SymbolGlyph(this.isFullLandscapeScreen ? $r('sys.symbol.arrow_down_right_and_arrow_up_left') : $r('sys.symbol.arrow_up_left_and_arrow_down_right'))
        .fontSize(24).width(24).height(24)
        .fontColor([Color.White])
        .onClick(() => { this.onFullScreenClick?.(!this.isFullLandscapeScreen); })
    }
    .width('100%')
    // 底部間距策略：
    // 竖屏——ctrlVPad 保证进度条不紧贴视频帧底边，与信息栏不重叠
    // 横屏全屏——额外加 navBarHeight 避开导航条
    .padding({
      left: this.ctrlHPad,
      right: this.ctrlHPad,
      bottom: this.isFullLandscapeScreen
              ? Math.max(this.ctrlVPad, this.navBarHeight + this.ctrlVPad)
              : this.ctrlVPad
    })
    .linearGradient({ direction: GradientDirection.Bottom, colors: [['#00000000', 0.0], ['#66000000', 1.0]] })
  }

  private sliderOnchange(value: number, mode: SliderChangeMode) {
    switch (mode) {
      case SliderChangeMode.Begin:
        this.isSliderDragging = true;
        this.sliderDragValue = this.currentTime; // 初始化为当前位置
        this.trackThicknessSize = CommonConstants.TRACK_SIZE_MAX;
        this.sliderStyle = SliderStyle.InSet;
        this.scheduleHideControls();
        break;
      case SliderChangeMode.Moving:
        this.sliderDragValue = value; // 同步更新本地值，立即反映到 UI
        this.isSliderDragging = true;
        this.trackThicknessSize = CommonConstants.TRACK_SIZE_MAX;
        this.sliderStyle = SliderStyle.InSet;
        // Moving期间仅更新UI，不发送seek命令
        break;
      case SliderChangeMode.End:
        // 清除防抖定时器，立即发送最终seek
        if (this.sliderChangeDebounceTimer >= 0) {
          clearTimeout(this.sliderChangeDebounceTimer);
          this.sliderChangeDebounceTimer = -1;
        }
        // 使用快速seek模式（keyframe）提升响应速度
        this.controller.syncSeekFast(value * 1000);
        this.isSliderDragging = false;
        this.sliderDragValue = value;
        this.trackThicknessSize = CommonConstants.TRACK_SIZE_MIN;
        this.sliderStyle = SliderStyle.NONE;
        break;
    }
  }

  aboutToDisappear(): void {
    this.controller.removeStateListener(this.keepScreenListener);
    this.controller.removeStateListener(this.pipSyncListener);
    this.envService.release();
    this.controller.unsubscribeProgress(this.progressListener);
    this.controller.unsubscribeEnded(this.onEnded);
    this.controller.removeErrorListener(this.errorListener);
    this.controller.removeWaitingForBufferListener(this.waitingForBufferListener);
    this.controller.removeSeekableRangesListener(this.seekableRangesListener);
    this.clearHideTimer();
    clearTimeout(this.volHideTimerId);
    clearTimeout(this.brightnessHideTimerId);
    clearTimeout(this.forwardHintTimerId);
    clearTimeout(this.backwardHintTimerId);
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

class PiPPlayPauseSyncListener implements StateChangeListener {
  private readonly owner: VideoPlayer;
  constructor(owner: VideoPlayer) {
    this.owner = owner;
  }
  onStateChange(_from: PlayerState, to: PlayerState): void {
    this.owner._onPiPStateChanged(to);
  }
}
