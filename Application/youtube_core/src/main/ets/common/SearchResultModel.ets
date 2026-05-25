import { VideoItem } from './VideoModel';

export enum SearchInfoType {
  STREAM = 'STREAM',
  CHANNEL = 'CHANNEL',
  PLAYLIST = 'PLAYLIST'
}

export class SearchStreamItem {
  id: number;
  type: SearchInfoType = SearchInfoType.STREAM;
  video: VideoItem;

  constructor(id: number, video: VideoItem) {
    this.id = id;
    this.video = video;
  }
}

export class SearchChannelItem {
  id: number;
  type: SearchInfoType = SearchInfoType.CHANNEL;
  channelId: string;
  name: string;
  subscriberText: string;
  videoCountText: string;
  avatarUrl: string;
  description: string;
  thumbnailColor: string;
  handle: string;

  constructor(
    id: number,
    channelId: string,
    name: string,
    subscriberText: string,
    videoCountText: string,
    avatarUrl: string,
    description: string,
    thumbnailColor: string,
    handle: string = ""
  ) {
    this.id = id;
    this.channelId = channelId;
    this.name = name;
    this.subscriberText = subscriberText;
    this.videoCountText = videoCountText;
    this.avatarUrl = avatarUrl;
    this.description = description;
    this.thumbnailColor = thumbnailColor;
    this.handle = handle;
  }
}

export class SearchPlaylistItem {
  id: number;
  type: SearchInfoType = SearchInfoType.PLAYLIST;
  playlistId: string;
  name: string;
  uploaderName: string;
  videoCountText: string;
  coverUrl: string;
  description: string;
  thumbnailColor: string;

  constructor(
    id: number,
    playlistId: string,
    name: string,
    uploaderName: string,
    videoCountText: string,
    coverUrl: string,
    description: string,
    thumbnailColor: string
  ) {
    this.id = id;
    this.playlistId = playlistId;
    this.name = name;
    this.uploaderName = uploaderName;
    this.videoCountText = videoCountText;
    this.coverUrl = coverUrl;
    this.description = description;
    this.thumbnailColor = thumbnailColor;
  }
}

export type SearchInfoItem = SearchStreamItem | SearchChannelItem | SearchPlaylistItem;

export interface SearchPageResult {
  items: Array<SearchInfoItem>;
  nextPageToken: string | null;
}

