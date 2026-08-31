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
import { ItagItem } from 'youtube_core';
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

/** classifyStreamList 的返回：分类结果 + 播放路径用的合并视频列表。 */
export interface StreamClassification {
  categories: StreamCategories;
  mergedVideoList: VideoEntry[];
}

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
   * 获取流的友好质量显示名称。
   * 权威来源是 extractor 填充的 quality（youtube_core ItagItem，
   * 经 YouTubePlayService.mapToPlayerStreams 映射）；ItagItem 表仅作为
   * 未携带 quality 字段的流的兜底，不再参与正常路径。
   */
  public static getFriendlyQuality(stream: StreamInfo): string {
    let baseQuality = stream.quality || stream.videoQuality || '';
    if (!baseQuality && stream.audioQuality) {
      baseQuality = stream.audioQuality.replace('AUDIO_QUALITY_', '').toLowerCase();
    }
    if (!baseQuality) {
      baseQuality = PlayerModel.itagFallbackQuality(stream.itag);
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

  /**
   * itag 兜底质量标签：查 youtube_core ItagItem 表（视频取 resolutionString，
   * 音频取平均码率）。ItagItem 表之外或未带 itag 的流返回 'Unknown'。
   */
  private static itagFallbackQuality(itag?: number): string {
    if (itag === undefined || !ItagItem.isSupported(itag)) {
      return 'Unknown';
    }
    const item = ItagItem.getItag(itag);
    const resolution = item.getResolutionString();
    if (resolution) {
      return resolution;
    }
    const avgBitrate = item.getAverageBitrate();
    return avgBitrate > 0 ? `${avgBitrate}kbps` : 'Unknown';
  }

  /** SABR 流判定唯一实现（播放 / 下载 / 离线共用）。 */
  public static isSabrStream(stream?: StreamInfo | null): boolean {
    if (!stream) {
      return false;
    }
    const delivery = (stream.deliveryMethod || '').toUpperCase();
    const kind = (stream.kind || '').toLowerCase();
    return delivery === 'SABR' || kind === 'sabr' || !!stream.sabrInfo?.serverAbrStreamingUrl;
  }

  /**
   * 流分类的唯一实现：播放路径（classifyStreams）与下载路径（entry
   * VideoDetails / DownloadDialog）共用。规则：
   * - manifest（kind=manifest_hls/manifest_dash，或 HLS delivery 且无视频）是
   *   控制资源，不进媒体列表；
   * - 无 sabrInfo 引导的 SABR 残桩直接丢弃；
   * - requirePlayableUrl=true（下载路径）时，既非 SABR 又无媒体 URL 的流不可
   *   下载，丢弃；
   * - 其余按 extractor 显式字段 hasVideo/hasAudio 分类，老响应回退到 kind。
   * 保持响应顺序；需要排序的调用方自行排序。
   */
  public static classifyStreamList(streams: StreamInfo[], requirePlayableUrl: boolean = false): StreamClassification {
    const categories: StreamCategories = {
      audio: [],
      video: [],
      dashManifest: [],
      hlsManifest: [],
      progressive: []
    };
    const mergedVideoList: VideoEntry[] = [];

    streams.forEach((stream: StreamInfo) => {
      const kind = stream.kind?.toLowerCase() || '';
      const delivery = stream.deliveryMethod?.toUpperCase() || '';

      // Manifests are control resources, not selectable media entries.
      if (kind === 'manifest_hls' || (delivery === 'HLS' && !stream.hasVideo)) {
        categories.hlsManifest.push(stream);
        return;
      }
      if (kind === 'manifest_dash') {
        categories.dashManifest.push(stream);
        return;
      }

      // SABR stubs without bootstrap cannot be played.
      if (PlayerModel.isSabrStream(stream)) {
        if (!stream.sabrInfo || !stream.sabrInfo.serverAbrStreamingUrl) {
          return;
        }
      } else if (requirePlayableUrl && !stream.url) {
        return;
      }

      // Classify only with fields explicitly returned by the extractor.
      if (stream.hasVideo === true) {
        if (stream.hasAudio === true) {
          categories.progressive.push(stream);
        } else {
          categories.video.push(stream);
        }
        mergedVideoList.push({ stream } as VideoEntry);
        return;
      }
      if (stream.hasAudio === true) {
        categories.audio.push(stream);
        return;
      }

      // Older responses may omit hasVideo/hasAudio but still provide an explicit kind.
      if (kind === 'progressive') {
        categories.progressive.push(stream);
        mergedVideoList.push({ stream } as VideoEntry);
      } else if (kind === 'video_only') {
        categories.video.push(stream);
        mergedVideoList.push({ stream } as VideoEntry);
      } else if (kind === 'audio_only') {
        categories.audio.push(stream);
      }
    });

    return { categories, mergedVideoList };
  }

  public classifyStreams(streams: StreamInfo[], preferredLanguage?: string, audioMaxBitrate?: number): void {
    const classification = PlayerModel.classifyStreamList(streams);
    this.categorizedStreams = classification.categories;
    this.mergedVideoList = classification.mergedVideoList;

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
   * Live quality management: replace mergedVideoList with per-variant entries
   * once background parsing delivered HLS variants. No synthetic "Auto" master
   * entry — the menu shows real variants only, with the playing one selected.
   * For live, the pre-merge list held DASH/OTF adaptive entries which cannot
   * be played through the proxy (no SIDX), so the list is replaced wholesale
   * instead of appended to.
   */
  public mergeLiveHlsVariants(variants: StreamInfo[]): void {
    const seen = new Set<string>();
    const sorted = variants.filter((s: StreamInfo) => {
      if (!s.url || s.hasVideo !== true || seen.has(s.url)) return false;
      seen.add(s.url);
      return true;
    }).slice().sort((a: StreamInfo, b: StreamInfo) => (b.height || 0) - (a.height || 0));
    if (sorted.length === 0) return;
    const list: VideoEntry[] = [];
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
    Logger.info(TAG, `live HLS variants merged: variants=${sorted.length} `
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
