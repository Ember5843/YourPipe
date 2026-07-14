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

import { media } from '@kit.MediaKit';
import { SubtitleTrack, YoutubeSabrInfo } from 'youtube_core';

export interface StreamInfo {
  url: string;
  /** When false, url is a session reference (SABR), not progressive media. */
  isUrl?: boolean;
  kind: string;
  sourceClient?: string;
  itag?: number;
  hasVideo?: boolean;
  hasAudio?: boolean;
  quality?: string;
  format?: string;
  audioQuality?: string;
  videoQuality?: string;
  mimeType?: string;
  codecs?: string;
  bitrate?: number;
  fps?: number;
  deliveryMethod?: string;
  height?: number;
  width?: number;
  audioLanguage?: string;
  audioTrackId?: string;
  audioTrackName?: string;
  audioTrackType?: string;
  // DASH SegmentBase fields (from YouTube InnerTube API response)
  initRangeStart?: number;
  initRangeEnd?: number;
  indexRangeStart?: number;
  indexRangeEnd?: number;
  contentLength?: number;
  approxDurationMs?: number;
  isOtf?: boolean;
  /** SABR bootstrap shared across audio/video streams of the same extract. */
  sabrInfo?: YoutubeSabrInfo;
}

export interface SelectOption {
  value: ResourceStr;
}

export interface VideoData {
  mediaSource?: media.MediaSource;
  url?: string;
  headers?: Record<string, string>;
  name: Resource;
  description: ResourceStr;
  author?: string;
  channelId?: string;
  videoDescription?: string;
  time: string;
  controller?: VideoController;
  auto: boolean;
  head: Resource;
  likeCount: string;
  /** Optional RYD / next-response dislike count for display. */
  dislikeCount?: string;
  commentCount: string;
  shareCount: string;
  play: boolean;
  index: number;
  width?: number;
  height?: number;
  error?: string;
  streams?: StreamInfo[];
  subtitleTracks?: SubtitleTrack[];
  isLive?: boolean;
  hlsUrl?: string;
  dashMpdUrl?: string;
  thumbnailUrl?: string;
  videoId?: string;
  viewCount?: number;
  publishDate?: string;
  tags?: string[];
}
