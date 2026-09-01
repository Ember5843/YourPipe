import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { common } from '@kit.AbilityKit';
import { AvPlayerController, parseVttSubtitles, SubtitleCue, SubtitleTrack } from 'mediaservice';
import { HttpDownloader } from 'youtube_core';
import { AppLog } from '../../../common/AppLog';
import { LlmTranslateConfig } from '../../../common/LlmTranslateConfig';
import { TranslationService } from '../../../common/TranslationService';
import { LlmClient } from './LlmClient';

const logger = AppLog.getInstance('SubtitleTranslationService');

export interface SubtitleTranslateProgress {
  doneBatches: number;
  totalBatches: number;
  failedBatches: number;
}

export interface SubtitleTranslateResult {
  ok: boolean;
  partial: boolean;
  fromCache: boolean;
  cancelled: boolean;
  error?: string;
}

interface CueTranslation {
  s: number;
  e: number;
  o: string;
  t: string;
}

interface CachedTranslatedTrack {
  v: number;
  cues: CueTranslation[];
}

interface TranslateBatch {
  startIndex: number;
  texts: string[];
}

const MAX_BATCH_CUES: number = 50;
const GTX_BATCH_CHARS: number = 1200;
const LLM_BATCH_CHARS: number = 3000;
const MEM_CACHE_MAX: number = 8;

/**
 * AI 字幕翻译调度（P2）：已有字幕轨 → 目标语言 cue 列表 → 播放 overlay。
 * 引擎：gtx（Google 免费端点，零配置）/ llm（用户自带 key 的 OpenAI 兼容
 * 端点）。整轨批量非流式：源轨下载 → 分批翻译（并发 2、批级重试一次）→
 * 组装 VTT → AvPlayerController.switchSubtitleText 应用。
 * 缓存：内存 LRU + cacheDir/ai_subtitle/<sha256>.json（仅完整成功才落盘，
 * 进"清除全部数据"，不进"恢复默认设置"）。
 */
export class SubtitleTranslationService {
  private static instance: SubtitleTranslationService | null = null;

  static getInstance(): SubtitleTranslationService {
    if (!SubtitleTranslationService.instance) {
      SubtitleTranslationService.instance = new SubtitleTranslationService();
    }
    return SubtitleTranslationService.instance;
  }

  private applyGeneration: number = 0;
  private running: boolean = false;
  private cancelled: boolean = false;
  private progress: SubtitleTranslateProgress | null = null;
  private progressListeners: Array<(p: SubtitleTranslateProgress | null) => void> = [];
  private memCache: Map<string, CueTranslation[]> = new Map();

  isRunning(): boolean {
    return this.running;
  }

  getProgress(): SubtitleTranslateProgress | null {
    return this.progress;
  }

  addProgressListener(cb: (p: SubtitleTranslateProgress | null) => void): void {
    this.progressListeners.push(cb);
  }

  removeProgressListener(cb: (p: SubtitleTranslateProgress | null) => void): void {
    this.progressListeners = this.progressListeners.filter((l) => l !== cb);
  }

  /** 中止当前任务：不应用、不写缓存、不作废缓存中已有内容。 */
  cancel(): void {
    if (!this.running) {
      return;
    }
    this.cancelled = true;
    this.applyGeneration++;
    logger.info('translate task cancelled by user');
  }

  /** 菜单/自动选轨共用的 trackKey（占用 currentSubtitleUrl 参与选中态比较）。 */
  static trackKey(videoId: string, targetLang: string): string {
    return `ai://${videoId}/${encodeURIComponent(targetLang)}`;
  }

  /**
   * 翻译并应用。切轨/切视频/取消都会作废旧任务的应用结果；完整跑完的任务
   * 无论是否仍被应用都会写入缓存。
   */
  async translateAndApply(
    videoId: string,
    tracks: SubtitleTrack[],
    currentSubtitleUrl: string,
    controller: AvPlayerController
  ): Promise<SubtitleTranslateResult> {
    const cfg = LlmTranslateConfig.get();
    const target = TranslationService.targetLanguage();
    const source = this.pickSourceTrack(tracks, currentSubtitleUrl);
    if (!source) {
      return { ok: false, partial: false, fromCache: false, cancelled: false, error: 'no translatable source track' };
    }
    if (cfg.engine === 'llm' && !cfg.isLlmReady()) {
      return { ok: false, partial: false, fromCache: false, cancelled: false, error: 'llm not configured' };
    }

    const myGen = ++this.applyGeneration;
    this.running = true;
    this.cancelled = false;
    const startedAt = Date.now();
    try {
      const cacheKey = await this.cacheKey(videoId, source.url, target, cfg);
      logger.info(`translate start video=${videoId} src=${source.languageCode} dst=${target} engine=${cfg.engine}`);

      // 1. 缓存命中：直接组装应用，不碰网络
      let cached = this.memCache.get(cacheKey) ?? await this.readDiskCache(cacheKey);
      if (cached) {
        if (this.isApplyValid(myGen)) {
          this.applyCues(controller, videoId, target, cached, cfg.bilingual);
        }
        logger.info(`translate done (cache) video=${videoId} cues=${cached.length}`);
        return { ok: true, partial: false, fromCache: true, cancelled: false };
      }

      // 2. 拉源轨 → 解析 cue
      const vttText = await this.fetchText(source.url);
      const cues = parseVttSubtitles(vttText);
      if (cues.length === 0) {
        throw new Error('source track has no cues');
      }

      // 3. 分批翻译
      const batches = this.splitBatches(cues, cfg.engine === 'llm' ? LLM_BATCH_CHARS : GTX_BATCH_CHARS);
      this.setProgress(myGen, { doneBatches: 0, totalBatches: batches.length, failedBatches: 0 });
      const translations: string[] = new Array<string>(cues.length).fill('');
      let failedBatches = 0;
      let nextBatch = 0;
      const worker = async (): Promise<void> => {
        while (nextBatch < batches.length) {
          if (this.cancelled) {
            return;
          }
          const batch = batches[nextBatch++];
          const out = await this.translateBatchWithRetry(batch.texts, target, cfg);
          if (out === null) {
            failedBatches++;
            batch.texts.forEach((t: string, i: number) => {
              translations[batch.startIndex + i] = t;
            });
          } else {
            out.forEach((t: string, i: number) => {
              translations[batch.startIndex + i] = t;
            });
          }
          const cur = this.progress;
          if (cur) {
            this.setProgress(myGen, {
              doneBatches: cur.doneBatches + 1,
              totalBatches: cur.totalBatches,
              failedBatches: failedBatches
            });
          }
        }
      };
      await Promise.all([worker(), worker()]);
      if (this.cancelled) {
        return { ok: false, partial: false, fromCache: false, cancelled: true };
      }

      // 4. 组装 + 缓存（仅完整成功落盘，部分失败的任务重试时可整体重做）
      const merged: CueTranslation[] = cues.map((cue: SubtitleCue, i: number): CueTranslation => ({
        s: cue.startMs,
        e: cue.endMs,
        o: cue.text,
        t: translations[i].length > 0 ? translations[i] : cue.text
      }));
      if (failedBatches === 0) {
        this.putMemCache(cacheKey, merged);
        this.writeDiskCache(cacheKey, merged);
      }

      // 5. 应用（任务期间发生切轨/切视频/取消则丢弃）
      if (this.isApplyValid(myGen)) {
        this.applyCues(controller, videoId, target, merged, cfg.bilingual);
      }
      logger.info(`translate done video=${videoId} cues=${merged.length} batches=${batches.length} failed=${failedBatches} elapsed=${Date.now() - startedAt}ms`);
      return { ok: true, partial: failedBatches > 0, fromCache: false, cancelled: false };
    } catch (e) {
      const err = e as Error;
      logger.warn(`translate failed video=${videoId}: ${err.message || String(e)}`);
      return { ok: false, partial: false, fromCache: false, cancelled: this.cancelled, error: err.message || String(e) };
    } finally {
      if (myGen === this.applyGeneration || this.cancelled) {
        this.running = false;
        this.setProgress(myGen, null);
      }
    }
  }

  /** 清数据接线：删除磁盘缓存目录 + 内存缓存。 */
  static clearPersistentCache(): void {
    SubtitleTranslationService.getInstance().memCache.clear();
    try {
      const ctx = AppStorage.get<common.UIAbilityContext>('context');
      if (!ctx) {
        return;
      }
      const dir = `${ctx.cacheDir}/ai_subtitle`;
      if (fileIo.accessSync(dir)) {
        fileIo.rmdirSync(dir);
      }
    } catch (e) {
      logger.warn(`clearPersistentCache failed: ${(e as Error).message || e}`);
    }
  }

  private isApplyValid(myGen: number): boolean {
    return myGen === this.applyGeneration && !this.cancelled;
  }

  private applyCues(
    controller: AvPlayerController,
    videoId: string,
    target: string,
    cues: CueTranslation[],
    bilingual: boolean
  ): void {
    controller.switchSubtitleText(
      SubtitleTranslationService.trackKey(videoId, target),
      this.buildVtt(cues, bilingual)
    );
  }

  private pickSourceTrack(tracks: SubtitleTrack[], currentSubtitleUrl: string): SubtitleTrack | null {
    const real = tracks.filter((t: SubtitleTrack) => !t.isAutoTranslated);
    if (real.length === 0) {
      return null;
    }
    return real.find((t: SubtitleTrack) => t.url === currentSubtitleUrl) ?? real[0];
  }

  private splitBatches(cues: SubtitleCue[], charBudget: number): TranslateBatch[] {
    const batches: TranslateBatch[] = [];
    let cur: string[] = [];
    let curChars = 0;
    let start = 0;
    cues.forEach((cue: SubtitleCue, i: number) => {
      if (cur.length > 0 && (curChars + cue.text.length > charBudget || cur.length >= MAX_BATCH_CUES)) {
        batches.push({ startIndex: start, texts: cur });
        start = i;
        cur = [];
        curChars = 0;
      }
      cur.push(cue.text);
      curChars += cue.text.length + 8;
    });
    if (cur.length > 0) {
      batches.push({ startIndex: start, texts: cur });
    }
    return batches;
  }

  /** 批级重试一次；两次都失败返回 null（调用方回填原文并记失败）。 */
  private async translateBatchWithRetry(
    texts: string[],
    target: string,
    cfg: LlmTranslateConfig
  ): Promise<string[] | null> {
    for (let attempt = 0; attempt < 2; attempt++) {
      if (this.cancelled) {
        return null;
      }
      try {
        if (cfg.engine === 'llm') {
          return await LlmClient.translateBatch(texts, target, cfg);
        }
        return await TranslationService.translateBatch(texts, target);
      } catch (e) {
        logger.warn(`batch translate attempt ${attempt + 1} failed: ${(e as Error).message || e}`);
      }
    }
    return null;
  }

  private buildVtt(cues: CueTranslation[], bilingual: boolean): string {
    const parts: string[] = ['WEBVTT'];
    for (const cue of cues) {
      const text = bilingual && cue.t !== cue.o ? `${cue.o}\n${cue.t}` : cue.t;
      parts.push(`${this.formatTs(cue.s)} --> ${this.formatTs(cue.e)}\n${text}`);
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

  private setProgress(myGen: number, p: SubtitleTranslateProgress | null): void {
    if (p !== null && myGen !== this.applyGeneration) {
      return;
    }
    this.progress = p;
    for (const cb of this.progressListeners) {
      try {
        cb(p);
      } catch (_e) {
        // 监听器异常不影响任务
      }
    }
  }

  private async cacheKey(
    videoId: string,
    srcUrl: string,
    target: string,
    cfg: LlmTranslateConfig
  ): Promise<string> {
    const raw = [videoId, srcUrl, target, cfg.engine, cfg.engine === 'llm' ? cfg.model : ''].join('|');
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new util.TextEncoder().encodeInto(raw) });
    const out = await md.digest();
    let hex = '';
    for (const b of out.data) {
      hex += b.toString(16).padStart(2, '0');
    }
    return hex;
  }

  private putMemCache(key: string, cues: CueTranslation[]): void {
    if (this.memCache.size >= MEM_CACHE_MAX) {
      const oldest = this.memCache.keys().next();
      if (!oldest.done) {
        this.memCache.delete(oldest.value);
      }
    }
    this.memCache.set(key, cues);
  }

  private cacheFilePath(key: string): string | null {
    const ctx = AppStorage.get<common.UIAbilityContext>('context');
    if (!ctx) {
      return null;
    }
    return `${ctx.cacheDir}/ai_subtitle/${key}.json`;
  }

  private async readDiskCache(key: string): Promise<CueTranslation[] | null> {
    const path = this.cacheFilePath(key);
    if (!path) {
      return null;
    }
    try {
      if (!fileIo.accessSync(path)) {
        return null;
      }
      const content = fileIo.readTextSync(path);
      const parsed = JSON.parse(content) as CachedTranslatedTrack;
      if (parsed.v === 1 && Array.isArray(parsed.cues) && parsed.cues.length > 0) {
        this.putMemCache(key, parsed.cues);
        return parsed.cues;
      }
    } catch (e) {
      logger.warn(`readDiskCache failed: ${(e as Error).message || e}`);
    }
    return null;
  }

  private writeDiskCache(key: string, cues: CueTranslation[]): void {
    const path = this.cacheFilePath(key);
    if (!path) {
      return;
    }
    try {
      const dir = path.substring(0, path.lastIndexOf('/'));
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const payload: CachedTranslatedTrack = { v: 1, cues: cues };
      const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, JSON.stringify(payload));
      fileIo.closeSync(file);
    } catch (e) {
      logger.warn(`writeDiskCache failed: ${(e as Error).message || e}`);
    }
  }

  private async fetchText(url: string): Promise<string> {
    const request = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.STRING,
        header: {
          'User-Agent': 'Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36',
          'Referer': 'https://www.youtube.com/'
        },
        connectTimeout: 8000,
        readTimeout: 15000
      };
      HttpDownloader.applyProxyToOptions(options, url);
      const response = await request.request(url, options);
      if (response.responseCode !== 200 || typeof response.result !== 'string' || response.result.length === 0) {
        throw new Error(`subtitle fetch failed (HTTP ${response.responseCode})`);
      }
      return response.result;
    } finally {
      request.destroy();
    }
  }
}
