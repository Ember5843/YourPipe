/**
 * SABR session bootstrap (PipePipe YoutubeSabrInfo).
 * Session/UMP playback lives in YoutubeSabrSession.
 */
export type SabrClientProfileKey = 'mweb' | 'web';

export interface YoutubeSabrFormatMeta {
  itag: number;
  mimeType?: string;
  bitrate?: number;
  width?: number;
  height?: number;
  lastModified?: string;
  xtags?: string;
  isAudio: boolean;
  isVideo: boolean;
  qualityLabel?: string;
  codecs?: string;
  audioTrackId?: string;
  audioTrackName?: string;
  /** acont from xtags when present: original | dubbed | descriptive | … */
  audioTrackType?: string;
  isOriginalAudio?: boolean;
  /** Optional progressive init URL (rare on pure SABR). */
  initializationUrl?: string;
  initRangeStart?: number;
  initRangeEnd?: number;
  contentLength?: number;
  approxDurationMs?: number;
  drc?: boolean;
}

export class YoutubeSabrInfo {
  profile: SabrClientProfileKey;
  videoId: string;
  cpn: string;
  clientVersion: string;
  visitorData?: string;
  serverAbrStreamingUrl?: string;
  videoPlaybackUstreamerConfig?: string;
  formats: YoutubeSabrFormatMeta[];

  constructor(
    profile: SabrClientProfileKey,
    videoId: string,
    cpn: string,
    clientVersion: string,
    formats: YoutubeSabrFormatMeta[]
  ) {
    this.profile = profile;
    this.videoId = videoId;
    this.cpn = cpn;
    this.clientVersion = clientVersion;
    this.formats = formats;
  }

  findBestAudioFormat(): YoutubeSabrFormatMeta | undefined {
    let best: YoutubeSabrFormatMeta | undefined = undefined;
    for (const format of this.formats) {
      if (!format.isAudio) {
        continue;
      }
      if (!best) {
        best = format;
        continue;
      }
      const preferTrack = !!format.isOriginalAudio && !best.isOriginalAudio;
      const preferBitrate = format.isOriginalAudio === best.isOriginalAudio
        && (format.bitrate ?? 0) > (best.bitrate ?? 0);
      if (preferTrack || preferBitrate) {
        best = format;
      }
    }
    return best;
  }

  findPreferredVideoFormat(maxHeight?: number): YoutubeSabrFormatMeta | undefined {
    let best: YoutubeSabrFormatMeta | undefined = undefined;
    for (const format of this.formats) {
      if (!format.isVideo) {
        continue;
      }
      if (maxHeight !== undefined && (format.height ?? 0) > maxHeight) {
        continue;
      }
      if (!best || (format.height ?? 0) > (best.height ?? 0)
        || ((format.height ?? 0) === (best.height ?? 0)
          && (format.bitrate ?? 0) > (best.bitrate ?? 0))) {
        best = format;
      }
    }
    return best;
  }

  findFormatByItag(itag: number): YoutubeSabrFormatMeta | undefined {
    for (const format of this.formats) {
      if (format.itag === itag) {
        return format;
      }
    }
    return undefined;
  }

  /**
   * Multi-language audio reuses the same itag (e.g. 140) with different audioTrackId.
   * Prefer exact itag+track match; fall back to first itag only when track is empty.
   */
  findFormatByItagAndTrack(
    itag: number,
    audioTrackId?: string
  ): YoutubeSabrFormatMeta | undefined {
    const track = (audioTrackId || '').trim();
    if (track.length > 0) {
      for (const format of this.formats) {
        if (format.itag === itag && (format.audioTrackId || '') === track) {
          return format;
        }
      }
    }
    return this.findFormatByItag(itag);
  }
}
