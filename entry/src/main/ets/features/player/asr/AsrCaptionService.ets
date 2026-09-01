import { taskpool } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { AvPlayerController, StreamInfo } from 'mediaservice';
import { decodeAacToPcm16k } from 'asrengine';
import { HttpDownloader } from 'youtube_core';
import {
  OfflineRecognizer, OfflineRecognizerConfig, OfflineStream
} from 'sherpa_onnx';
import { AppLog } from '../../../common/AppLog';
import { AsrModelManager } from './AsrModelManager';

const logger = AppLog.getInstance('AsrCaptionService');

export type AsrPhase = 'model' | 'audio' | 'decode' | 'transcribe';

export interface AsrProgress {
  phase: AsrPhase;
  percent: number;
}

export interface AsrCue {
  s: number;
  e: number;
  t: string;
}

export interface AsrGenerateResult {
  ok: boolean;
  cancelled: boolean;
  fromCache: boolean;
  error?: string;
}

interface TranscribeTaskResult {
  cancelled: boolean;
  cues: AsrCue[];
}

/** task 进度消息（Task.sendData 上行） */
interface TranscribeProgressMsg {
  doneSamples: number;
  total: number;
  cues: AsrCue[];
}

/** 识别缓存文件格式 */
interface AsrCueCacheFile {
  v: number;
  cues: AsrCue[];
}

/**
 * taskpool 并发转写：在 worker 线程内创建 SenseVoice 识别器（句柄不可跨线程），
 * 30s 窗口滑动，逐窗口产出 cue 并经 Task.sendData 回报宿主线程做增量上屏。
 * 取消经 cancelFlagPath 标志文件协作（worker 每窗口检查一次）。
 */
@Concurrent
async function transcribePcm(
  modelPath: string,
  tokensPath: string,
  pcmPath: string,
  totalSamples: number,
  cancelFlagPath: string
): Promise<string> {
  // @Concurrent 只能使用局部变量/导入符号：采样率等常量全部内联
  const sampleRate = 16000;
  const windowSamples = 30 * sampleRate;
  const silenceRms = 0.0005;
  const config = new OfflineRecognizerConfig();
  config.featConfig.sampleRate = sampleRate;
  config.featConfig.featureDim = 80;
  config.modelConfig.senseVoice.model = modelPath;
  config.modelConfig.senseVoice.language = 'auto';
  config.modelConfig.senseVoice.useItn = true;
  config.modelConfig.tokens = tokensPath;
  config.modelConfig.numThreads = 2;
  config.modelConfig.debug = false;
  const recognizer = new OfflineRecognizer(config);

  const cues: AsrCue[] = [];
  const file = fileIo.openSync(pcmPath, fileIo.OpenMode.READ_ONLY);
  let done = 0;
  try {
    while (done < totalSamples) {
      if (fileIo.accessSync(cancelFlagPath)) {
        return JSON.stringify({ cancelled: true, cues: cues } as TranscribeTaskResult);
      }
      const n = Math.min(windowSamples, totalSamples - done);
      const buf = new ArrayBuffer(n * 4);
      const readLen = fileIo.readSync(file.fd, buf, { offset: done * 4 });
      if (readLen <= 0) {
        break;
      }
      const samples = new Float32Array(buf, 0, Math.floor(readLen / 4));
      // 静音粗判：RMS 过低直接跳过该窗口
      let energy = 0;
      for (let i = 0; i < samples.length; i += 16) {
        energy += samples[i] * samples[i];
      }
      const rms = Math.sqrt(energy / Math.ceil(samples.length / 16));
      if (rms >= silenceRms) {
        const stream: OfflineStream = recognizer.createStream();
        stream.acceptWaveform({ samples: samples, sampleRate: sampleRate });
        recognizer.decode(stream);
        const text = recognizer.getResult(stream).text.trim();
        if (text.length > 0) {
          cues.push({
            s: Math.round(done / sampleRate * 1000),
            e: Math.round((done + samples.length) / sampleRate * 1000),
            t: text
          });
        }
      }
      done += samples.length;
      taskpool.Task.sendData(JSON.stringify({ doneSamples: done, total: totalSamples, cues: cues }));
    }
  } finally {
    fileIo.closeSync(file);
  }
  return JSON.stringify({ cancelled: false, cues: cues } as TranscribeTaskResult);
}

/**
 * AI 生成字幕编排（P3）：无字幕轨视频 → 端侧 SenseVoice 识别 → overlay。
 * 流程：模型就绪检查（必要时先下载）→ 拉取音频轨（itag 140 优先）→
 * asrengine NDK 解码成 16kHz PCM → taskpool 边转边出 cue → 增量应用。
 * 识别结果按 videoId 缓存（cacheDir/asr_caption），进"清除全部数据"。
 * 不做自动触发：模型下载与转写开销大，仅在用户显式点击时进行。
 */
export class AsrCaptionService {
  private static instance: AsrCaptionService | null = null;

  static getInstance(): AsrCaptionService {
    if (!AsrCaptionService.instance) {
      AsrCaptionService.instance = new AsrCaptionService();
    }
    return AsrCaptionService.instance;
  }

  private running: boolean = false;
  private cancelled: boolean = false;
  private progress: AsrProgress | null = null;
  private listeners: Array<(p: AsrProgress | null) => void> = [];
  private activeTask: taskpool.Task | null = null;
  private httpRequest: http.HttpRequest | null = null;
  private activeVideoId: string = '';

  isRunning(): boolean {
    return this.running;
  }

  getProgress(): AsrProgress | null {
    return this.progress;
  }

  addProgressListener(cb: (p: AsrProgress | null) => void): void {
    this.listeners.push(cb);
  }

  removeProgressListener(cb: (p: AsrProgress | null) => void): void {
    this.listeners = this.listeners.filter((l) => l !== cb);
  }

  static trackKey(videoId: string): string {
    return `asr://${videoId}`;
  }

  async generateAndApply(
    videoId: string,
    streams: StreamInfo[],
    controller: AvPlayerController
  ): Promise<AsrGenerateResult> {
    if (this.running) {
      return { ok: false, cancelled: false, fromCache: false, error: 'busy' };
    }
    this.running = true;
    this.cancelled = false;
    this.activeVideoId = videoId;
    const startedAt = Date.now();
    try {
      // 0. 识别缓存命中：直接应用
      const cached = this.readCueCache(videoId);
      if (cached && cached.length > 0) {
        controller.switchSubtitleText(AsrCaptionService.trackKey(videoId), this.buildVtt(cached));
        logger.info(`asr caption applied from cache video=${videoId} cues=${cached.length}`);
        return { ok: true, cancelled: false, fromCache: true };
      }

      // 1. 模型
      let paths = AsrModelManager.getInstance().getModelPaths();
      if (!paths) {
        this.setProgress({ phase: 'model', percent: 0 });
        const mgr = AsrModelManager.getInstance();
        // 转发模型下载进度到菜单标签
        const relay = (status: string, percent: number): void => {
          if (status === 'downloading') {
            this.setProgress({ phase: 'model', percent: percent });
          }
        };
        mgr.addListener(relay);
        try {
          let modelOk: boolean;
          if (mgr.getStatus() === 'downloading') {
            // 已有在途下载（例如上次任务取消后模型下载仍在跑）：附着等待而不是报错
            modelOk = await this.waitModelDownload(mgr);
          } else {
            modelOk = await mgr.download();
          }
          if (this.cancelled) {
            return this.cancelResult();
          }
          if (!modelOk) {
            return { ok: false, cancelled: false, fromCache: false, error: 'model download failed' };
          }
        } finally {
          mgr.removeListener(relay);
        }
        paths = AsrModelManager.getInstance().getModelPaths();
        if (!paths) {
          return { ok: false, cancelled: false, fromCache: false, error: 'model missing after download' };
        }
      }

      // 2. 音频轨选择 + 下载
      const audio = this.pickAudioStream(streams);
      if (!audio) {
        return { ok: false, cancelled: false, fromCache: false, error: 'no_aac_audio_stream' };
      }
      this.setProgress({ phase: 'audio', percent: 0 });
      const audioPath = this.cachePath(`asr_audio_${videoId}.m4a`);
      await this.downloadToFile(audio.url, audioPath);
      if (this.cancelled) {
        return this.cancelResult();
      }

      // 3. NDK 解码 → 16kHz PCM 文件
      this.setProgress({ phase: 'decode', percent: 50 });
      const pcmPath = this.cachePath(`asr_pcm_${videoId}.f32`);
      const audioFile = fileIo.openSync(audioPath, fileIo.OpenMode.READ_ONLY);
      const audioSize = fileIo.statSync(audioPath).size;
      let totalSamples = 0;
      try {
        totalSamples = await decodeAacToPcm16k(audioFile.fd, 0, audioSize, pcmPath);
      } finally {
        fileIo.closeSync(audioFile);
      }
      if (this.cancelled) {
        return this.cancelResult();
      }
      if (totalSamples <= 0) {
        return { ok: false, cancelled: false, fromCache: false, error: 'decode produced no samples' };
      }

      // 4. 并发转写，边转边上屏
      this.setProgress({ phase: 'transcribe', percent: 0 });
      const cancelFlag = this.cachePath(`asr_cancel_${videoId}`);
      const task = new taskpool.Task(
        transcribePcm, paths.model, paths.tokens, pcmPath, totalSamples, cancelFlag);
      this.activeTask = task;
      task.onReceiveData((msg: string) => {
        if (typeof msg !== 'string') {
          return;
        }
        try {
          const p = JSON.parse(msg) as TranscribeProgressMsg;
          const percent = Math.min(99, Math.round(p.doneSamples / Math.max(1, p.total) * 100));
          this.setProgress({ phase: 'transcribe', percent: percent });
          if (!this.cancelled && p.cues.length > 0) {
            controller.switchSubtitleText(AsrCaptionService.trackKey(videoId), this.buildVtt(p.cues));
          }
        } catch (e) {
          logger.warn(`asr progress parse failed: ${(e as Error).message || e}`);
        }
      });
      const resultJson = await taskpool.execute(task);
      const result = JSON.parse(resultJson as string) as TranscribeTaskResult;
      this.activeTask = null;
      if (result.cancelled || this.cancelled) {
        return this.cancelResult();
      }

      // 5. 最终应用 + 落缓存 + 清理中间文件
      if (result.cues.length === 0) {
        return { ok: false, cancelled: false, fromCache: false, error: 'no speech recognized' };
      }
      controller.switchSubtitleText(AsrCaptionService.trackKey(videoId), this.buildVtt(result.cues));
      this.writeCueCache(videoId, result.cues);
      this.cleanupIntermediates(videoId);
      logger.info(`asr caption done video=${videoId} cues=${result.cues.length} elapsed=${Date.now() - startedAt}ms`);
      return { ok: true, cancelled: false, fromCache: false };
    } catch (e) {
      const err = e as Error;
      logger.error(`asr caption failed video=${videoId}: ${err.message || String(e)}`);
      return { ok: false, cancelled: this.cancelled, fromCache: false, error: err.message || String(e) };
    } finally {
      this.running = false;
      this.activeTask = null;
      this.httpRequest = null;
      this.setProgress(null);
      this.removeCancelFlag(videoId);
    }
  }

  /** 取消：中止下载/转写（转写经标志文件协作停止），不应用、不写缓存。 */
  cancel(): void {
    if (!this.running) {
      return;
    }
    this.cancelled = true;
    logger.info('asr caption cancelled by user');
    // 模型下载也要取消，否则其状态机会卡在 downloading，后续任务全部秒失败
    AsrModelManager.getInstance().cancelDownload();
    try {
      this.httpRequest?.destroy();
    } catch (_e) {
      // ignore
    }
    if (this.activeTask) {
      try {
        taskpool.cancel(this.activeTask);
      } catch (_e) {
        // 已在运行的 task 由标志文件协作停止
      }
      if (this.activeVideoId.length > 0) {
        this.touchCancelFlag(this.activeVideoId);
      }
    }
  }

  /** 清数据接线：删除识别缓存目录。 */
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

  // ── 内部实现 ──

  private cancelResult(): AsrGenerateResult {
    return { ok: false, cancelled: true, fromCache: false };
  }

  /** 附着到在途模型下载：轮询状态直到 ready/not_downloaded，期间响应取消。 */
  private async waitModelDownload(mgr: AsrModelManager): Promise<boolean> {
    while (mgr.getStatus() === 'downloading') {
      if (this.cancelled) {
        mgr.cancelDownload();
        return false;
      }
      await new Promise<void>((r) => setTimeout(r, 500));
    }
    return mgr.getStatus() === 'ready';
  }

  private pickAudioStream(streams: StreamInfo[]): StreamInfo | null {
    const audioOnly = streams.filter((s: StreamInfo) => s.hasAudio && !s.hasVideo && s.url && s.url.length > 0);
    // 优先 AAC/mp4（系统 NDK 可解）；SABR 流不带直链 URL，已被上面的 url 过滤排除
    return audioOnly.find((s: StreamInfo) => (s.mimeType || '').includes('audio/mp4') || s.itag === 140)
      ?? audioOnly.find((s: StreamInfo) => (s.mimeType || '').startsWith('audio/'))
      ?? null;
  }

  private downloadToFile(url: string, dest: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const request = http.createHttp();
      this.httpRequest = request;
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36',
          'Referer': 'https://www.youtube.com/'
        },
        connectTimeout: 10000,
        // 音频可能几十 MB，30s 对大视频/慢网必超时；放宽到 5min，足够 10min 视频音频。
        readTimeout: 300000
      };
      HttpDownloader.applyProxyToOptions(options, url);
      let file: fileIo.File | null = null;
      let settled = false;
      const fail = (msg: string): void => {
        if (settled) {
          return;
        }
        settled = true;
        try {
          if (file) {
            fileIo.closeSync(file);
          }
        } catch (_e) {
          // ignore
        }
        try {
          request.destroy();
        } catch (_e) {
          // ignore
        }
        reject(new Error(msg));
      };
      try {
        file = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      } catch (e) {
        fail(`open dest failed: ${(e as Error).message || e}`);
        return;
      }
      request.on('dataReceive', (data: ArrayBuffer) => {
        if (settled || this.cancelled) {
          return;
        }
        try {
          // fileIo.writeSync 只接受原始 ArrayBuffer，TypedArray 视图会报 Invalid arraybuffer。
          // 实测单次 writeSync 最多写入约 16KB，必须按 chunk 循环写入。
          const view = new Uint8Array(data);
          let offset = 0;
          while (offset < data.byteLength) {
            const end = Math.min(offset + 16384, data.byteLength);
            const chunk = view.subarray(offset, end);
            const copy = new ArrayBuffer(chunk.byteLength);
            new Uint8Array(copy).set(chunk);
            const written = fileIo.writeSync(file!.fd, copy);
            if (written <= 0) {
              throw new Error(`writeSync returned ${written}`);
            }
            offset += written;
          }
        } catch (e) {
          fail(`write failed: ${(e as Error).message || e}`);
        }
      });
      request.on('dataReceiveProgress', (data: http.DataReceiveProgressInfo) => {
        if (data.totalSize > 0) {
          this.setProgress({
            phase: 'audio',
            percent: Math.min(99, Math.round(data.receiveSize / data.totalSize * 100))
          });
        }
      });
      request.on('dataEnd', () => {
        if (settled) {
          return;
        }
        settled = true;
        try {
          fileIo.closeSync(file!);
        } catch (_e) {
          // ignore
        }
        request.destroy();
        this.httpRequest = null;
        if (this.cancelled) {
          reject(new Error('cancelled'));
        } else {
          resolve();
        }
      });
      request.requestInStream(url, options)
        .then((code: number) => {
          if (code !== 200 && code !== 206) {
            fail(`HTTP ${code}`);
          }
        })
        .catch((e: Error) => fail(e.message || 'request failed'));
    });
  }

  private cachePath(name: string): string {
    const ctx = AppStorage.get<common.UIAbilityContext>('context');
    if (!ctx) {
      throw new Error('no context');
    }
    return `${ctx.cacheDir}/${name}`;
  }

  private cueCachePath(videoId: string): string | null {
    const ctx = AppStorage.get<common.UIAbilityContext>('context');
    if (!ctx) {
      return null;
    }
    return `${ctx.cacheDir}/asr_caption/${videoId}.json`;
  }

  private readCueCache(videoId: string): AsrCue[] | null {
    const path = this.cueCachePath(videoId);
    if (!path) {
      return null;
    }
    try {
      if (!fileIo.accessSync(path)) {
        return null;
      }
      const parsed = JSON.parse(fileIo.readTextSync(path)) as AsrCueCacheFile;
      if (parsed.v === 1 && Array.isArray(parsed.cues)) {
        return parsed.cues;
      }
    } catch (e) {
      logger.warn(`readCueCache failed: ${(e as Error).message || e}`);
    }
    return null;
  }

  private writeCueCache(videoId: string, cues: AsrCue[]): void {
    const path = this.cueCachePath(videoId);
    if (!path) {
      return;
    }
    try {
      const dir = path.substring(0, path.lastIndexOf('/'));
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify({ v: 1, cues: cues }));
      fileIo.closeSync(file);
    } catch (e) {
      logger.warn(`writeCueCache failed: ${(e as Error).message || e}`);
    }
  }

  private cleanupIntermediates(videoId: string): void {
    for (const name of [`asr_audio_${videoId}.m4a`, `asr_pcm_${videoId}.f32`]) {
      try {
        const p = this.cachePath(name);
        if (fileIo.accessSync(p)) {
          fileIo.unlinkSync(p);
        }
      } catch (_e) {
        // ignore
      }
    }
  }

  private removeCancelFlag(videoId: string): void {
    try {
      const p = this.cachePath(`asr_cancel_${videoId}`);
      if (fileIo.accessSync(p)) {
        fileIo.unlinkSync(p);
      }
    } catch (_e) {
      // ignore
    }
  }

  private touchCancelFlag(videoId: string): void {
    try {
      const p = this.cachePath(`asr_cancel_${videoId}`);
      const file = fileIo.openSync(p, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE);
      fileIo.closeSync(file);
    } catch (_e) {
      // ignore
    }
  }

  private setProgress(p: AsrProgress | null): void {
    this.progress = p;
    for (const cb of this.listeners) {
      try {
        cb(p);
      } catch (_e) {
        // 监听器异常不影响任务
      }
    }
  }

  private buildVtt(cues: AsrCue[]): string {
    const parts: string[] = ['WEBVTT'];
    for (const cue of cues) {
      parts.push(`${this.formatTs(cue.s)} --> ${this.formatTs(cue.e)}\n${cue.t}`);
    }
    return parts.join('\n\n') + '\n';
  }

  private formatTs(ms: number): string {
    const h = Math.floor(ms / 3600000);
    const m = Math.floor((ms % 3600000) / 60000);
    const s = Math.floor((ms % 60000) / 1000);
    const milli = ms % 1000;
    return `${h.toString().padStart(2, '0')}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}.${milli.toString().padStart(3, '0')}`;
  }
}
