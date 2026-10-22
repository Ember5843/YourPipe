import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { getAppVersion } from '../AppVersion';
import { AppLog } from '../AppLog';
import { CommunityHttp, CommunityHttpResult } from './CommunityHttp';

const logger = AppLog.getInstance('SponsorBlockClient');

const CACHE_TTL_MS: number = 6 * 60 * 60 * 1000;
const EMPTY_CACHE_TTL_MS: number = 60 * 60 * 1000;
const CACHE_LIMIT: number = 300;

export interface SponsorSegment {
  category: string;
  actionType: string;
  startSec: number;
  endSec: number;
  votes: number;
  locked: boolean;
}

interface SegmentCacheEntry {
  segments: SponsorSegment[];
  fetchedAt: number;
}

interface SegmentApiItem {
  category?: string;
  actionType?: string;
  segment?: number[];
  votes?: number;
  locked?: number;
}

interface VideoSegmentsApiItem {
  videoID?: string;
  segments?: SegmentApiItem[];
}

/** SponsorBlock 客户端：只读查询 + 内存缓存 + 单飞去重。 */
export class SponsorBlockClient {
  private static instance: SponsorBlockClient | null = null;

  private cache: Map<string, SegmentCacheEntry> = new Map();
  private inflight: Map<string, Promise<SponsorSegment[]>> = new Map();

  static getInstance(): SponsorBlockClient {
    if (!SponsorBlockClient.instance) {
      SponsorBlockClient.instance = new SponsorBlockClient();
    }
    return SponsorBlockClient.instance;
  }

  /**
   * 取某个视频的片段。404 / 空响应返回空数组（属正常语义），网络错误抛出。
   * privacy=true 时只发送 videoId 的 SHA-256 前 4 位。
   */
  async getSegments(videoId: string, categories: string[], server: string,
    privacy: boolean): Promise<SponsorSegment[]> {
    const id = (videoId || '').trim();
    if (id.length === 0 || categories.length === 0) {
      return [];
    }
    const cacheKey = `${id}|${categories.join(',')}`;
    const cached = this.readCache(cacheKey);
    if (cached !== null) {
      return cached;
    }
    const pending = this.inflight.get(cacheKey);
    if (pending) {
      return pending;
    }
    const task = this.fetchSegments(id, categories, server, privacy);
    this.inflight.set(cacheKey, task);
    try {
      return await task;
    } finally {
      this.inflight.delete(cacheKey);
    }
  }

  clearCache(): void {
    this.cache.clear();
  }

  private async fetchSegments(videoId: string, categories: string[],
    server: string, privacy: boolean): Promise<SponsorSegment[]> {
    const base = (server || 'https://sponsor.ajay.app').replace(/\/+$/, '');
    const categoryParam = encodeURIComponent(JSON.stringify(categories));
    const actionParam = encodeURIComponent(JSON.stringify(['skip', 'poi']));
    let url: string;
    if (privacy) {
      const hash = await SponsorBlockClient.videoHashPrefix(videoId);
      url = `${base}/api/skipSegments/${hash}?categories=${categoryParam}`
        + `&actionTypes=${actionParam}&userAgent=${encodeURIComponent(SponsorBlockClient.userAgent())}`;
    } else {
      url = `${base}/api/skipSegments?videoID=${encodeURIComponent(videoId)}`
        + `&categories=${categoryParam}&actionTypes=${actionParam}`
        + `&userAgent=${encodeURIComponent(SponsorBlockClient.userAgent())}`;
    }

    const startedAt = Date.now();
    let result: CommunityHttpResult;
    try {
      result = await CommunityHttp.getText(url, 8000);
    } catch (e) {
      logger.warn(`fetch failed video=${videoId} privacy=${privacy} error=${(e as Error).message}`);
      throw e as Error;
    }

    let segments: SponsorSegment[] = [];
    if (result.status === 200 && result.body.length > 0) {
      segments = SponsorBlockClient.parse(videoId, result.body);
    } else if (result.status !== 404 && result.status !== 204) {
      logger.warn(`unexpected status video=${videoId} status=${result.status}`);
    }

    this.writeCache(`${videoId}|${categories.join(',')}`, segments);
    logger.info(`segments video=${videoId} privacy=${privacy} count=${segments.length} `
      + `status=${result.status} elapsed=${Date.now() - startedAt}ms`);
    return segments;
  }

  private readCache(videoId: string): SponsorSegment[] | null {
    const entry = this.cache.get(videoId);
    if (!entry) {
      return null;
    }
    const ttl = entry.segments.length > 0 ? CACHE_TTL_MS : EMPTY_CACHE_TTL_MS;
    if (Date.now() - entry.fetchedAt > ttl) {
      this.cache.delete(videoId);
      return null;
    }
    return entry.segments;
  }

  private writeCache(videoId: string, segments: SponsorSegment[]): void {
    if (this.cache.size >= CACHE_LIMIT) {
      const oldest = this.cache.keys().next();
      if (!oldest.done) {
        this.cache.delete(oldest.value);
      }
    }
    this.cache.set(videoId, { segments: segments, fetchedAt: Date.now() });
  }

  private static parse(videoId: string, body: string): SponsorSegment[] {
    let root: VideoSegmentsApiItem[];
    try {
      root = JSON.parse(body) as VideoSegmentsApiItem[];
    } catch (e) {
      logger.warn(`parse failed video=${videoId} error=${(e as Error).message}`);
      return [];
    }
    if (!Array.isArray(root)) {
      return [];
    }
    const segments: SponsorSegment[] = [];
    for (const video of root) {
      if (!video || video.videoID !== videoId || !Array.isArray(video.segments)) {
        continue;
      }
      for (const item of video.segments) {
        if (!item || !Array.isArray(item.segment) || item.segment.length < 2) {
          continue;
        }
        const start = item.segment[0];
        const end = item.segment[1];
        if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) {
          continue;
        }
        segments.push({
          category: item.category || '',
          actionType: item.actionType || 'skip',
          startSec: start,
          endSec: end,
          votes: typeof item.votes === 'number' ? item.votes : 0,
          locked: item.locked === 1
        });
      }
    }
    segments.sort((a: SponsorSegment, b: SponsorSegment) => a.startSec - b.startSec);
    return segments;
  }

  private static async videoHashPrefix(videoId: string): Promise<string> {
    const md = cryptoFramework.createMd('SHA256');
    await md.update({ data: new util.TextEncoder().encodeInto(videoId) });
    const out = await md.digest();
    let hex = '';
    for (const b of out.data) {
      hex += b.toString(16).padStart(2, '0');
    }
    return hex.substring(0, 4);
  }

  private static userAgent(): string {
    try {
      return `YourPipe/${getAppVersion().versionName}`;
    } catch (_e) {
      return 'YourPipe';
    }
  }
}

