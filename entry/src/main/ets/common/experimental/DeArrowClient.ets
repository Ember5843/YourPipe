import { AppLog } from '../AppLog';
import { CommunityHttp, CommunityHttpResult } from './CommunityHttp';

const logger = AppLog.getInstance('DeArrowClient');

const BRANDING_URL: string = 'https://sponsor.ajay.app/api/branding';
const THUMBNAIL_URL: string = 'https://dearrow-thumb.ajay.app/api/v1/getThumbnail';
const CACHE_TTL_MS: number = 24 * 60 * 60 * 1000;
const EMPTY_CACHE_TTL_MS: number = 60 * 60 * 1000;
const CACHE_LIMIT: number = 500;

export interface DeArrowBranding {
  /** 可替换的众包标题；空串表示不替换。 */
  title: string;
  /** 可替换的缩略图时间点（秒）；< 0 表示不替换。 */
  thumbnailTime: number;
}

interface DeArrowTitleApiItem {
  title?: string;
  original?: boolean;
  votes?: number;
  locked?: boolean;
}

interface DeArrowThumbnailApiItem {
  timestamp?: number;
  original?: boolean;
  votes?: number;
  locked?: boolean;
}

interface DeArrowBrandingApi {
  titles?: DeArrowTitleApiItem[];
  thumbnails?: DeArrowThumbnailApiItem[];
}

interface BrandingCacheEntry {
  branding: DeArrowBranding;
  fetchedAt: number;
}

function emptyBranding(): DeArrowBranding {
  return { title: '', thumbnailTime: -1 };
}

/** DeArrow 只读客户端：众包标题 + 缩略图时间点。 */
export class DeArrowClient {
  private static instance: DeArrowClient | null = null;

  private cache: Map<string, BrandingCacheEntry> = new Map();
  private inflight: Map<string, Promise<DeArrowBranding>> = new Map();

  static getInstance(): DeArrowClient {
    if (!DeArrowClient.instance) {
      DeArrowClient.instance = new DeArrowClient();
    }
    return DeArrowClient.instance;
  }

  async getBranding(videoId: string): Promise<DeArrowBranding> {
    const id = (videoId || '').trim();
    if (id.length === 0) {
      return emptyBranding();
    }
    const cached = this.readCache(id);
    if (cached !== null) {
      return cached;
    }
    const pending = this.inflight.get(id);
    if (pending) {
      return pending;
    }
    const task = this.fetchBranding(id);
    this.inflight.set(id, task);
    try {
      return await task;
    } finally {
      this.inflight.delete(id);
    }
  }

  /** 缩略图生成服务 URL；只在有众包提交时间点时调用。 */
  static thumbnailUrl(videoId: string, timestamp: number): string {
    return `${THUMBNAIL_URL}?videoID=${encodeURIComponent(videoId)}`
      + `&time=${encodeURIComponent(timestamp.toFixed(3))}`;
  }

  clearCache(): void {
    this.cache.clear();
  }

  private async fetchBranding(videoId: string): Promise<DeArrowBranding> {
    const url = `${BRANDING_URL}?videoID=${encodeURIComponent(videoId)}&fetchAll=true`;
    const startedAt = Date.now();
    let result: CommunityHttpResult;
    try {
      result = await CommunityHttp.getText(url, 8000);
    } catch (e) {
      logger.warn(`branding fetch failed video=${videoId} error=${(e as Error).message}`);
      throw e as Error;
    }

    let branding = emptyBranding();
    if (result.status === 200 && result.body.length > 0) {
      branding = DeArrowClient.parse(result.body);
    } else if (result.status !== 404 && result.status !== 204) {
      logger.warn(`branding unexpected status video=${videoId} status=${result.status}`);
    }

    this.writeCache(videoId, branding);
    logger.info(`branding video=${videoId} title=${branding.title.length > 0} `
      + `thumb=${branding.thumbnailTime >= 0} status=${result.status} `
      + `elapsed=${Date.now() - startedAt}ms`);
    return branding;
  }

  private static parse(body: string): DeArrowBranding {
    let api: DeArrowBrandingApi;
    try {
      api = JSON.parse(body) as DeArrowBrandingApi;
    } catch (e) {
      return emptyBranding();
    }
    return {
      title: DeArrowClient.pickTitle(api.titles),
      thumbnailTime: DeArrowClient.pickThumbnailTime(api.thumbnails)
    };
  }

  private static pickTitle(titles: DeArrowTitleApiItem[] | undefined): string {
    if (!Array.isArray(titles)) {
      return '';
    }
    for (const item of titles) {
      if (!item || item.original === true) {
        continue;
      }
      const locked = item.locked === true;
      const votes = typeof item.votes === 'number' ? item.votes : 0;
      if (!locked && votes < 0) {
        continue;
      }
      const cleaned = DeArrowClient.cleanTitle(item.title || '');
      if (cleaned.length > 0) {
        return cleaned;
      }
    }
    return '';
  }

  private static pickThumbnailTime(thumbnails: DeArrowThumbnailApiItem[] | undefined): number {
    if (!Array.isArray(thumbnails)) {
      return -1;
    }
    for (const item of thumbnails) {
      if (!item || item.original === true) {
        continue;
      }
      const locked = item.locked === true;
      const votes = typeof item.votes === 'number' ? item.votes : 0;
      if (!locked && votes < 0) {
        continue;
      }
      const timestamp = item.timestamp;
      if (typeof timestamp === 'number' && Number.isFinite(timestamp) && timestamp > 0) {
        return timestamp;
      }
    }
    return -1;
  }

  /** DeArrow 用 '>' 标记「不要自动改变大小写」的词，展示前去掉。 */
  private static cleanTitle(raw: string): string {
    return raw.replace(/>/g, '').trim();
  }

  private readCache(videoId: string): DeArrowBranding | null {
    const entry = this.cache.get(videoId);
    if (!entry) {
      return null;
    }
    const hasData = entry.branding.title.length > 0 || entry.branding.thumbnailTime >= 0;
    const ttl = hasData ? CACHE_TTL_MS : EMPTY_CACHE_TTL_MS;
    if (Date.now() - entry.fetchedAt > ttl) {
      this.cache.delete(videoId);
      return null;
    }
    return entry.branding;
  }

  private writeCache(videoId: string, branding: DeArrowBranding): void {
    if (this.cache.size >= CACHE_LIMIT) {
      const oldest = this.cache.keys().next();
      if (!oldest.done) {
        this.cache.delete(oldest.value);
      }
    }
    this.cache.set(videoId, { branding: branding, fetchedAt: Date.now() });
  }
}
