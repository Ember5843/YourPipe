/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { StreamInfo } from './VideoData';
import Logger from '../utils/Logger';

const TAG: string = '[PlayerLog][PlayerModel]';

// 流分类接口
export interface StreamCategories {
  audio: StreamInfo[];
  video: StreamInfo[];
  dashManifest: StreamInfo[];
  hlsManifest: StreamInfo[];
  progressive: StreamInfo[];
}

// 当前播放的流
export interface CurrentStreams {
  video: StreamInfo | undefined;
  audio: StreamInfo | undefined;
  manifest: StreamInfo | undefined;
}

export interface VideoEntry {
  stream: StreamInfo;
}

export interface AudioTrackOption {
  trackId: string;
  label: string;
}

// YouTube itag 映射表 (2024-2026 完整版)
export interface ItagMetadata {
  quality: string;
  type: 'video' | 'audio' | 'muxed';
  height?: number;
  bitrate?: number; // 约等于的码率，用于排序
}

export const ITAG_MAP: Record<number, ItagMetadata> = {
  // --- Muxed (Video + Audio) (Progressive) ---
  17: { quality: '144p', type: 'muxed', height: 144 },
  36: { quality: '240p', type: 'muxed', height: 240 },
  18: { quality: '360p', type: 'muxed', height: 360 },
  34: { quality: '360p', type: 'muxed', height: 360 },
  35: { quality: '480p', type: 'muxed', height: 480 },
  59: { quality: '480p', type: 'muxed', height: 480 },
  78: { quality: '480p', type: 'muxed', height: 480 },
  22: { quality: '720p', type: 'muxed', height: 720 },
  37: { quality: '1080p', type: 'muxed', height: 1080 },
  38: { quality: '1080p', type: 'muxed', height: 1080 },
  43: { quality: '360p', type: 'muxed', height: 360 },
  44: { quality: '480p', type: 'muxed', height: 480 },
  45: { quality: '720p', type: 'muxed', height: 720 },
  46: { quality: '1080p', type: 'muxed', height: 1080 },

  // --- DASH Audio Only ---
  171: { quality: 'Medium', type: 'audio', bitrate: 128 },
  172: { quality: 'High', type: 'audio', bitrate: 256 },
  599: { quality: 'UltraLow', type: 'audio', bitrate: 32 },
  139: { quality: 'Low', type: 'audio', bitrate: 48 },
  140: { quality: 'Medium', type: 'audio', bitrate: 128 },
  141: { quality: 'High', type: 'audio', bitrate: 256 },
  600: { quality: 'UltraLow', type: 'audio', bitrate: 35 },
  249: { quality: 'Low', type: 'audio', bitrate: 50 },
  250: { quality: 'Medium', type: 'audio', bitrate: 70 },
  251: { quality: 'High', type: 'audio', bitrate: 160 },
  256: { quality: 'High', type: 'audio', bitrate: 192 },
  258: { quality: 'High', type: 'audio', bitrate: 384 },

  // --- DASH Video Only (MPEG-4, VP9, AV1) ---
  160: { quality: '144p', type: 'video', height: 144 },
  394: { quality: '144p', type: 'video', height: 144 },
  278: { quality: '144p', type: 'video', height: 144 },
  
  133: { quality: '240p', type: 'video', height: 240 },
  395: { quality: '240p', type: 'video', height: 240 },
  242: { quality: '240p', type: 'video', height: 240 },

  134: { quality: '360p', type: 'video', height: 360 },
  396: { quality: '360p', type: 'video', height: 360 },
  243: { quality: '360p', type: 'video', height: 360 },

  135: { quality: '480p', type: 'video', height: 480 },
  212: { quality: '480p', type: 'video', height: 480 },
  397: { quality: '480p', type: 'video', height: 480 },
  244: { quality: '480p', type: 'video', height: 480 },
  245: { quality: '480p', type: 'video', height: 480 },
  246: { quality: '480p', type: 'video', height: 480 },

  136: { quality: '720p', type: 'video', height: 720 },
  398: { quality: '720p', type: 'video', height: 720 },
  247: { quality: '720p', type: 'video', height: 720 },
  298: { quality: '720p60', type: 'video', height: 720 },
  302: { quality: '720p60', type: 'video', height: 720 },

  137: { quality: '1080p', type: 'video', height: 1080 },
  399: { quality: '1080p', type: 'video', height: 1080 },
  248: { quality: '1080p', type: 'video', height: 1080 },
  299: { quality: '1080p60', type: 'video', height: 1080 },
  303: { quality: '1080p60', type: 'video', height: 1080 },

  400: { quality: '1440p', type: 'video', height: 1440 },
  271: { quality: '1440p', type: 'video', height: 1440 },
  308: { quality: '1440p60', type: 'video', height: 1440 },

  266: { quality: '2160p', type: 'video', height: 2160 },
  401: { quality: '2160p', type: 'video', height: 2160 },
  272: { quality: '2160p', type: 'video', height: 2160 },
  313: { quality: '2160p', type: 'video', height: 2160 },
  315: { quality: '2160p60', type: 'video', height: 2160 },

  402: { quality: '4320p', type: 'video', height: 4320 }
};

@Observed
export class PlayerModel {
  @Track public categorizedStreams: StreamCategories = {
    audio: [],
    video: [],
    dashManifest: [],
    hlsManifest: [],
    progressive: []
  };

  @Track public mergedVideoList: VideoEntry[] = [];
  /** True once background-parsed live HLS variants have been merged into
   * mergedVideoList. UI uses it to unhide the quality menu for live playback. */
  @Track public liveQualityReady: boolean = false;

  @Track public currentVideoStream?: StreamInfo;
  @Track public currentAudioStream?: StreamInfo;
  @Track public currentManifestStream?: StreamInfo;

  constructor() {}

  /**
   * 获取流的友好质量显示名称
   */
  public static getFriendlyQuality(stream: StreamInfo): string {
    const itagMeta = stream.itag ? ITAG_MAP[stream.itag] : undefined;
    let baseQuality = 'Unknown';
    
    if (itagMeta) {
      baseQuality = itagMeta.quality;
    } else if (stream.audioQuality) {
      baseQuality = stream.audioQuality.replace('AUDIO_QUALITY_', '').toLowerCase();
    } else {
      baseQuality = stream.videoQuality || stream.quality || 'Unknown';
    }

    let result = baseQuality;
    
    // 如果有语言信息，加在后面
    if (stream.audioLanguage || stream.audioTrackName) {
      const lang = stream.audioTrackName || stream.audioLanguage;
      result += ` (${lang})`;
    }

    // 在末尾加上方括号带上 itag
    return stream.itag ? `${result} [${stream.itag}]` : result;
  }

  public classifyStreams(streams: StreamInfo[], preferredLanguage?: string, audioMaxBitrate?: number): void {
    this.categorizedStreams = {
      audio: [],
      video: [],
      dashManifest: [],
      hlsManifest: [],
      progressive: []
    };

    this.mergedVideoList = [];

    streams.forEach((stream: StreamInfo) => {
      const kind = stream.kind?.toLowerCase() || '';
      const delivery = stream.deliveryMethod?.toUpperCase() || '';

      // Manifests are control resources, not selectable media entries.
      if (kind === 'manifest_hls' || (delivery === 'HLS' && !stream.hasVideo)) {
        this.categorizedStreams.hlsManifest.push(stream);
        return;
      }
      if (kind === 'manifest_dash') {
        this.categorizedStreams.dashManifest.push(stream);
        return;
      }

      // SABR stubs without bootstrap cannot be played.
      if (kind === 'sabr' || delivery === 'SABR') {
        if (!stream.sabrInfo || !stream.sabrInfo.serverAbrStreamingUrl) {
          return;
        }
      }

      // Classify only with fields explicitly returned by the extractor.
      if (stream.hasVideo === true) {
        if (stream.hasAudio === true) {
          this.categorizedStreams.progressive.push(stream);
        } else {
          this.categorizedStreams.video.push(stream);
        }
        this.mergedVideoList.push({ stream } as VideoEntry);
        return;
      }
      if (stream.hasAudio === true) {
        this.categorizedStreams.audio.push(stream);
        return;
      }

      // Older responses may omit hasVideo/hasAudio but still provide an explicit kind.
      if (kind === 'progressive') {
        this.categorizedStreams.progressive.push(stream);
        this.mergedVideoList.push({ stream } as VideoEntry);
      } else if (kind === 'video_only') {
        this.categorizedStreams.video.push(stream);
        this.mergedVideoList.push({ stream } as VideoEntry);
      } else if (kind === 'audio_only') {
        this.categorizedStreams.audio.push(stream);
      }
    });

// UI lists intentionally preserve response order.
    // The user's preferred audio language is honoured in
    // AvPlayerController.filterAudioStreamsByLanguage at selection time so
    // manual track picks keep this response order intact.
    void preferredLanguage;
    void audioMaxBitrate;
    Logger.info(TAG, `audio streams listed: ${this.categorizedStreams.audio.length} `
      + this.categorizedStreams.audio.map((s) =>
        `${s.audioTrackName || s.audioLanguage || s.audioTrackId || '-'}[${s.itag}]`
      ).join(', '));

    Logger.info(TAG, `Streams categorized: 
      Audio: ${this.categorizedStreams.audio.length}, 
      Video: ${this.categorizedStreams.video.length}, 
      DASH Manifest: ${this.categorizedStreams.dashManifest.length},
      HLS Manifest: ${this.categorizedStreams.hlsManifest.length},
      Progressive: ${this.categorizedStreams.progressive.length}`);
    
    // 不再自动选择默认播放流，仅完成分类
    this.currentVideoStream = undefined;
    this.currentAudioStream = undefined;
    this.currentManifestStream = undefined;
    this.liveQualityReady = false;
  }

  public getStreamCategories(): StreamCategories { return this.categorizedStreams; }
  /**
   * Live quality management: replace mergedVideoList with [Auto(master),
   * ...per-variant entries] once background parsing delivered HLS variants.
   * For live, the pre-merge list held DASH/OTF adaptive entries which cannot
   * be played through the proxy (no SIDX), so the list is replaced wholesale
   * instead of appended to.
   */
  public mergeLiveHlsVariants(variants: StreamInfo[], masterUrl: string): void {
    const seen = new Set<string>();
    const sorted = variants.filter((s: StreamInfo) => {
      if (!s.url || s.hasVideo !== true || seen.has(s.url)) return false;
      seen.add(s.url);
      return true;
    }).slice().sort((a: StreamInfo, b: StreamInfo) => (b.height || 0) - (a.height || 0));
    if (sorted.length === 0) return;
    const list: VideoEntry[] = [];
    if (masterUrl.length > 0) {
      const autoStream: StreamInfo = {
        url: masterUrl,
        kind: 'manifest_hls',
        deliveryMethod: 'HLS',
        hasVideo: true,
        hasAudio: true,
        mimeType: 'application/vnd.apple.mpegurl',
        sourceClient: 'hls-auto',
      };
      list.push({ stream: autoStream } as VideoEntry);
    }
    for (const s of sorted) {
      list.push({ stream: s } as VideoEntry);
      // Keep categories coherent for future per-track audio work.
      if (s.hasAudio === true) {
        this.categorizedStreams.progressive.push(s);
      } else {
        this.categorizedStreams.video.push(s);
      }
    }
    this.mergedVideoList = list;
    this.liveQualityReady = true;
    Logger.info(TAG, `live HLS variants merged: auto=${masterUrl.length > 0} variants=${sorted.length} `
      + sorted.map((s: StreamInfo) => s.quality || `${s.height}p`).join(','));
  }
  public getMergedVideoList(): VideoEntry[] { return this.mergedVideoList; }
  public getCurrentStreams(): CurrentStreams { return { video: this.currentVideoStream, audio: this.currentAudioStream, manifest: this.currentManifestStream }; }
  public updateVideoStream(stream: StreamInfo | undefined): void { this.currentVideoStream = stream; }
  public updateAudioStream(stream: StreamInfo | undefined): void { this.currentAudioStream = stream; }

  /** Flat list of all audio streams for UI Select (like quality list). */
  public getAudioStreamList(): StreamInfo[] {
    return this.categorizedStreams.audio.slice();
  }

  public getCurrentAudioIndex(): number {
    const list = this.categorizedStreams.audio;
    const cur = this.currentAudioStream;
    if (!cur) {
      return 0;
    }
    const idx = list.findIndex((s: StreamInfo) =>
      s === cur
      || (s.itag === cur.itag
        && (s.audioTrackId || '') === (cur.audioTrackId || '')
        && (s.bitrate || 0) === (cur.bitrate || 0))
    );
    return idx >= 0 ? idx : 0;
  }
}
