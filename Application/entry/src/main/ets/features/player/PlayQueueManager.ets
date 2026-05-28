import { VideoItem } from 'youtube_core';
import { AppLog } from '../../common/AppLog';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { StoredLocalQueue } from '../../common/PlaylistModel';

const logger = AppLog.getInstance('PlayQueueManager');

// ---- Types ----

export enum QueueSourceType {
  NONE = 'none',
  REMOTE = 'remote',   // YouTube playlist, lazy-loaded
  LOCAL = 'local',     // Locally saved queue
  ADHOC = 'adhoc',     // Single video or manually constructed
}

export class QueueChangeListener {
  onQueueChanged(): void {}
  onCurrentIndexChanged(_index: number): void {}
}

// ---- PlayQueueManager ----

export class PlayQueueManager {
  private static instance: PlayQueueManager;

  // Queue state
  queue: VideoItem[] = [];
  currentIndex: number = -1;
  sourceType: QueueSourceType = QueueSourceType.NONE;
  sourceId: string = '';
  sourceName: string = '';

  // Remote pagination
  private nextPageToken: string | null = null;
  private visitorData: string = '';
  private isLoadingMore: boolean = false;

  // Listeners
  private listeners: QueueChangeListener[] = [];

  /**
   * Callback fired when the current video changes (via moveTo/next/prev).
   * PlayerPage registers this to reload the video source.
   */
  onSwitchVideo: ((video: VideoItem) => void) | null = null;

  static getInstance(): PlayQueueManager {
    if (!PlayQueueManager.instance) {
      PlayQueueManager.instance = new PlayQueueManager();
    }
    return PlayQueueManager.instance;
  }

  // ---- Listener management ----

  addListener(listener: QueueChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  removeListener(listener: QueueChangeListener): void {
    const idx = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  private notifyQueueChanged(): void {
    this.listeners.forEach(l => {
      try { l.onQueueChanged(); } catch (e) { /* ignore */ }
    });
  }

  private notifyCurrentIndexChanged(index: number): void {
    this.listeners.forEach(l => {
      try { l.onCurrentIndexChanged(index); } catch (e) { /* ignore */ }
    });
  }

  // ---- Queue initialization ----

  /**
   * Set adhoc (single-video) queue.
   * Called when tapping a video from Home / Search / Subscriptions.
   */
  setAdhocQueue(videos: VideoItem[], startIndex: number): void {
    this.queue = videos;
    this.currentIndex = startIndex;
    this.sourceType = QueueSourceType.ADHOC;
    this.sourceId = '';
    this.sourceName = '';
    this.nextPageToken = null;
    this.visitorData = '';
    logger.info(`setAdhocQueue: ${videos.length} videos, start=${startIndex}`);
    this.notifyQueueChanged();
    this.notifyCurrentIndexChanged(startIndex);
  }

  /**
   * Load from remote YouTube playlist with lazy loading.
   * Called when opening a video from PlaylistDetailPage.
   */
  async loadFromRemotePlaylist(playlistId: string, startVideoId: string, playlistName: string = ''): Promise<void> {
    const prevSourceId = this.sourceId;
    const prevSourceType = this.sourceType;
    this.sourceType = QueueSourceType.REMOTE;
    this.sourceId = playlistId;
    this.sourceName = playlistName;
    this.queue = [];
    this.currentIndex = -1;
    this.nextPageToken = null;
    this.visitorData = '';

    try {
      const service = FeedServiceProvider.getInstance().getPlaylistService();
      const result = await service.fetchPlaylistInitial(playlistId, 1);
      this.queue = result.items;
      this.nextPageToken = result.nextPageToken;
      this.visitorData = result.visitorData;

      // Find the index of the startVideoId
      let foundIndex = -1;
      for (let i = 0; i < this.queue.length; i++) {
        if (this.queue[i].videoId === startVideoId) {
          foundIndex = i;
          break;
        }
      }
      if (foundIndex >= 0) {
        this.currentIndex = foundIndex;
      } else {
        // Start video not in first page — try to load more until found or exhausted
        this.currentIndex = 0;
      }

      if (!this.sourceName && result.totalCountText) {
        this.sourceName = result.totalCountText;
      }

      logger.info(`loadFromRemotePlaylist: ${this.queue.length} items, idx=${this.currentIndex}, token=${!!this.nextPageToken}`);
    } catch (err) {
      logger.error('loadFromRemotePlaylist failed:', err);
      // Revert to previous state on error
      if (prevSourceType === QueueSourceType.NONE) {
        this.sourceType = QueueSourceType.NONE;
        this.sourceId = '';
      }
    }

    this.notifyQueueChanged();
    this.notifyCurrentIndexChanged(this.currentIndex);
  }

  /**
   * Set a local (previously saved) queue.
   */
  setLocalQueue(videos: VideoItem[], name: string, localId: string, startVideoId?: string): void {
    this.queue = videos;
    this.sourceType = QueueSourceType.LOCAL;
    this.sourceId = localId;
    this.sourceName = name;
    this.nextPageToken = null;
    this.visitorData = '';

    if (startVideoId) {
      const idx = this.queue.findIndex(v => v.videoId === startVideoId);
      this.currentIndex = idx >= 0 ? idx : 0;
    } else {
      this.currentIndex = 0;
    }
    logger.info(`setLocalQueue: ${videos.length} videos, startId=${startVideoId}, idx=${this.currentIndex}`);
    this.notifyQueueChanged();
    this.notifyCurrentIndexChanged(this.currentIndex);
  }

  // ---- Navigation ----

  /** Get the current video */
  getCurrent(): VideoItem | null {
    if (this.currentIndex < 0 || this.currentIndex >= this.queue.length) {
      return null;
    }
    return this.queue[this.currentIndex];
  }

  /** Move to a specific index and return the video (returns null if out of bounds) */
  moveTo(index: number): VideoItem | null {
    if (index < 0 || index >= this.queue.length) {
      return null;
    }
    this.currentIndex = index;
    const video = this.queue[index];
    logger.info(`moveTo: idx=${index} videoId=${video.videoId}`);
    this.notifyCurrentIndexChanged(index);
    // Notify PlayerPage to reload the video
    if (this.onSwitchVideo) {
      this.onSwitchVideo(video);
    }
    return video;
  }

  /** Move to next video. Returns null if at end. Auto-triggers loadMore if needed. */
  next(): VideoItem | null {
    const nextIdx = this.currentIndex + 1;
    if (nextIdx >= this.queue.length) {
      // At end of loaded items — try lazy load if remote
      if (this.sourceType === QueueSourceType.REMOTE && this.nextPageToken) {
        logger.info('next() at boundary — triggering loadMore');
        this.loadMore();
      }
      return null;
    }
    return this.moveTo(nextIdx);
  }

  /** Move to previous video. Returns null if at start. */
  prev(): VideoItem | null {
    return this.moveTo(this.currentIndex - 1);
  }

  /** Whether there is a next item available */
  hasNext(): boolean {
    return this.currentIndex + 1 < this.queue.length;
  }

  /** Whether there is a previous item available */
  hasPrev(): boolean {
    return this.currentIndex - 1 >= 0;
  }

  // ---- Remote lazy loading ----

  /**
   * Load next page of videos for a remote playlist.
   */
  async loadMore(): Promise<boolean> {
    if (this.sourceType !== QueueSourceType.REMOTE) {
      return false;
    }
    if (this.isLoadingMore) {
      return false;
    }
    if (!this.nextPageToken) {
      return false;
    }

    this.isLoadingMore = true;
    try {
      const service = FeedServiceProvider.getInstance().getPlaylistService();
      const startId = this.queue.length + 1;
      const result = await service.fetchPlaylistNext(this.nextPageToken!, this.visitorData, startId);

      if (result.items && result.items.length > 0) {
        const oldLen = this.queue.length;
        this.queue = this.queue.concat(result.items);
        logger.info(`loadMore: +${result.items.length} items (${oldLen} → ${this.queue.length})`);
      }

      if (result.visitorData) {
        this.visitorData = result.visitorData;
      }

      // Avoid infinite loop: if token didn't change, stop
      if (result.nextPageToken && result.nextPageToken !== this.nextPageToken) {
        this.nextPageToken = result.nextPageToken;
      } else {
        this.nextPageToken = null;
      }

      this.notifyQueueChanged();
      return result.items && result.items.length > 0;
    } catch (err) {
      logger.error('loadMore failed:', err);
      return false;
    } finally {
      this.isLoadingMore = false;
    }
  }

  get isLoadingNextPage(): boolean {
    return this.isLoadingMore;
  }

  get hasMoreRemotePages(): boolean {
    return this.sourceType === QueueSourceType.REMOTE && this.nextPageToken !== null;
  }

  // ---- Mutation ----

  /** Add a single video to the end of the queue */
  addToQueue(video: VideoItem): void {
    // Dedup
    if (this.queue.some(v => v.videoId === video.videoId)) {
      return;
    }
    this.queue.push(video);
    this.notifyQueueChanged();
  }

  /** Remove video at index. Adjust currentIndex if needed. */
  removeAt(index: number): void {
    if (index < 0 || index >= this.queue.length) {
      return;
    }
    this.queue.splice(index, 1);
    if (index < this.currentIndex) {
      this.currentIndex--;
    } else if (index === this.currentIndex) {
      // Current video removed — clamp
      if (this.currentIndex >= this.queue.length) {
        this.currentIndex = this.queue.length - 1;
      }
      this.notifyCurrentIndexChanged(this.currentIndex);
    }
    this.notifyQueueChanged();
  }

  /** Reorder: move item from fromIndex to toIndex */
  reorder(fromIndex: number, toIndex: number): void {
    if (fromIndex < 0 || fromIndex >= this.queue.length ||
        toIndex < 0 || toIndex >= this.queue.length) {
      return;
    }
    const item: VideoItem = this.queue.splice(fromIndex, 1)[0];
    this.queue.splice(toIndex, 0, item);

    // Adjust currentIndex
    if (fromIndex === this.currentIndex) {
      this.currentIndex = toIndex;
    } else if (fromIndex < this.currentIndex && toIndex >= this.currentIndex) {
      this.currentIndex--;
    } else if (fromIndex > this.currentIndex && toIndex <= this.currentIndex) {
      this.currentIndex++;
    }

    this.notifyQueueChanged();
    this.notifyCurrentIndexChanged(this.currentIndex);
  }

  /** Clear the queue */
  clear(): void {
    this.queue = [];
    this.currentIndex = -1;
    this.sourceType = QueueSourceType.NONE;
    this.sourceId = '';
    this.sourceName = '';
    this.nextPageToken = null;
    this.visitorData = '';
    this.notifyQueueChanged();
    this.notifyCurrentIndexChanged(-1);
  }

  // ---- Auto-play queue (related videos) ----

  private autoQueueCandidates: VideoItem[] = [];
  private autoQueueUsedUrls: Set<string> = new Set();

  /**
   * Store related videos as auto-play candidates.
   * Called from YouTubeExtractor after extracting relatedItems from nextResponse.
   */
  setAutoQueueCandidates(items: VideoItem[]): void {
    this.autoQueueCandidates = items;
    this.autoQueueUsedUrls = new Set();
    // Mark existing queue items as already used
    for (const item of this.queue) {
      if (item.videoId) {
        this.autoQueueUsedUrls.add(item.videoId);
      }
    }
    // Immediately append the first candidate so the queue has >1 item right away
    this.appendAutoQueueNext();
  }

  /**
   * Append auto-queue candidates to the end of the queue.
   * - Skips candidates already in the queue (by videoId)
   * - Appends up to `maxCount` candidates at once (default 5)
   * Returns the number of candidates appended.
   */
  appendAutoQueueNext(maxCount: number = 20): number {
    if (this.autoQueueCandidates.length === 0) {
      return 0;
    }
    let addedCount = 0;
    for (const candidate of this.autoQueueCandidates) {
      if (addedCount >= maxCount) {
        break;
      }
      const vid = candidate.videoId;
      if (vid && !this.autoQueueUsedUrls.has(vid)) {
        this.autoQueueUsedUrls.add(vid);
        this.queue.push(candidate);
        addedCount++;
      }
    }
    if (addedCount > 0) {
      logger.info(`appendAutoQueueNext: added ${addedCount} videos`);
      this.notifyQueueChanged();
    }
    return addedCount;
  }

  // ---- Persistent local queues ----

  /**
   * Save current queue as a local playlist.
   * Only saves loaded items (not entire remote playlist).
   */
  saveAsLocal(name: string): StoredLocalQueue {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    let id = 'local_';
    for (let i = 0; i < 16; i++) {
      id += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return {
      id: id,
      name: name,
      videos: this.queue,
      createdAt: Date.now(),
    };
  }
}
