import { SearchInfoItem, VideoItem } from 'youtube_core';

export interface HomeFeedChip {
  label: string;
  continuationToken: string;
  isSelected: boolean;
  /** 兜底搜索词（未返回 continuationToken 时用搜索接口拉取）。 */
  searchQuery?: string;
  /** 是否为「我的分类」聚合分组页签。 */
  isMyCategories?: boolean;
}

export interface HomeFeedSection {
  title: string;
  items: Array<VideoItem>;
  chipIndex?: number;
}

export interface VideoBuildResult {
  items: Array<VideoItem>;
  nextPageToken: string | null;
}

export interface SearchBuildResult {
  items: Array<SearchInfoItem>;
  nextPageToken: string | null;
}
