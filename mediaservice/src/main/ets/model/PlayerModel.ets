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

interface TrackRank {
  trackId: string;
  score: number;
  streams: StreamInfo[];
}

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
  height: number;
  resolutionLabel: string;
  codecLabel: string;
  deliveryMethod: 'DASH' | 'HLS' | 'PROGRESSIVE_HTTP';
  requiresSeparateAudio: boolean;
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

    streams.forEach(stream => {
      const itagMeta = stream.itag ? ITAG_MAP[stream.itag] : undefined;
      const kind = stream.kind?.toLowerCase() || '';
      const delivery = stream.deliveryMethod?.toUpperCase() || '';

      // SABR: classify as separated A/V when bootstrap present; skip bare stubs.
      if (kind === 'sabr' || delivery === 'SABR') {
        if (!stream.sabrInfo || !stream.sabrInfo.serverAbrStreamingUrl) {
          return;
        }
        if (stream.hasVideo && !stream.hasAudio) {
          this.categorizedStreams.video.push(stream);
        } else if (stream.hasAudio && !stream.hasVideo) {
          this.categorizedStreams.audio.push(stream);
        }
        return;
      }

      // 1. 优先根据 ITAG 元数据分类
      if (itagMeta) {
        if (itagMeta.type === 'muxed') {
          this.categorizedStreams.progressive.push(stream);
          return;
        } else if (itagMeta.type === 'video') {
          this.categorizedStreams.video.push(stream);
          return;
        } else if (itagMeta.type === 'audio') {
          this.categorizedStreams.audio.push(stream);
          return;
        }
      }

      // 2. 兜底逻辑：根据 kind 或 deliveryMethod 识别
      if (kind === 'progressive' || delivery === 'PROGRESSIVE_HTTP') {
        this.categorizedStreams.progressive.push(stream);
      } else if (kind === 'manifest_hls' || delivery === 'HLS') {
        this.categorizedStreams.hlsManifest.push(stream);
      } else if (kind === 'manifest_dash') {
        this.categorizedStreams.dashManifest.push(stream);
      } else if (kind === 'video_only' || (delivery === 'DASH' && stream.videoQuality)) {
        this.categorizedStreams.video.push(stream);
      } else if (kind === 'audio_only' || (delivery === 'DASH' && stream.audioQuality)) {
        this.categorizedStreams.audio.push(stream);
      }
    });

    this.categorizedStreams.video.sort((a, b) => {
      const hA = ITAG_MAP[a.itag!]?.height || a.height || 0;
      const hB = ITAG_MAP[b.itag!]?.height || b.height || 0;
      if (hB !== hA) return hB - hA; // 主键：分辨率降序
      // 次键：codec 优先级（与 AvPlayerController 一致）
      // HEVC/H.264 优先；VP9/AV1 靠后（无硬解时选流侧会再过滤）
      const codecPriority = (s: StreamInfo): number => {
        const c = (s.codecs || '').toLowerCase();
        if (c.startsWith('hvc1') || c.startsWith('hev1')) return 50;
        if (c.startsWith('avc1') || c.startsWith('avc3')) return 40;
        if (c.startsWith('vp9')  || c.startsWith('vp09')) return 30;
        if (c.startsWith('av01'))                          return 20;
        return 0;
      };
      return codecPriority(b) - codecPriority(a);
    });
    
    // 音频分组与排序 (Audio grouping and sorting matching NewPipe)
    // 1. Group streams by audioTrackId
    const trackGroups = new Map<string, StreamInfo[]>();
    this.categorizedStreams.audio.forEach(stream => {
      const trackId = stream.audioTrackId || '';
      if (!trackGroups.has(trackId)) {
        trackGroups.set(trackId, []);
      }
      trackGroups.get(trackId)!.push(stream);
    });

    // 2. Rank each track
    const trackRanks: TrackRank[] = Array.from(trackGroups.entries()).map((entry: [string, StreamInfo[]]) => {
      const trackId = entry[0];
      const trackStreams = entry[1];
      const s = trackStreams[0]; // Representative stream for the track
      let score = 0;
      const lang = s.audioLanguage?.toLowerCase() || '';
      const type = s.audioTrackType?.toUpperCase() || '';
      const prefLang = preferredLanguage?.toLowerCase() || '';
      
      // a. Language match
      if (prefLang && lang.startsWith(prefLang)) {
        score += 1000;
      } else if (lang.startsWith('en')) {
        score += 10; // English fallback
      }
      
      // b. Track type match (NewPipe default: ORIGINAL > DUBBED > DESCRIPTIVE)
      if (type === 'ORIGINAL') {
        score += 100;
      } else if (type === 'DUBBED') {
        score += 50;
      } else if (type === 'DESCRIPTIVE') {
        score += 10;
      }
      
      const rank: TrackRank = { trackId: trackId, score: score, streams: trackStreams };
      return rank;
    });

    // Sort tracks by score descending
    trackRanks.sort((a, b) => b.score - a.score);

    // 3. Sort streams within each track and flatten
    const sortedAudioStreams: StreamInfo[] = [];
    // 优先高码率 AAC(140/141)，其次 Opus(251/250)
    // 如果调用方传入了 audioMaxBitrate，过滤掉超出上限的 itag
    const rawPreferredAudioItags = [141, 140, 258, 256, 251, 250, 249, 172, 171];
    const preferredAudioItags = (audioMaxBitrate !== undefined && audioMaxBitrate < 9999)
      ? rawPreferredAudioItags.filter(itag => {
          const meta = ITAG_MAP[itag];
          return !meta || !meta.bitrate || meta.bitrate <= audioMaxBitrate;
        })
      : rawPreferredAudioItags;

    trackRanks.forEach(track => {
      track.streams.sort((a, b) => {
        // Format rank
        let rankA = preferredAudioItags.indexOf(a.itag || -1);
        let rankB = preferredAudioItags.indexOf(b.itag || -1);
        if (rankA === -1) rankA = 999;
        if (rankB === -1) rankB = 999;
        if (rankA !== rankB) return rankA - rankB;

        // Bitrate fallback
        const bA = ITAG_MAP[a.itag!]?.bitrate || a.bitrate || 0;
        const bB = ITAG_MAP[b.itag!]?.bitrate || b.bitrate || 0;
        return bB - bA;
      });
      sortedAudioStreams.push(...track.streams);
    });

    this.categorizedStreams.audio = sortedAudioStreams;

    const codecShortName = (codecs?: string): string => {
      if (!codecs) return '';
      const c = codecs.toLowerCase();
      if (c.startsWith('av01')) return 'AV1';
      if (c.startsWith('vp9') || c.startsWith('vp09')) return 'VP9';
      if (c.startsWith('hvc1') || c.startsWith('hev1')) return 'H265';
      if (c.startsWith('avc1') || c.startsWith('avc3')) return 'H264';
      return codecs.split('.')[0].toUpperCase();
    };

    const heightOf = (s: StreamInfo): number => {
      return ITAG_MAP[s.itag!]?.height || s.height || 0;
    };

    const dedupVideoMap = new Map<string, StreamInfo>();
    const bucketsToMerge: StreamInfo[][] = [
      this.categorizedStreams.progressive,
      this.categorizedStreams.hlsManifest,
      this.categorizedStreams.video,
    ];
    for (const bucket of bucketsToMerge) {
      for (const stream of bucket) {
        const h = heightOf(stream);
        const codec = codecShortName(stream.codecs);
        const key = `${codec}|${h}`;
        dedupVideoMap.set(key, stream);
      }
    }

    const getDeliveryFromBucket = (stream: StreamInfo): string => {
      const d = (stream.deliveryMethod || '').toUpperCase();
      if (d === 'SABR' || stream.kind?.toLowerCase() === 'sabr') return 'SABR';
      if (this.categorizedStreams.video.includes(stream)) return 'DASH';
      if (this.categorizedStreams.hlsManifest.includes(stream)) return 'HLS';
      return 'PROGRESSIVE_HTTP';
    };

    const codecSortPriority = (label: string): number => {
      if (label === 'H265') return 50;
      if (label === 'H264') return 40;
      if (label === 'VP9') return 30;
      if (label === 'AV1') return 20;
      return 0;
    };

    this.mergedVideoList = Array.from(dedupVideoMap.values())
      .map(stream => {
        const h = heightOf(stream);
        const codec = codecShortName(stream.codecs);
        const delivery = getDeliveryFromBucket(stream);
        return {
          stream, height: h,
          resolutionLabel: stream.quality || '',
          codecLabel: codec || 'Unknown',
          deliveryMethod: delivery,
          requiresSeparateAudio: delivery !== 'PROGRESSIVE_HTTP' && delivery !== 'HLS',
        } as VideoEntry;
      })
      .sort((a, b) => {
        if (b.height !== a.height) return b.height - a.height;
        return codecSortPriority(b.codecLabel) - codecSortPriority(a.codecLabel);
      });

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
  }

  public getStreamCategories(): StreamCategories { return this.categorizedStreams; }
  public getMergedVideoList(): VideoEntry[] { return this.mergedVideoList; }
  public getCurrentStreams(): CurrentStreams { return { video: this.currentVideoStream, audio: this.currentAudioStream, manifest: this.currentManifestStream }; }
  public updateVideoStream(stream: StreamInfo | undefined): void { this.currentVideoStream = stream; }
  public updateAudioStream(stream: StreamInfo | undefined): void { this.currentAudioStream = stream; }
}
