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
