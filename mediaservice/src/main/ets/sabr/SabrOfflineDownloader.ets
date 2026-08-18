import {
  SabrProtocolException,
  YoutubeSabrFormatMeta,
  YoutubeSabrInfo
} from 'youtube_core';
import Logger from '../utils/Logger';
import { StreamInfo } from '../model/VideoData';
import { PlayerModel } from '../model/PlayerModel';
import { SabrLease, sabrSessionStore } from './SabrSessionStore';
import { SabrTrackBuffer } from './SabrTrackBuffer';

const TAG = '[SabrOfflineDownloader]';

export interface SabrOfflineProgress {
  track: 'video' | 'audio' | 'both';
  phase: 'init' | 'media' | 'done';
  sequence: number;
  endSegment: number;
  bytesWritten: number;
  /** Overall 0–100 when both ends known; else heuristic. */
  percent: number;
  videoBytes: number;
  audioBytes: number;
  videoSeq: number;
  audioSeq: number;
}

export interface SabrOfflineDownloadOptions {
  video: StreamInfo;
  audio: StreamInfo;
  durationMs?: number;
  useAuth?: boolean;
  isCancelled?: () => boolean;
  onProgress?: (progress: SabrOfflineProgress) => void;
  writeVideo: (data: Uint8Array) => void | Promise<void>;
  writeAudio: (data: Uint8Array) => void | Promise<void>;
}

/**
 * Offline SABR dump — dual-track (same session as playback).
 * One lease requests A+V together; each pump can fill both tracks.
 * Interleave writes so cache stays near play-head and does not thrash.
 */
export class SabrOfflineDownloader {
  static isSabrStream(stream?: StreamInfo | null): boolean {
    return PlayerModel.isSabrStream(stream);
  }

  static async downloadTracks(options: SabrOfflineDownloadOptions): Promise<void> {
    const info: YoutubeSabrInfo | undefined = options.video.sabrInfo || options.audio.sabrInfo;
    if (!info || !info.serverAbrStreamingUrl) {
      throw new Error('SABR download: missing sabrInfo/serverAbrStreamingUrl');
    }
    const videoItag = options.video.itag;
    const audioItag = options.audio.itag;
    if (videoItag === undefined || audioItag === undefined) {
      throw new Error('SABR download: missing itags');
    }

    const videoFmt = SabrOfflineDownloader.resolveVideoFormat(info, options.video, videoItag);
    const audioFmt = SabrOfflineDownloader.resolveAudioFormat(info, options.audio, audioItag);

    const durationMs = options.durationMs
      || options.video.approxDurationMs
      || options.audio.approxDurationMs
      || 0;
    const useAuth = !!options.useAuth;

    Logger.info(TAG, `download start dual-track video=${videoItag} audio=${audioItag} `
      + `track=${options.audio.audioTrackId || audioFmt.audioTrackId || '-'} `
      + `durationMs=${durationMs} useAuth=${useAuth}`);

    const lease: SabrLease = sabrSessionStore.acquire(info, audioFmt, videoFmt, useAuth);
    try {
      const videoBuf = new SabrTrackBuffer(lease, false, durationMs);
      const audioBuf = new SabrTrackBuffer(lease, true, durationMs);
      // Warm once (serialized), same as playback createSabrDualSession.
      await videoBuf.ensureReady();
      if (options.isCancelled?.()) {
        throw new Error('cancelled');
      }
      await audioBuf.ensureReady();
      if (options.isCancelled?.()) {
        throw new Error('cancelled');
      }

      await SabrOfflineDownloader.dumpDualTrack(
        videoBuf, audioBuf, lease, options.writeVideo, options.writeAudio,
        options.onProgress, options.isCancelled);

      Logger.info(TAG, `download complete dual-track video=${videoItag} audio=${audioItag}`);
    } finally {
      sabrSessionStore.release(lease.key);
    }
  }

  private static resolveVideoFormat(
    info: YoutubeSabrInfo, stream: StreamInfo, itag: number
  ): YoutubeSabrFormatMeta {
    const found = info.findFormatByItag(itag);
    if (found) {
      return found;
    }
    return {
      itag: itag,
      mimeType: stream.mimeType,
      bitrate: stream.bitrate,
      width: stream.width,
      height: stream.height,
      isAudio: false,
      isVideo: true,
      qualityLabel: stream.quality,
      codecs: stream.codecs,
      approxDurationMs: stream.approxDurationMs
    };
  }

  private static resolveAudioFormat(
    info: YoutubeSabrInfo, stream: StreamInfo, itag: number
  ): YoutubeSabrFormatMeta {
    let found = info.findFormatByItagAndTrack(itag, stream.audioTrackId);
    if (found && stream.audioTrackId && found.audioTrackId !== stream.audioTrackId) {
      found = undefined;
    }
    if (found) {
      return found;
    }
    return {
      itag: itag,
      mimeType: stream.mimeType,
      bitrate: stream.bitrate,
      isAudio: true,
      isVideo: false,
      codecs: stream.codecs,
      audioTrackId: stream.audioTrackId,
      audioTrackName: stream.audioTrackName,
      isOriginalAudio: (stream.audioTrackType || '').toLowerCase() === 'original',
      approxDurationMs: stream.approxDurationMs
    };
  }

  /**
   * Dual-track dump: keep A/V timelines close.
   * Prefer whichever track is lagging in media time so SABR POSTs stay balanced.
   */
  private static async dumpDualTrack(
    videoBuf: SabrTrackBuffer,
    audioBuf: SabrTrackBuffer,
    lease: SabrLease,
    writeVideo: (data: Uint8Array) => void | Promise<void>,
    writeAudio: (data: Uint8Array) => void | Promise<void>,
    onProgress?: (progress: SabrOfflineProgress) => void,
    isCancelled?: () => boolean
  ): Promise<void> {
    let videoBytes = 0;
    let audioBytes = 0;
    let videoSeq = 0;
    let audioSeq = 0;
    let videoDone = false;
    let audioDone = false;
    let consecutiveFetchFails = 0;

    // Inits first (both tracks). Use the same trimmed init as playback:
    // full UMP init often embeds hierarchical SIDX (reference_type=1) which
    // lavf rejects or remuxes into a black-screen MP4. Playback already trims
    // to decoder init only — offline remux must match.
    const vInit = await videoBuf.readSegment(true, -1, false);
    if (!vInit || vInit.length === 0) {
      throw new Error(`SABR download: empty video init itag=${videoBuf.getItag()}`);
    }
    await writeVideo(vInit);
    videoBytes += vInit.length;
    onProgress?.({
      track: 'video', phase: 'init', sequence: 0,
      endSegment: videoBuf.getEndSegment(), bytesWritten: videoBytes, percent: 1,
      videoBytes, audioBytes, videoSeq, audioSeq
    });

    const aInit = await audioBuf.readSegment(true, -1, false);
    if (!aInit || aInit.length === 0) {
      throw new Error(`SABR download: empty audio init itag=${audioBuf.getItag()}`);
    }
    await writeAudio(aInit);
    audioBytes += aInit.length;
    onProgress?.({
      track: 'audio', phase: 'init', sequence: 0,
      endSegment: audioBuf.getEndSegment(), bytesWritten: audioBytes, percent: 1,
      videoBytes, audioBytes, videoSeq, audioSeq
    });

    // Next media sequence to request for each track.
    let nextVideoSeq = 1;
    let nextAudioSeq = 1;

    while (!videoDone || !audioDone) {
      if (isCancelled?.()) {
        throw new Error('cancelled');
      }

      const vEnd = videoBuf.getEndSegment();
      const aEnd = audioBuf.getEndSegment();
      if (!videoDone && vEnd > 0 && nextVideoSeq > vEnd) {
        videoDone = true;
      }
      if (!audioDone && aEnd > 0 && nextAudioSeq > aEnd) {
        audioDone = true;
      }
      if (videoDone && audioDone) {
        break;
      }

      // Choose lagging track by end time of last written media (dual-track balance).
      const vTime = videoSeq > 0 ? videoBuf.getSegmentEndMs(videoSeq) : 0;
      const aTime = audioSeq > 0 ? audioBuf.getSegmentEndMs(audioSeq) : 0;
      let preferVideo = !videoDone;
      if (!videoDone && !audioDone) {
        preferVideo = vTime <= aTime;
      } else if (audioDone) {
        preferVideo = true;
      } else {
        preferVideo = false;
      }

      let progressed = false;
      if (preferVideo && !videoDone) {
        progressed = await SabrOfflineDownloader.tryWriteNext(
          videoBuf, nextVideoSeq, writeVideo,
          (bytes: number, seq: number): void => {
            videoBytes += bytes;
            videoSeq = seq;
            nextVideoSeq = seq + 1;
          },
          (): void => {
            // readSegment() returns undefined only after isBeyondEnd() proves EOF.
            // Never skip a missing sequence: transient no-media is thrown and retried.
            videoDone = true;
          }
        );
      } else if (!audioDone) {
        progressed = await SabrOfflineDownloader.tryWriteNext(
          audioBuf, nextAudioSeq, writeAudio,
          (bytes: number, seq: number): void => {
            audioBytes += bytes;
            audioSeq = seq;
            nextAudioSeq = seq + 1;
          },
          (): void => {
            audioDone = true;
          }
        );
      }

      if (!progressed && !preferVideo && !videoDone) {
        // Fallback: try the other track once per loop.
        progressed = await SabrOfflineDownloader.tryWriteNext(
          videoBuf, nextVideoSeq, writeVideo,
          (bytes: number, seq: number): void => {
            videoBytes += bytes;
            videoSeq = seq;
            nextVideoSeq = seq + 1;
          },
          (): void => {
            videoDone = true;
          }
        );
      } else if (!progressed && preferVideo && !audioDone) {
        progressed = await SabrOfflineDownloader.tryWriteNext(
          audioBuf, nextAudioSeq, writeAudio,
          (bytes: number, seq: number): void => {
            audioBytes += bytes;
            audioSeq = seq;
            nextAudioSeq = seq + 1;
          },
          (): void => {
            audioDone = true;
          }
        );
      }

      if (progressed) {
        consecutiveFetchFails = 0;
        // Keep session play-head at the slower track so eviction does not drop needed segs.
        const headMs = Math.min(
          videoSeq > 0 ? videoBuf.getSegmentEndMs(videoSeq) : 0,
          audioSeq > 0 ? audioBuf.getSegmentEndMs(audioSeq) : 0
        );
        if (headMs > 0) {
          sabrSessionStore.setPlayHeadMs(lease.key, headMs);
        }
        const percent = SabrOfflineDownloader.overallPercent(
          videoSeq, audioSeq, videoBuf.getEndSegment(), audioBuf.getEndSegment(),
          videoBytes, audioBytes);
        onProgress?.({
          track: 'both',
          phase: 'media',
          sequence: Math.max(videoSeq, audioSeq),
          endSegment: Math.max(videoBuf.getEndSegment(), audioBuf.getEndSegment()),
          bytesWritten: videoBytes + audioBytes,
          percent,
          videoBytes,
          audioBytes,
          videoSeq,
          audioSeq
        });
      } else {
        consecutiveFetchFails++;
        if (consecutiveFetchFails >= 6) {
          throw new Error(
            `SABR dual-track stalled videoSeq=${nextVideoSeq} audioSeq=${nextAudioSeq} `
            + `vEnd=${videoBuf.getEndSegment()} aEnd=${audioBuf.getEndSegment()}`);
        }
        // Brief yield so server backoff can clear without spinning.
        await new Promise<void>((r) => setTimeout(r, 300));
      }
    }

    const finalVideoEnd = videoBuf.getEndSegment();
    const finalAudioEnd = audioBuf.getEndSegment();
    if (videoSeq <= 0 || audioSeq <= 0) {
      throw new Error(`SABR download incomplete: missing media videoSeq=${videoSeq} audioSeq=${audioSeq}`);
    }
    if (finalVideoEnd > 0 && videoSeq < finalVideoEnd) {
      throw new Error(`SABR video incomplete: last=${videoSeq} expected=${finalVideoEnd}`);
    }
    if (finalAudioEnd > 0 && audioSeq < finalAudioEnd) {
      throw new Error(`SABR audio incomplete: last=${audioSeq} expected=${finalAudioEnd}`);
    }

    onProgress?.({
      track: 'both',
      phase: 'done',
      sequence: Math.max(videoSeq, audioSeq),
      endSegment: Math.max(finalVideoEnd, finalAudioEnd),
      bytesWritten: videoBytes + audioBytes,
      percent: 100,
      videoBytes,
      audioBytes,
      videoSeq,
      audioSeq
    });
    Logger.info(TAG, `dump dual-track vItag=${videoBuf.getItag()} aItag=${audioBuf.getItag()} `
      + `vSegs=${videoSeq} aSegs=${audioSeq} vBytes=${videoBytes} aBytes=${audioBytes} `
      + `vEnd=${finalVideoEnd} aEnd=${finalAudioEnd}`);
  }

  private static async tryWriteNext(
    buf: SabrTrackBuffer,
    sequence: number,
    write: (data: Uint8Array) => void | Promise<void>,
    onOk: (bytes: number, seq: number) => void,
    onEmpty: () => void
  ): Promise<boolean> {
    try {
      const media = await buf.readSegment(false, sequence);
      if (!media) {
        onEmpty();
        return false;
      }
      await write(media);
      onOk(media.length, sequence);
      return true;
    } catch (e) {
      const msg = String(e);
      // Transient / not-available: caller may retry other track or wait.
      if (msg.indexOf('beyond end') >= 0) {
        onEmpty();
        return false;
      }
      const transient = e instanceof SabrProtocolException
        && (e.kind === 'protection' || e.kind === 'no_media');
      if (transient || msg.indexOf('segment not available') >= 0) {
        Logger.warn(TAG, `tryWriteNext itag=${buf.getItag()} seq=${sequence}: ${msg}`);
        return false;
      }
      throw e instanceof Error ? e : new Error(msg);
    }
  }

  private static overallPercent(
    videoSeq: number, audioSeq: number, vEnd: number, aEnd: number,
    videoBytes: number, audioBytes: number
  ): number {
    if (vEnd > 0 && aEnd > 0) {
      const vp = Math.min(1, videoSeq / vEnd);
      const ap = Math.min(1, audioSeq / aEnd);
      return Math.min(99, Math.round(((vp + ap) / 2) * 100));
    }
    if (vEnd > 0) {
      return Math.min(99, Math.round((videoSeq / vEnd) * 100));
    }
    if (aEnd > 0) {
      return Math.min(99, Math.round((audioSeq / aEnd) * 100));
    }
    const mb = (videoBytes + audioBytes) / (1024 * 1024);
    return Math.min(99, Math.max(2, Math.round(mb)));
  }
}
