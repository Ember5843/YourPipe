import { BusinessError, cacheDownload } from '@kit.BasicServicesKit';
import { AppLog } from '../AppLog';
import { MediaThumb } from '../components/MediaThumb';

const logger = AppLog.getInstance('ThumbPrefetcher');

/** 缩略图 URL 提取器：信息流 item → 卡片 Image 实际首请求的 URL（空串 = 该项无可预取图） */
export type FeedThumbUrlOf = (item: Object) => string;

/**
 * 默认提取器：覆盖 MediaVideoFeed 全部现有 item 形态 ——
 * VideoItem / SubscriptionFeedItem（thumbnailUrl）、SearchStreamItem（video.thumbnailUrl）、
 * SearchChannelItem（avatarUrl）、SearchPlaylistItem（coverUrl）。
 * YouTube /vi/ 静帧收敛到 MediaThumb 五级回退链的首档（maxresdefault 优先），
 * 预取 URL 必须与卡片首请求 URL 一致才能命中同一份缓存。
 */
export function defaultFeedThumbUrl(item: Object): string {
  if (!item) {
    return '';
  }
  const rec = item as Record<string, Object>;
  const nested = rec['video'] as Record<string, Object> | undefined;
  if (nested) {
    const nestedThumb = nested['thumbnailUrl'];
    if (typeof nestedThumb === 'string' && nestedThumb.length > 0) {
      return MediaThumb.firstChoiceUrl(nestedThumb);
    }
  }
  const direct = rec['thumbnailUrl'];
  if (typeof direct === 'string' && direct.length > 0) {
    return MediaThumb.firstChoiceUrl(direct);
  }
  const avatar = rec['avatarUrl'];
  if (typeof avatar === 'string' && avatar.length > 0) {
    return avatar;
  }
  const cover = rec['coverUrl'];
  if (typeof cover === 'string' && cover.length > 0) {
    return cover;
  }
  return '';
}

interface PrefetchHandlers {
  onSuccess: () => void;
  onError: (err: cacheDownload.DownloadError) => void;
}

/** 日志脱敏：ytimg 静帧只留 videoId，其余只留 host，绝不落完整 URL */
function redactThumbUrl(url: string): string {
  const vid = /ytimg\.com\/vi(?:_webp)?\/([^/]+)\//i.exec(url);
  if (vid && vid[1]) {
    return `ytimg/vi/${vid[1]}`;
  }
  const host = /^https?:\/\/([^/]+)/i.exec(url);
  return host ? host[1] : 'invalid-url';
}

/**
 * 列表缩略图预取器（进程内单例，跨信息流去重）。
 * 底层走系统 cacheDownload：预下载进内存 + 文件缓存后，ArkUI Image 组件
 * 请求同一 URL 时直接命中该缓存（官方 arkts-graphics-display 指南确认的
 * Image ↔ cacheDownload 联动机制），无需自管磁盘缓存。
 * cacheStrategy=LAZY 让系统侧已缓存的 URL 直接跳过；retry=0 保持预取轻量，
 * 失败不补刀 —— 卡片出现时 Image 会按原有五级回退链自行加载。
 */
export class ThumbPrefetcher {
  private static readonly MAX_DONE: number = 2000;
  private static instance: ThumbPrefetcher | null = null;

  /** URL -> 该 URL 注册的完成/失败回调（注销需要原引用） */
  private inFlight: Map<string, PrefetchHandlers> = new Map();
  /** 已成功预取的 URL（去重；超上限整体清空，让最旧的重新可预取） */
  private done: Set<string> = new Set();

  static getInstance(): ThumbPrefetcher {
    if (!ThumbPrefetcher.instance) {
      ThumbPrefetcher.instance = new ThumbPrefetcher();
    }
    return ThumbPrefetcher.instance;
  }

  prefetchUrl(rawUrl: string): void {
    const url = (rawUrl || '').trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return;
    }
    if (this.done.has(url) || this.inFlight.has(url)) {
      return;
    }
    const handlers: PrefetchHandlers = {
      onSuccess: () => {
        this.finish(url, true, 0);
      },
      onError: (err: cacheDownload.DownloadError) => {
        this.finish(url, false, err.errorCode);
      }
    };
    try {
      cacheDownload.onDownloadSuccess(url, handlers.onSuccess);
      cacheDownload.onDownloadError(url, handlers.onError);
      cacheDownload.download(url, {
        cacheStrategy: cacheDownload.CacheStrategy.LAZY,
        retry: { maxRetryCount: 0 },
        timeout: { httpTotalTimeout: 15 }
      });
      this.inFlight.set(url, handlers);
      logger.debug(`thumb prefetch start ${redactThumbUrl(url)}`);
    } catch (e) {
      cacheDownload.offDownloadSuccess(url, handlers.onSuccess);
      cacheDownload.offDownloadError(url, handlers.onError);
      const err = e as BusinessError;
      logger.warn(`thumb prefetch start failed ${redactThumbUrl(url)} code=${err.code}`);
    }
  }

  cancelUrl(rawUrl: string): void {
    const url = (rawUrl || '').trim();
    const handlers = this.inFlight.get(url);
    if (!handlers) {
      return;
    }
    cacheDownload.offDownloadSuccess(url, handlers.onSuccess);
    cacheDownload.offDownloadError(url, handlers.onError);
    this.inFlight.delete(url);
    try {
      cacheDownload.cancel(url);
      logger.debug(`thumb prefetch cancel ${redactThumbUrl(url)}`);
    } catch (e) {
      const err = e as BusinessError;
      logger.warn(`thumb prefetch cancel failed ${redactThumbUrl(url)} code=${err.code}`);
    }
  }

  private finish(url: string, ok: boolean, errorCode: number): void {
    const handlers = this.inFlight.get(url);
    if (handlers) {
      cacheDownload.offDownloadSuccess(url, handlers.onSuccess);
      cacheDownload.offDownloadError(url, handlers.onError);
      this.inFlight.delete(url);
    }
    if (ok) {
      this.done.add(url);
      if (this.done.size > ThumbPrefetcher.MAX_DONE) {
        this.done.clear();
      }
      logger.debug(`thumb prefetch done ${redactThumbUrl(url)}`);
    } else {
      // 预取失败不打回退链 —— 交给卡片出现时的 Image 五级回退，避免双倍请求
      logger.debug(`thumb prefetch failed ${redactThumbUrl(url)} errorCode=${errorCode}`);
    }
  }
}
