import { VideoItem } from 'youtube_core';

export class PlaylistItem {
  playlistId: string;
  title: string;
  coverUrl: string;

  constructor(playlistId: string, title: string, coverUrl: string = '') {
    this.playlistId = playlistId;
    this.title = title;
    this.coverUrl = coverUrl;
  }
}

/** A locally saved play queue (non-YouTube playlist). */
export interface StoredLocalQueue {
  id: string;
  name: string;
  videos: VideoItem[];
  createdAt: number;
}
