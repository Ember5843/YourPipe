import {
  SabrMediaSegment,
  SabrSegmentRequest,
  YoutubeSabrFormatMeta,
  YoutubeSabrInfo,
  YoutubeSabrSession,
  YouTubeHttpClient
} from 'youtube_core';
import Logger from '../utils/Logger';

const TAG = '[SabrSessionStore]';

export interface SabrSessionKey {
  videoId: string;
  audioItag: number;
  videoItag: number;
}

export interface SabrLease {
  key: string;
  session: YoutubeSabrSession;
  audioFormat: YoutubeSabrFormatMeta;
  videoFormat: YoutubeSabrFormatMeta;
  info: YoutubeSabrInfo;
  refCount: number;
}

/**
 * Process-wide SABR session registry (PipePipe SabrSessionStore subset).
 * One session = one audio+video itag pair.
 */
class SabrSessionStoreImpl {
  private leases: Map<string, SabrLease> = new Map();
  private httpClient?: YouTubeHttpClient;

  setHttpClient(client: YouTubeHttpClient): void {
    this.httpClient = client;
  }

  makeKey(videoId: string, audioItag: number, videoItag: number): string {
    return `${videoId}|a${audioItag}|v${videoItag}`;
  }

  acquire(
    info: YoutubeSabrInfo,
    audioFormat: YoutubeSabrFormatMeta,
    videoFormat: YoutubeSabrFormatMeta,
    useAuth: boolean = false
  ): SabrLease {
    const key = this.makeKey(info.videoId, audioFormat.itag, videoFormat.itag);
    const existing = this.leases.get(key);
    if (existing) {
      existing.refCount++;
      Logger.info(TAG, `acquire existing key=${key} refs=${existing.refCount}`);
      return existing;
    }
    if (!this.httpClient) {
      throw new Error('SabrSessionStore: YouTubeHttpClient not set');
    }
    const session = new YoutubeSabrSession(
      info, audioFormat, videoFormat, this.httpClient, undefined, useAuth);
    const lease: SabrLease = {
      key: key,
      session: session,
      audioFormat: audioFormat,
      videoFormat: videoFormat,
      info: info,
      refCount: 1
    };
    this.leases.set(key, lease);
    Logger.info(TAG, `acquire new key=${key}`);
    return lease;
  }

  release(key: string): void {
    const lease = this.leases.get(key);
    if (!lease) {
      return;
    }
    lease.refCount--;
    Logger.info(TAG, `release key=${key} refs=${lease.refCount}`);
    if (lease.refCount <= 0) {
      lease.session.close();
      this.leases.delete(key);
    }
  }

  get(key: string): SabrLease | undefined {
    return this.leases.get(key);
  }

  async ensureInit(lease: SabrLease, isAudio: boolean): Promise<SabrMediaSegment> {
    const itag = isAudio ? lease.audioFormat.itag : lease.videoFormat.itag;
    return await lease.session.fetchSegment(SabrSegmentRequest.init(itag));
  }

  async ensureMedia(lease: SabrLease, isAudio: boolean, sequence: number): Promise<SabrMediaSegment> {
    const itag = isAudio ? lease.audioFormat.itag : lease.videoFormat.itag;
    return await lease.session.fetchSegment(SabrSegmentRequest.media(itag, sequence));
  }

  setPlayHeadMs(key: string, ms: number): void {
    const lease = this.leases.get(key);
    if (lease) {
      lease.session.setPlayHeadMs(ms);
    }
  }

  prepareSeek(key: string, targetMs: number): void {
    const lease = this.leases.get(key);
    if (!lease) {
      return;
    }
    lease.session.prepareForForwardJump(targetMs);
  }
}

export const sabrSessionStore = new SabrSessionStoreImpl();
