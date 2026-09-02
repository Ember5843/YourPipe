import {
  SabrInfoReloader,
  SabrMediaSegment,
  SabrPoTokenProvider,
  SabrSegmentRequest,
  setSabrNetworkTrafficSink,
  YoutubeSabrFormatMeta,
  YoutubeSabrInfo,
  YoutubeSabrSession,
  YouTubeHttpClient
} from 'youtube_core';
import Logger from '../utils/Logger';
import { proxyTrafficMeter } from '../proxy/ProxyTrafficMeter';

const TAG = '[SabrSessionStore]';

export interface SabrSessionKey {
  videoId: string;
  profile: string;
  audioItag: number;
  audioTrackId: string;
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
 * One session = one client profile + audio track + video format combination.
 * Multi-language audio reuses the same itag, so audioTrackId is part of the identity.
 */
class SabrSessionStoreImpl {
  private leases: Map<string, SabrLease> = new Map();
  private httpClient?: YouTubeHttpClient;
  private poTokenProvider?: SabrPoTokenProvider;
  private infoReloader?: SabrInfoReloader;

  setHttpClient(client: YouTubeHttpClient): void {
    this.httpClient = client;
    // UMP response bytes are the SABR path's true network ingress; meter them
    // for the stats panel's connection speed (segment-cache hits never reach this).
    setSabrNetworkTrafficSink((bytes: number) => proxyTrafficMeter.recordBytes(bytes));
  }

  setPoTokenProvider(provider?: SabrPoTokenProvider): void {
    this.poTokenProvider = provider;
  }

  setInfoReloader(reloader?: SabrInfoReloader): void {
    this.infoReloader = reloader;
  }

  makeKey(
    videoId: string,
    profile: string,
    audioItag: number,
    audioTrackId: string | undefined,
    videoItag: number
  ): string {
    return `${videoId}|p${profile}|a${audioItag}|t${audioTrackId || '-'}|v${videoItag}`;
  }

  /**
   * @param keySuffix Isolation suffix appended to the lease key. Offline
   *   downloads pass '|dl' so a download never shares a session (playhead,
   *   segment cache, forward-jump resets) with concurrent playback on the
   *   same video/formats. release/abort key off lease.key, so they stay
   *   balanced for suffixed keys without further changes.
   */
  acquire(
    info: YoutubeSabrInfo,
    audioFormat: YoutubeSabrFormatMeta,
    videoFormat: YoutubeSabrFormatMeta,
    useAuth: boolean = false,
    keySuffix: string = ''
  ): SabrLease {
    const key = this.makeKey(
      info.videoId, info.profile, audioFormat.itag, audioFormat.audioTrackId, videoFormat.itag)
      + keySuffix;
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
      info, audioFormat, videoFormat, this.httpClient, this.poTokenProvider, useAuth,
      this.infoReloader);
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

  /**
   * Abort-level teardown for a lease whose proxy session is being destroyed:
   * session.close() aborts the in-flight UMP POST, rejects queued pump waiters
   * and interrupts backoff sleeps. Only fires when this lease is the sole
   * holder — a shared lease (e.g. two proxy sessions on the same key) keeps
   * its session alive, and release() remains the sole refCount-driven closer
   * (close() itself is idempotent, so abort → release never double-closes).
   * Offline downloads never share a key with playback: they acquire with the
   * '|dl' suffix, so their abort/release lifecycle is fully independent.
   */
  abort(key: string): void {
    const lease = this.leases.get(key);
    if (!lease) {
      return;
    }
    if (lease.refCount <= 1) {
      Logger.info(TAG, `abort key=${key}`);
      lease.session.close();
    }
  }

  get(key: string): SabrLease | undefined {
    return this.leases.get(key);
  }

  /**
   * Network-handover lever (wired by entry NetworkHandoverService): abort the
   * in-flight UMP POST of every active session so a stale connection errors
   * out immediately. Unlike abort(key), sessions stay open — each session's
   * existing catch/retry paths re-POST on the new network. Returns the number
   * of sessions whose POST was aborted.
   */
  abortAllInFlightPosts(reason: string): number {
    let count = 0;
    for (const lease of this.leases.values()) {
      if (lease.session.abortInFlightPost(reason)) {
        count++;
      }
    }
    Logger.info(TAG, `abortAllInFlightPosts: reason=${reason} sessions=${this.leases.size} aborted=${count}`);
    return count;
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
