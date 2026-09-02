import { http } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { AppLog } from '../../../common/AppLog';
import { HttpDownloader } from 'youtube_core';

const logger = AppLog.getInstance('AsrModelManager');

export type AsrModelStatus = 'not_downloaded' | 'downloading' | 'ready';

export interface AsrModelPaths {
  encoder: string;
  decoder: string;
  joiner: string;
  tokens: string;
}

interface ModelFileSpec {
  name: string;
  /** 用于就绪校验的最小字节数 */
  minBytes: number;
}

const REPO: string = 'csukuangfj/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20';
const FILES: ModelFileSpec[] = [
  { name: 'tokens.txt', minBytes: 50 * 1024 },
  { name: 'encoder-epoch-99-avg-1.int8.onnx', minBytes: 170 * 1024 * 1024 },
  { name: 'decoder-epoch-99-avg-1.int8.onnx', minBytes: 12 * 1024 * 1024 },
  { name: 'joiner-epoch-99-avg-1.int8.onnx', minBytes: 3 * 1024 * 1024 }
];
/** 旧版 SenseVoice 模型目录名（遗留 ~230MB），下载成功/删除模型时一并清理 */
const LEGACY_DIR_NAME: string = 'sensevoice';
/**
 * 模型下载源（按序尝试，任一成功即停）：
 * 1. 项目自有 GitHub Release `asr-models`（原始散文件，无需解压 tar.bz2）；
 * 2. huggingface 官方（需代理可达，YouTube 可用即通常可用）；
 * 3. hf-mirror（CN 兜底；注意其对 LFS 文件会 308 回源站，可能无效）。
 */
const BASE_URLS: string[] = [
  'https://github.com/Ember5843/YourPipe/releases/download/asr-models',
  `https://huggingface.co/${REPO}/resolve/main`,
  `https://hf-mirror.com/${REPO}/resolve/main`
];

/**
 * 端侧识别模型管理（P3）：sherpa-onnx 流式 zipformer 中英双语 int8
 * （encoder ~173MB + decoder ~12.5MB + joiner ~3MB + tokens，真流式亚秒 partial）。
 * 模型存 filesDir/asr_models/zipformer_bilingual —— 属可清理资产，进"清除全部数据"，
 * 不进"恢复默认设置"（不是配置）。旧版 SenseVoice 目录（sensevoice/）在新模型
 * 下载成功或删除模型时一并清理。
 */
export class AsrModelManager {
  private static instance: AsrModelManager | null = null;

  static getInstance(): AsrModelManager {
    if (!AsrModelManager.instance) {
      AsrModelManager.instance = new AsrModelManager();
    }
    return AsrModelManager.instance;
  }

  private status: AsrModelStatus = 'not_downloaded';
  private percent: number = 0;
  private cancelFlag: boolean = false;
  private listeners: Array<(status: AsrModelStatus, percent: number) => void> = [];
  private activeRequest: http.HttpRequest | null = null;
  /** 当前 fetchToFile 的幂等 settle 钩子，供 cancelDownload 确定性收尾。 */
  private activeSettle: ((error?: Error) => void) | null = null;
  /** 单文件下载总超时兜底（大模型文件看门狗）。 */
  private static readonly FETCH_TOTAL_TIMEOUT_MS: number = 5 * 60 * 1000;
  /** 停滞检测：超过该时长无任何接收进度即判定流已死。 */
  private static readonly FETCH_STALL_TIMEOUT_MS: number = 60 * 1000;
  /** 停滞检测轮询间隔。 */
  private static readonly FETCH_STALL_CHECK_MS: number = 15 * 1000;

  getStatus(): AsrModelStatus {
    if (this.status !== 'downloading') {
      this.status = this.filesReady() ? 'ready' : 'not_downloaded';
    }
    return this.status;
  }

  getPercent(): number {
    return this.percent;
  }

  addListener(cb: (status: AsrModelStatus, percent: number) => void): void {
    this.listeners.push(cb);
  }

  removeListener(cb: (status: AsrModelStatus, percent: number) => void): void {
    this.listeners = this.listeners.filter((l) => l !== cb);
  }

  getModelPaths(): AsrModelPaths | null {
    const dir = this.modelDir();
    if (!dir || !this.filesReady()) {
      return null;
    }
    return {
      encoder: `${dir}/encoder-epoch-99-avg-1.int8.onnx`,
      decoder: `${dir}/decoder-epoch-99-avg-1.int8.onnx`,
      joiner: `${dir}/joiner-epoch-99-avg-1.int8.onnx`,
      tokens: `${dir}/tokens.txt`
    };
  }

  /** 下载模型（顺序拉取 tokens + encoder/decoder/joiner，镜像故障切换）。已在下载中直接返回 false。 */
  async download(): Promise<boolean> {
    if (this.status === 'downloading') {
      logger.warn('download() called while already downloading');
      return false;
    }
    const dir = this.modelDir();
    if (!dir) {
      logger.error('download() aborted: no app context (modelDir null)');
      return false;
    }
    logger.info('ASR model download start');
    this.cancelFlag = false;
    this.setStatus('downloading', 0);
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      for (let f = 0; f < FILES.length; f++) {
        const spec = FILES[f];
        const dest = `${dir}/${spec.name}.part`;
        const ok = await this.downloadOne(spec, dest, f / FILES.length, 1 / FILES.length);
        if (this.cancelFlag) {
          this.cleanupPartial(dir);
          this.setStatus('not_downloaded', 0);
          return false;
        }
        if (!ok) {
          this.cleanupPartial(dir);
          this.setStatus('not_downloaded', 0);
          return false;
        }
        const finalPath = `${dir}/${spec.name}`;
        fileIo.renameSync(dest, finalPath);
        const size = this.verifyFileSize(finalPath, spec.minBytes, spec.name);
        if (size < spec.minBytes) {
          logger.warn(`ASR model file size check failed: name=${spec.name} size=${size} minBytes=${spec.minBytes}`);
          this.cleanupPartial(dir);
          this.setStatus('not_downloaded', 0);
          return false;
        }
      }
      if (!this.filesReady()) {
        logger.warn('ASR model filesReady() check failed after download');
        this.cleanupPartial(dir);
        this.setStatus('not_downloaded', 0);
        return false;
      }
      this.setStatus('ready', 100);
      this.removeLegacyModel();
      logger.info('ASR model ready');
      return true;
    } catch (e) {
      logger.error(`ASR model download failed: ${(e as Error).message || e}`);
      this.cleanupPartial(dir);
      this.setStatus('not_downloaded', 0);
      return false;
    }
  }

  cancelDownload(): void {
    this.cancelFlag = true;
    // 优先走活动下载的 settle 钩子：destroy() 之后 requestInStream/dataEnd
    // 可能都不再回调，必须由这里确定性地按"已取消"收尾 Promise。
    const settle = this.activeSettle;
    if (settle) {
      settle(new Error('cancelled'));
      return;
    }
    try {
      this.activeRequest?.destroy();
    } catch (_e) {
      // ignore
    }
  }

  deleteModel(): void {
    const dir = this.modelDir();
    if (dir && fileIo.accessSync(dir)) {
      try {
        fileIo.rmdirSync(dir);
      } catch (e) {
        logger.warn(`deleteModel failed: ${(e as Error).message || e}`);
      }
    }
    this.removeLegacyModel();
    this.setStatus('not_downloaded', 0);
  }

  /** 清数据接线：删除模型目录并重置状态。 */
  static clearAll(): void {
    AsrModelManager.getInstance().deleteModel();
  }

  private modelDir(): string | null {
    const ctx = AppStorage.get<common.UIAbilityContext>('context');
    if (!ctx) {
      return null;
    }
    return `${ctx.filesDir}/asr_models/zipformer_bilingual`;
  }

  /** 旧版 SenseVoice 目录（v0.5.x 遗留，新流式模型启用后不再使用）。 */
  private legacyModelDir(): string | null {
    const ctx = AppStorage.get<common.UIAbilityContext>('context');
    if (!ctx) {
      return null;
    }
    return `${ctx.filesDir}/asr_models/${LEGACY_DIR_NAME}`;
  }

  private removeLegacyModel(): void {
    const dir = this.legacyModelDir();
    if (dir && fileIo.accessSync(dir)) {
      try {
        fileIo.rmdirSync(dir);
        logger.info('legacy SenseVoice model dir removed');
      } catch (e) {
        logger.warn(`removeLegacyModel failed: ${(e as Error).message || e}`);
      }
    }
  }

  private filesReady(): boolean {
    const dir = this.modelDir();
    if (!dir) {
      return false;
    }
    for (const spec of FILES) {
      const path = `${dir}/${spec.name}`;
      try {
        if (!fileIo.accessSync(path)) {
          return false;
        }
        const stat = fileIo.statSync(path);
        logger.info(`ASR model file ready check: name=${spec.name} path=${path} size=${stat.size}`);
        if (stat.size < spec.minBytes) {
          return false;
        }
      } catch (_e) {
        return false;
      }
    }
    return true;
  }

  /** 校验单个文件落盘大小；返回实际字节数，异常或缺失返回 0。 */
  private verifyFileSize(path: string, minBytes: number, name: string): number {
    try {
      if (!fileIo.accessSync(path)) {
        logger.warn(`verifyFileSize: file missing path=${path} name=${name}`);
        return 0;
      }
      const stat = fileIo.statSync(path);
      if (stat.size < minBytes) {
        logger.warn(`verifyFileSize: file undersized name=${name} size=${stat.size} minBytes=${minBytes}`);
      }
      return stat.size;
    } catch (e) {
      logger.warn(`verifyFileSize: stat failed name=${name} error=${(e as Error).message || e}`);
      return 0;
    }
  }

  private async downloadOne(spec: ModelFileSpec, dest: string, base: number, span: number): Promise<boolean> {
    for (const baseUrl of BASE_URLS) {
      if (this.cancelFlag) {
        return false;
      }
      const url = `${baseUrl}/${spec.name}`;
      try {
        await this.fetchToFile(url, dest, base, span);
        // fetchToFile 可能因空 200/网络异常而"假成功"，必须按大小复核才能换下一镜像
        const size = this.verifyFileSize(dest, spec.minBytes, spec.name);
        if (size >= spec.minBytes) {
          return true;
        }
        logger.warn(`model file ${spec.name} from ${baseUrl} rejected by size check: size=${size} minBytes=${spec.minBytes}`);
      } catch (e) {
        logger.warn(`model file ${spec.name} failed from ${baseUrl}: ${(e as Error).message || e}`);
      }
    }
    return false;
  }

  private fetchToFile(url: string, dest: string, base: number, span: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const request = http.createHttp();
      this.activeRequest = request;
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 60000
      };
      HttpDownloader.applyProxyToOptions(options, url);
      let file: fileIo.File | null = null;
      let receivedBytes = 0;
      let httpCode = 0;
      let settled = false;
      let totalTimerId: number = -1;
      let stallTimerId: number = -1;
      let lastProgressAtMs: number = Date.now();
      try {
        file = fileIo.openSync(dest, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      } catch (e) {
        request.destroy();
        reject(new Error(`open dest failed: ${(e as Error).message || e}`));
        return;
      }
      // 幂等收尾：清看门狗、关文件、销毁请求、清活动句柄，只 settle 一次。
      // requestInStream 在收到响应头（200）时即 resolve，中停滞/断流不会再
      // 触发任何回调，所以所有路径（含看门狗与 cancelDownload）都必须经此收尾，
      // 否则悬挂的 Promise 会把下载状态机卡死在 downloading。
      const settle = (error?: Error): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (totalTimerId >= 0) {
          clearTimeout(totalTimerId);
          totalTimerId = -1;
        }
        if (stallTimerId >= 0) {
          clearInterval(stallTimerId);
          stallTimerId = -1;
        }
        if (this.activeSettle === settle) {
          this.activeSettle = null;
        }
        try {
          fileIo.closeSync(file!);
        } catch (_e) {
          // ignore
        }
        try {
          request.destroy();
        } catch (_e) {
          // ignore
        }
        if (this.activeRequest === request) {
          this.activeRequest = null;
        }
        if (error) {
          reject(error);
        } else {
          resolve();
        }
      };
      this.activeSettle = settle;
      // 看门狗 1：单文件总时长兜底。
      totalTimerId = setTimeout(() => {
        totalTimerId = -1;
        logger.warn(`fetchToFile total timeout: url=${url} receivedBytes=${receivedBytes}`);
        settle(new Error('download total timeout'));
      }, AsrModelManager.FETCH_TOTAL_TIMEOUT_MS);
      // 看门狗 2：停滞检测——中停滞时 dataReceive/dataReceiveProgress 都不再触发。
      stallTimerId = setInterval(() => {
        if (Date.now() - lastProgressAtMs > AsrModelManager.FETCH_STALL_TIMEOUT_MS) {
          logger.warn(`fetchToFile stall timeout: url=${url} receivedBytes=${receivedBytes}`);
          settle(new Error('download stalled (no progress)'));
        }
      }, AsrModelManager.FETCH_STALL_CHECK_MS);
      request.on('dataReceive', (data: ArrayBuffer) => {
        if (settled || this.cancelFlag) {
          return;
        }
        lastProgressAtMs = Date.now();
        receivedBytes += data.byteLength;
        try {
          // fileIo.writeSync 只接受原始 ArrayBuffer，TypedArray 视图会报 Invalid arraybuffer。
          // 实测单次 writeSync 最多写入约 16KB，必须按 chunk 循环写入，防止部分写入导致文件截断。
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
          settle(new Error(`write failed: ${(e as Error).message || e}`));
        }
      });
      request.on('dataReceiveProgress', (data: http.DataReceiveProgressInfo) => {
        lastProgressAtMs = Date.now();
        if (data.totalSize > 0) {
          const frac = data.receiveSize / data.totalSize;
          this.setStatus('downloading', Math.round((base + span * frac) * 100));
        }
      });
      request.on('dataEnd', () => {
        // 记录最终字节数与 HTTP 状态，便于排查空 200 假成功
        logger.info(`fetchToFile finished: url=${url} httpCode=${httpCode} receivedBytes=${receivedBytes}`);
        // 失败/取消都必须 reject——悬挂的 Promise 会把下载状态机卡死在 downloading
        if (this.cancelFlag) {
          settle(new Error('cancelled'));
        } else {
          settle();
        }
      });
      request.requestInStream(url, options)
        .then((code: number) => {
          httpCode = code;
          if (code !== 200 && code !== 206) {
            settle(new Error(`HTTP ${code}`));
          }
        })
        .catch((e: Error) => {
          settle(new Error(e.message || 'request failed'));
        });
    });
  }

  private cleanupPartial(dir: string): void {
    try {
      for (const spec of FILES) {
        const part = `${dir}/${spec.name}.part`;
        if (fileIo.accessSync(part)) {
          fileIo.unlinkSync(part);
        }
      }
    } catch (_e) {
      // ignore
    }
  }

  private setStatus(status: AsrModelStatus, percent: number): void {
    this.status = status;
    this.percent = percent;
    for (const cb of this.listeners) {
      try {
        cb(status, percent);
      } catch (_e) {
        // 监听器异常不影响下载
      }
    }
  }
}
