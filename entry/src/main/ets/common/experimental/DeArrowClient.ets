import { AppLog } from '../AppLog';
import { CommunityHttp, CommunityHttpResult } from './CommunityHttp';

const logger = AppLog.getInstance('DeArrowClient');

const BRANDING_URL: string = 'https://sponsor.ajay.app/api/branding';
const CACHE_TTL_MS: number = 24 * 60 * 60 * 1000;
const EMPTY_CACHE_TTL_MS: number = 60 * 60 * 1000;
const CACHE_LIMIT: number = 500;

interface DeArrowTitleApiItem {
  title?: string;
  original?: boolean;
  votes?: number;
  locked?: boolean;
}

interface DeArrowBrandingApi {
  titles?: DeArrowTitleApiItem[];
  randomTime?: number;
  videoDuration?: number;
}

interface TitleCacheEntry {
  title: string;
  fetchedAt: number;
}

/** DeArrow 只读客户端：众包标题（缩略图留到后续阶段）。 */
export class DeArrowClient {
  private static instance: DeArrowClient | null = null;

  private cache: Map<string, TitleCacheEntry> = new Map();
  private inflight: Map<string, Promise<string>> = new Map();

  static getInstance(): DeArrowClient {
    if (!DeArrowClient.instance) {
      DeArrowClient.instance = new DeArrowClient();
    }
    return DeArrowClient.instance;
  }

  /** 返回可替换的标题；无提交/全部原题/负票时返回空串。 */
  async getTitle(videoId: string): Promise<string> {
    const id = (videoId || '').trim();
    if (id.length === 0) {
      return '';
    }
    const cached = this.readCache(id);
    if (cached !== null) {
      return cached;
    }
    const pending = this.inflight.get(id);
    if (pending) {
      return pending;
    }
    const task = this.fetchTitle(id);
    this.inflight.set(id, task);
    try {
      return await task;
    } finally {
      this.inflight.delete(id);
    }
  }

  clearCache(): void {
    this.cache.clear();
  }

  private async fetchTitle(videoId: string): Promise<string> {
    const url = `${BRANDING_URL}?videoID=${encodeURIComponent(videoId)}&fetchAll=true`;
    const startedAt = Date.now();
    let result: CommunityHttpResult;
    try {
      result = await CommunityHttp.getText(url, 8000);
    } catch (e) {
      logger.warn(`title fetch failed video=${videoId} error=${(e as Error).message}`);
      throw e as Error;
    }

    let title = '';
    if (result.status === 200 && result.body.length > 0) {
      title = DeArrowClient.pickTitle(result.body);
    } else if (result.status !== 404 && result.status !== 204) {
      logger.warn(`title unexpected status video=${videoId} status=${result.status}`);
    }

    this.writeCache(videoId, title);
    logger.info(`title video=${videoId} replaced=${title.length > 0} `
      + `status=${result.status} elapsed=${Date.now() - startedAt}ms`);
    return title;
  }

  private static pickTitle(body: string): string {
    let branding: DeArrowBrandingApi;
    try {
      branding = JSON.parse(body) as DeArrowBrandingApi;
    } catch (e) {
      return '';
    }
    const titles = branding.titles;
    if (!Array.isArray(titles)) {
      return '';
    }
    for (const item of titles) {
      if (!item || item.original === true) {
        continue;
      }
      const locked = item.locked === true;
      const votes = typeof item.votes === 'number' ? item.votes : 0;
      // 负票且未锁定的标题不采用；锁定标题即使 0 票也采用。
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

  /** DeArrow 用 '>' 标记「不要自动改变大小写」的词，展示前去掉。 */
  private static cleanTitle(raw: string): string {
    return raw.replace(/>/g, '').trim();
  }

  private readCache(videoId: string): string | null {
    const entry = this.cache.get(videoId);
    if (!entry) {
      return null;
    }
    const ttl = entry.title.length > 0 ? CACHE_TTL_MS : EMPTY_CACHE_TTL_MS;
    if (Date.now() - entry.fetchedAt > ttl) {
      this.cache.delete(videoId);
      return null;
    }
    return entry.title;
  }

  private writeCache(videoId: string, title: string): void {
    if (this.cache.size >= CACHE_LIMIT) {
      const oldest = this.cache.keys().next();
      if (!oldest.done) {
        this.cache.delete(oldest.value);
      }
    }
    this.cache.set(videoId, { title: title, fetchedAt: Date.now() });
  }
}
