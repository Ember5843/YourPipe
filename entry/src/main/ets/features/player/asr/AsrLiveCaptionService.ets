import { worker, MessageEvents, ErrorEvent } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { AvPlayerController } from 'mediaservice';
import { AppLog } from '../../../common/AppLog';
import { AsrModelManager, AsrModelPaths, AsrModelStatus } from './AsrModelManager';
import { AsrCue, asrTrackKey, buildAsrVtt } from './AsrVtt';

// [DISABLED] P3 实时 ASR 依赖的 MPV PCM tap 已随播放器回退（vendored libmpv
// 回到 0.5.9）移除。本服务的 tap 挂接/回调均已注释；重新启用需要先恢复
// libmpv_napi 的 asrtap 支持。此处仅保留类型形状以维持代码可编译。
interface AudioTapChunk {
  ptsMs: number;
  samples: Float32Array;
  flags: number;
}

const logger = AppLog.getInstance('AsrLiveCaption');

export type AsrLiveState = 'idle' | 'preparing' | 'running' | 'stopped';

export interface AsrLiveProgress {
  /** model = 模型下载中（percent 有效）；live = 实时识别中（无百分比） */
  phase: 'model' | 'live';
  percent: number;
}

/** worker → 宿主消息（与 AsrStreamingWorker.ets 协议一致） */
interface WorkerMsg {
  type: string;
  text?: string;
  endPtsMs?: number;
  message?: string;
}

/**
 * 实时 ASR 字幕（P3 live，真流式）：消费播放器 PCM tap（16kHz mono float32，
 * ~200ms 块，pts 基于媒体时间轴），逐块转发给 AsrStreamingWorker（常驻 worker
 * 线程持有 sherpa OnlineRecognizer + 流式 zipformer 中英双语模型）。
 * worker 端点检测出 final（一句定稿，提交为 cue）；未定点期间回 partial
 * （当前句快照），宿主以临时 cue 原地刷新（节流 ≥400ms），观感为逐字生长。
 * 只显示识别原文，不做翻译（翻译需求由 P0 tlang 官方自动翻译轨承担）。
 * 结果仅驻留内存，不落盘。
 * 停止条件：用户再次点击菜单项 / 切换或关闭字幕轨 / PlayerSession 重置
 * （源切换、页面退出）→ stop()。
 */
export class AsrLiveCaptionService {
  /** worker 模型加载（首次 ~190MB int8）超时 */
  private static readonly INIT_TIMEOUT_MS: number = 20000;
  /** partial 临时 cue 上屏节流间隔 */
  private static readonly PARTIAL_APPLY_INTERVAL_MS: number = 400;

  private static instance: AsrLiveCaptionService | null = null;

  static getInstance(): AsrLiveCaptionService {
    if (!AsrLiveCaptionService.instance) {
      AsrLiveCaptionService.instance = new AsrLiveCaptionService();
    }
    return AsrLiveCaptionService.instance;
  }

  /** 清数据接线：删除历史批量路径遗留的识别缓存目录（实时路径不落盘）。 */
  static clearCaches(): void {
    try {
      const ctx = AppStorage.get<common.UIAbilityContext>('context');
      if (!ctx) {
        return;
      }
      const dir = `${ctx.cacheDir}/asr_caption`;
      if (fileIo.accessSync(dir)) {
        fileIo.rmdirSync(dir);
      }
    } catch (e) {
      logger.warn(`clearCaches failed: ${(e as Error).message || e}`);
    }
  }

  private state: AsrLiveState = 'idle';
  private videoId: string = '';
  private controller: AvPlayerController | null = null;
  private progress: AsrLiveProgress | null = null;
  private listeners: Array<(p: AsrLiveProgress | null) => void> = [];
  private errorListeners: Array<(err: string) => void> = [];

  // 流式识别状态
  private asrWorker: worker.ThreadWorker | null = null;
  private initResolve: ((ok: boolean) => void) | null = null;
  private initTimer: number = -1;
  /** 当前句起始 pts（媒体时间轴毫秒）；-1 = 句边界未定（首块到达时锚定） */
  private sentenceStartPtsMs: number = -1;
  private tentativeCue: AsrCue | null = null;
  private lastPartialApplyAt: number = 0;
  /** 上次实际推给播放器的 VTT，内容未变时跳过重推（防 overlay 无谓重渲染） */
  private lastAppliedVtt: string = '';
  private cues: AsrCue[] = [];

  getState(): AsrLiveState {
    return this.state;
  }

  isActive(): boolean {
    return this.state === 'preparing' || this.state === 'running';
  }

  getProgress(): AsrLiveProgress | null {
    return this.progress;
  }

  addProgressListener(cb: (p: AsrLiveProgress | null) => void): void {
    this.listeners.push(cb);
  }

  removeProgressListener(cb: (p: AsrLiveProgress | null) => void): void {
    this.listeners = this.listeners.filter((l) => l !== cb);
  }

  /** 识别失败（worker 运行异常）通知：UI 据此 toast。 */
  addErrorListener(cb: (err: string) => void): void {
    this.errorListeners.push(cb);
  }

  removeErrorListener(cb: (err: string) => void): void {
    this.errorListeners = this.errorListeners.filter((l) => l !== cb);
  }

  /**
   * 启动实时识别：模型就绪（必要时先下载，进度经 progress listener 上报）→
   * 拉起识别 worker（加载模型）→ 挂 PCM tap。返回 false = 启动失败，UI 可 toast。
   */
  async start(videoId: string, controller: AvPlayerController): Promise<boolean> {
    if (this.isActive()) {
      logger.warn(`live asr start ignored: busy state=${this.state} video=${this.videoId}`);
      return false;
    }
    this.videoId = videoId;
    this.controller = controller;
    this.cues = [];
    this.resetStreamState();
    this.setState('preparing');
    logger.info(`live asr start video=${videoId}`);
    try {
      // 1. 模型（复用 AsrModelManager 的 ensure/download，进度经 progress listener 上报）
      let paths = AsrModelManager.getInstance().getModelPaths();
      if (!paths) {
        this.setProgress({ phase: 'model', percent: 0 });
        const mgr = AsrModelManager.getInstance();
        const relay = (status: AsrModelStatus, percent: number): void => {
          if (status === 'downloading') {
            this.setProgress({ phase: 'model', percent: percent });
          }
        };
        mgr.addListener(relay);
        try {
          let modelOk: boolean;
          if (mgr.getStatus() === 'downloading') {
            // 已有在途下载：附着等待而不是报错
            modelOk = await this.waitModelDownload(mgr);
          } else {
            modelOk = await mgr.download();
          }
          if (this.state !== 'preparing') {
            return false; // 下载期间被 stop()
          }
          if (!modelOk) {
            throw new Error('model download failed');
          }
        } finally {
          mgr.removeListener(relay);
        }
        paths = AsrModelManager.getInstance().getModelPaths();
        if (!paths) {
          throw new Error('model missing after download');
        }
      }

      // 2. 拉起识别 worker（模型加载在 worker 线程内完成，句柄不跨线程）
      const workerOk = await this.spawnWorker(paths);
      if (this.state !== 'preparing') {
        return false; // init 期间被 stop()
      }
      if (!workerOk) {
        throw new Error('asr worker init failed');
      }

      // 3. 挂 PCM tap —— [DISABLED] tap 已随播放器回退移除（见文件头注释）。
      // controller.setAudioTapCallback((chunk: AudioTapChunk) => this.onPcm(chunk));
      // controller.enableAudioTap();
      if (this.state !== 'preparing') {
        this.teardownTap();
        return false; // 启动尾段被 stop()
      }
      this.setState('running');
      // 立即选中 asr:// 轨（占位空 VTT）：菜单勾选项随 currentSubtitleUrl 即时
      // 更新；首个 partial/final 出来后以增量 cue 覆盖
      controller.switchSubtitleText(asrTrackKey(videoId), 'WEBVTT\n');
      this.setProgress({ phase: 'live', percent: 0 });
      logger.info(`live asr running video=${videoId}`);
      return true;
    } catch (e) {
      const err = e as Error;
      logger.error(`live asr start failed video=${videoId}: ${err.message || String(e)}`);
      this.failStop();
      return false;
    }
  }

  /** 停止（幂等）：断 tap、终止 worker、清状态。 */
  stop(): void {
    if (!this.isActive()) {
      return;
    }
    logger.info(`live asr stop video=${this.videoId} state=${this.state} cues=${this.cues.length}`);
    if (this.state === 'preparing') {
      // 模型下载不取消会卡在 downloading，后续任务全部秒失败
      AsrModelManager.getInstance().cancelDownload();
    }
    this.teardownTap();
    this.teardownWorker();
    this.resetStreamState();
    this.cues = [];
    this.controller = null;
    this.setState('stopped');
    this.setProgress(null);
  }

  // ── PCM tap → worker ──

  private onPcm(chunk: AudioTapChunk): void {
    if (this.state !== 'running' || !this.asrWorker) {
      return;
    }
    if ((chunk.flags & 1) !== 0) {
      // DISCONTINUITY（seek/reset）：worker 流状态与本地句锚点一起重置；
      // 已提交 cue 按媒体时间轴锚定，对同一视频依然有效，保留
      this.asrWorker.postMessage({ cmd: 'resetStream' });
      this.resetStreamState();
      this.applyCues();
      return;
    }
    if ((chunk.flags & 2) !== 0) {
      // EOF：冲刷残余音频，尽量出最后一次 final
      this.asrWorker.postMessage({ cmd: 'flush', endPtsMs: chunk.ptsMs });
      return;
    }
    if (chunk.samples.length === 0) {
      return;
    }
    if (this.sentenceStartPtsMs < 0) {
      this.sentenceStartPtsMs = chunk.ptsMs;
    }
    // 拷贝到独立 ArrayBuffer 再跨线程传递（native 侧缓冲的所有权不做假设）
    const buf = new ArrayBuffer(chunk.samples.length * 4);
    new Float32Array(buf).set(chunk.samples);
    this.asrWorker.postMessage({ cmd: 'feed', samples: buf, endPtsMs: chunk.ptsMs });
  }

  // ── worker 生命周期与消息 ──

  private spawnWorker(paths: AsrModelPaths): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      let w: worker.ThreadWorker;
      try {
        w = new worker.ThreadWorker('../../../workers/AsrStreamingWorker.ets');
      } catch (e) {
        logger.error(`asr worker spawn failed: ${(e as Error).message || e}`);
        resolve(false);
        return;
      }
      this.asrWorker = w;
      this.initResolve = resolve;
      w.onmessage = (e: MessageEvents): void => {
        this.onWorkerMessage(e.data as WorkerMsg);
      };
      w.onerror = (err: ErrorEvent): void => {
        logger.error(`asr worker onerror: ${err.message}`);
        this.onWorkerError(`worker: ${err.message}`);
      };
      this.initTimer = setTimeout(() => {
        this.initTimer = -1;
        logger.error(`asr worker init timeout after ${AsrLiveCaptionService.INIT_TIMEOUT_MS}ms`);
        this.resolveInit(false);
      }, AsrLiveCaptionService.INIT_TIMEOUT_MS);
      w.postMessage({
        cmd: 'init',
        encoder: paths.encoder,
        decoder: paths.decoder,
        joiner: paths.joiner,
        tokens: paths.tokens
      });
      logger.debug('asr worker init posted');
    });
  }

  private resolveInit(ok: boolean): void {
    if (this.initTimer >= 0) {
      clearTimeout(this.initTimer);
      this.initTimer = -1;
    }
    const resolve = this.initResolve;
    this.initResolve = null;
    if (resolve) {
      resolve(ok);
    }
  }

  private onWorkerMessage(msg: WorkerMsg): void {
    if (msg.type === 'ready') {
      logger.info(`asr worker ready video=${this.videoId}`);
      this.resolveInit(true);
      return;
    }
    if (msg.type === 'error') {
      this.onWorkerError(msg.message || 'unknown');
      return;
    }
    if (this.state !== 'running') {
      return; // stop()/restart 后迟到的 partial/final 直接丢弃
    }
    const endPtsMs = msg.endPtsMs ?? -1;
    if (msg.type === 'final') {
      const startMs = this.sentenceStartPtsMs >= 0 ? this.sentenceStartPtsMs : endPtsMs;
      const cue: AsrCue = { s: Math.round(startMs), e: Math.round(endPtsMs), t: (msg.text ?? '').trim() };
      if (cue.t.length === 0) {
        return;
      }
      this.cues.push(cue);
      this.sentenceStartPtsMs = -1;
      this.tentativeCue = null;
      this.applyCues();
      logger.debug(`live asr final video=${this.videoId} cues=${this.cues.length} s=${cue.s} e=${cue.e}`);
      return;
    }
    if (msg.type === 'partial') {
      const text = (msg.text ?? '').trim();
      if (text.length === 0) {
        return; // 句首静音/噪声：不产生空字幕抖动
      }
      const startMs = this.sentenceStartPtsMs >= 0 ? this.sentenceStartPtsMs : endPtsMs;
      this.tentativeCue = { s: Math.round(startMs), e: Math.round(endPtsMs), t: text };
      const now = Date.now();
      if (now - this.lastPartialApplyAt >= AsrLiveCaptionService.PARTIAL_APPLY_INTERVAL_MS) {
        this.lastPartialApplyAt = now;
        this.applyCues();
      }
    }
  }

  private onWorkerError(reason: string): void {
    if (this.state === 'preparing') {
      logger.error(`asr worker init failed video=${this.videoId}: ${reason}`);
      this.resolveInit(false);
      return;
    }
    if (this.state !== 'running') {
      return;
    }
    logger.error(`live asr worker error video=${this.videoId}: ${reason}`);
    this.failStop();
    // worker 失败发生在 start() 返回之后，经 error listener 通知 UI toast
    for (const cb of this.errorListeners) {
      try {
        cb(reason);
      } catch (_e) {
        // 监听器异常不影响状态机
      }
    }
  }

  /** 已提交 cue + 当前临时 cue（如有）合成 VTT 上屏；内容未变时跳过重推。 */
  private applyCues(): void {
    const display: AsrCue[] = this.tentativeCue ? this.cues.concat([this.tentativeCue]) : this.cues;
    const vtt = buildAsrVtt(display);
    if (vtt === this.lastAppliedVtt) {
      return;
    }
    this.lastAppliedVtt = vtt;
    try {
      this.controller?.switchSubtitleText(asrTrackKey(this.videoId), vtt);
    } catch (e) {
      logger.warn(`live asr apply cues failed: ${(e as Error).message || e}`);
    }
  }

  private resetStreamState(): void {
    this.sentenceStartPtsMs = -1;
    this.tentativeCue = null;
    this.lastPartialApplyAt = 0;
    this.lastAppliedVtt = '';
  }

  private teardownWorker(): void {
    this.resolveInit(false); // init 等待中的 promise 必须释放，避免悬挂
    const w = this.asrWorker;
    this.asrWorker = null;
    if (w) {
      try {
        w.terminate();
      } catch (e) {
        logger.warn(`asr worker terminate failed: ${(e as Error).message || e}`);
      }
    }
  }

  // ── 内部实现 ──

  private failStop(): void {
    this.teardownTap();
    this.teardownWorker();
    // 失败时回退字幕选中态（此时当前轨必为 asr:// 或已关闭；切到别的字幕轨会先 stop 本服务）
    try {
      this.controller?.switchSubtitle('');
    } catch (e) {
      logger.warn(`live asr revert subtitle failed: ${(e as Error).message || e}`);
    }
    this.resetStreamState();
    this.cues = [];
    this.controller = null;
    this.setState('stopped');
    this.setProgress(null);
  }

  private teardownTap(): void {
    // [DISABLED] PCM tap 已随播放器回退移除，无底层资源需要释放。
    // 保留空实现以维持 P3 代码结构可编译。
  }

  /** 附着到在途模型下载：轮询状态直到 ready/not_downloaded，期间响应 stop。 */
  private async waitModelDownload(mgr: AsrModelManager): Promise<boolean> {
    while (mgr.getStatus() === 'downloading') {
      if (this.state !== 'preparing') {
        mgr.cancelDownload();
        return false;
      }
      await new Promise<void>((r) => setTimeout(r, 500));
    }
    return mgr.getStatus() === 'ready';
  }

  private setState(state: AsrLiveState): void {
    if (this.state === state) {
      return;
    }
    logger.info(`live asr state ${this.state} -> ${state} video=${this.videoId}`);
    this.state = state;
  }

  private setProgress(p: AsrLiveProgress | null): void {
    this.progress = p;
    for (const cb of this.listeners) {
      try {
        cb(p);
      } catch (_e) {
        // 监听器异常不影响任务
      }
    }
  }
}
