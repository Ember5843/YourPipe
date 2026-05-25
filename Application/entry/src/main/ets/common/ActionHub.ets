import { VideoItem } from 'youtube_core';
import { SearchChannelItem, SearchPlaylistItem } from 'youtube_core';

export type CallbackFunc = Function;

export enum ActionHubEvent {
  EXIT_FULLSCREEN = 'exitFullScreen',
  EXIT_COMMENT_REPLIES = 'exitCommentReplies',
  IS_REPLIES_OPEN_CHANGE = 'isRepliesOpenChange',
}

export class ActionHub {
  openSearch: () => void = () => {};
  openVideo: (video: VideoItem) => void = () => {};
  openChannel: (channel: SearchChannelItem) => void = () => {};
  openChannelById: (channelId: string, channelName: string, channelAvatarUrl: string, channelHandle: string) => void = () => {};
  openPlaylist: (playlist: SearchPlaylistItem) => void = () => {};
  closePage: () => void = () => {};
  addFavorite: (video: VideoItem) => void = () => {};
  removeFavorite: (videoId: string) => void = () => {};
  addSubscription: (channel: SearchChannelItem) => void = () => {};
  removeSubscription: (channelId: string) => void = () => {};
  addPlaylist: (playlist: SearchPlaylistItem) => void = () => {};
  removePlaylist: (playlistId: string) => void = () => {};
  shareVideo: (video: VideoItem) => void = () => {};
  shareChannel: (channel: SearchChannelItem) => void = () => {};
  sharePlaylist: (playlist: SearchPlaylistItem) => void = () => {};
  setSearchLanguage: (languageCode: string) => void = () => {};
  setSearchCountry: (countryCode: string) => void = () => {};
  setSearchLocale: (languageCode: string, countryCode: string) => void = () => {};
  resetSearchLocale: () => void = () => {};

  // 事件监听和触发方法
  private events: Map<string, Array<CallbackFunc>> = new Map();

  on(event: ActionHubEvent, callback: CallbackFunc): void {
    if (!this.events.has(event)) {
      this.events.set(event, []);
    }
    this.events.get(event)?.push(callback);
  }

  off(event: ActionHubEvent, callback?: CallbackFunc): void {
    if (!callback) {
      this.events.delete(event);
      return;
    }
    const callbacks = this.events.get(event);
    if (callbacks) {
      const index = callbacks.indexOf(callback);
      if (index !== -1) {
        callbacks.splice(index, 1);
      }
    }
  }

  emit(event: ActionHubEvent, ...args: Object[]): void {
    const callbacks = this.events.get(event);
    if (callbacks) {
      callbacks.forEach(callback => {
        callback(...args);
      });
    }
  }
}
