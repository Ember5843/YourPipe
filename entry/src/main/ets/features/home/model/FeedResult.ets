import { SearchInfoItem, VideoItem } from 'youtube_core';

export interface VideoBuildResult {
  items: Array<VideoItem>;
  nextPageToken: string | null;
}

export interface SearchBuildResult {
  items: Array<SearchInfoItem>;
  nextPageToken: string | null;
}
