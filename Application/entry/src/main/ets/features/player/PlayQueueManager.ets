import { VideoItem } from 'youtube_core';
import { AppLog } from '../../common/AppLog';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { StoredLocalQueue } from '../../common/PlaylistModel';

const logger = AppLog.getInstance('PlayQueueManager');

// ---- Types ----

export enum QueueSourceType {
  NONE = 'none',
  REMOTE = 'remote',   // YouTube playlist, lazy-loaded
  LOCAL = 'local',     // Locally saved queue snapshot
  ADHOC = 'adhoc',     // Single video or manually constructed
}

/** Hints passed from the caller to pre-configure the play queue before opening the player. */
export interface PlayQueueSourceHint {
  type: 'playlist' | 'local';
  playlistId: string;
  playlistName: string;
  loadedItems?: VideoItem[];
  startIndex?: number;
  nextPageToken?: string | null;
  visitorData?: string;
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

  private readonly QUEUE_BATCH_SIZE: number = 12;
  private pendingQueueItems: VideoItem[] = [];

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

  private resetAutoQueueState(): void {
    this.autoQueueCandidates = [];
    this.autoQueueUsedUrls = new Set();
    this.autoQueueLocked = false;
  }

  private applyLazyQueue(items: VideoItem[], startIndex: number): void {
    if (!items || items.length === 0) {
      this.queue = [];
      this.pendingQueueItems = [];
      this.currentIndex = -1;
      return;
    }

    const safeIndex = startIndex >= 0 && startIndex < items.length ? startIndex : 0;
    const visibleCount = Math.min(items.length, Math.max(this.QUEUE_BATCH_SIZE, safeIndex + 1));
    this.queue = items.slice(0, visibleCount);
    this.pendingQueueItems = items.slice(visibleCount);
    this.currentIndex = safeIndex;
  }

  private appendPendingQueueItems(maxCount: number = this.QUEUE_BATCH_SIZE): number {
    if (this.pendingQueueItems.length === 0) {
      return 0;
    }

    const count = Math.min(maxCount, this.pendingQueueItems.length);
    const nextItems = this.pendingQueueItems.slice(0, count);
    this.pendingQueueItems = this.pendingQueueItems.slice(count);
    this.queue = this.queue.concat(nextItems);
    logger.info(`appendPendingQueueItems: +${count} pending=${this.pendingQueueItems.length}`);
    this.notifyQueueChanged();
    return count;
  }

  // ---- Queue initialization ----

  /**
   * Set adhoc (single-video) queue.
   * Called when tapping a video from Home / Search / Subscriptions.
   */
  setAdhocQueue(videos: VideoItem[], startIndex: number): void {
    this.applyLazyQueue(videos, startIndex);
    this.sourceType = QueueSourceType.ADHOC;
    this.sourceId = '';
    this.sourceName = '';
    this.nextPageToken = null;
    this.visitorData = '';
    this.resetAutoQueueState();
    logger.info(`setAdhocQueue: total=${videos.length} shown=${this.queue.length} pending=${this.pendingQueueItems.length} start=${this.currentIndex}`);
    this.notifyQueueChanged();
    this.notifyCurrentIndexChanged(this.currentIndex);
  }

  /**
   * Load from remote YouTube playlist with lazy loading.
   * Called when opening a video from PlaylistDetailPage.
   */
  async loadFromRemotePlaylist(playlistId: string, startVideoId: string, playlistName: string = ''): Promise<void> {
    const startedAt = Date.now();
    logger.info(`loadFromRemotePlaylist start: playlist=${playlistId} start=${startVideoId}`);
    // Save full snapshot so we can roll back on error
    const prevQueue: VideoItem[] = this.queue.slice();
    const prevIndex: number = this.currentIndex;
    const prevType: QueueSourceType = this.sourceType;
    const prevId: string = this.sourceId;
    const prevName: string = this.sourceName;
    const prevToken: string | null = this.nextPageToken;
    const prevVisitor: string = this.visitorData;
    const prevPending: VideoItem[] = this.pendingQueueItems.slice();
    const prevAutoCandidates: VideoItem[] = this.autoQueueCandidates.slice();
    const prevAutoUsedUrls: Set<string> = new Set(this.autoQueueUsedUrls);
    const prevAutoLocked: boolean = this.autoQueueLocked;

    // Optimistically set remote state
    this.sourceType = QueueSourceType.REMOTE;
    this.sourceId = playlistId;
    this.sourceName = playlistName;
    this.queue = [];
    this.currentIndex = -1;
    this.pendingQueueItems = [];
    this.nextPageToken = null;
    this.visitorData = '';
    this.resetAutoQueueState();

    try {
      const service = FeedServiceProvider.getInstance().getPlaylistService();
      const result = await service.fetchPlaylistInitial(playlistId, 1);
      let loadedItems: VideoItem[] = result.items ? result.items.slice() : [];
      let nextToken: string | null = result.nextPageToken;
      let visitor: string = result.visitorData || '';

      // Find the index of the startVideoId
      let foundIndex = -1;
      for (let i = 0; i < loadedItems.length; i++) {
        if (loadedItems[i].videoId === startVideoId) {
          foundIndex = i;
          break;
        }
      }

      while (foundIndex < 0 && nextToken) {
        const prevToken = nextToken;
        const nextResult = await service.fetchPlaylistNext(prevToken, visitor, loadedItems.length + 1);
        if (nextResult.items && nextResult.items.length > 0) {
          const oldLen = loadedItems.length;
          loadedItems = loadedItems.concat(nextResult.items);
          for (let i = oldLen; i < loadedItems.length; i++) {
            if (loadedItems[i].videoId === startVideoId) {
              foundIndex = i;
              break;
            }
          }
        }
        if (nextResult.visitorData) {
          visitor = nextResult.visitorData;
        }
        if (nextResult.nextPageToken && nextResult.nextPageToken !== prevToken) {
          nextToken = nextResult.nextPageToken;
        } else {
          nextToken = null;
        }
      }

      this.nextPageToken = nextToken;
      this.visitorData = visitor;
      this.applyLazyQueue(loadedItems, foundIndex >= 0 ? foundIndex : 0);

      if (!this.sourceName && result.totalCountText) {
        this.sourceName = result.totalCountText;
      }

      logger.info(`loadFromRemotePlaylist done: elapsed=${Date.now() - startedAt}ms total=${loadedItems.length} shown=${this.queue.length} pending=${this.pendingQueueItems.length} idx=${this.currentIndex} found=${foundIndex >= 0} token=${!!this.nextPageToken}`);
    } catch (err) {
      logger.error('loadFromRemotePlaylist failed, restoring previous queue:', err);
      // Full rollback to previous state on any error
      this.queue = prevQueue;
      this.currentIndex = prevIndex;
      this.sourceType = prevType;
      this.sourceId = prevId;
      this.sourceName = prevName;
      this.nextPageToken = prevToken;
      this.visitorData = prevVisitor;
      this.pendingQueueItems = prevPending;
      this.autoQueueCandidates = prevAutoCandidates;
      this.autoQueueUsedUrls = prevAutoUsedUrls;
      this.autoQueueLocked = prevAutoLocked;
    }

    this.notifyQueueChanged();
    this.notifyCurrentIndexChanged(this.currentIndex);
  }

  setRemotePlaylistSnapshot(
    playlistId: string,
    items: VideoItem[],
    startVideoId: string,
    playlistName: string = '',
    startIndex: number = -1,
    nextPageToken: string | null = null,
    visitorData: string = ''
  ): void {
    if (!items || items.length === 0) {
      return;
    }

    this.sourceType = QueueSourceType.REMOTE;
    this.sourceId = playlistId;
    this.sourceName = playlistName;
    this.nextPageToken = nextPageToken;
    this.visitorData = visitorData;
    this.resetAutoQueueState();

    if (startIndex >= 0 && startIndex < items.length && items[startIndex].videoId === startVideoId) {
      this.applyLazyQueue(items, startIndex);
    } else {
      const foundIndex = items.findIndex((item) => item.videoId === startVideoId);
      this.applyLazyQueue(items, foundIndex >= 0 ? foundIndex : 0);
    }

    logger.info(`setRemotePlaylistSnapshot: playlist=${playlistId} total=${items.length} shown=${this.queue.length} pending=${this.pendingQueueItems.length} idx=${this.currentIndex} token=${!!this.nextPageToken}`);
    this.notifyQueueChanged();
    this.notifyCurrentIndexChanged(this.currentIndex);
  }

  /**
   * Set a local (previously saved) queue.
   */
  setLocalQueue(videos: VideoItem[], name: string, localId: string, startVideoId?: string): void {
    this.sourceType = QueueSourceType.LOCAL;
    this.sourceId = localId;
    this.sourceName = name;
    this.nextPageToken = null;
    this.visitorData = '';
    this.resetAutoQueueState();

    let startIndex = 0;
    if (startVideoId) {
      const idx = videos.findIndex(v => v.videoId === startVideoId);
      startIndex = idx >= 0 ? idx : 0;
    }
    this.applyLazyQueue(videos, startIndex);
    logger.info(`setLocalQueue: total=${videos.length} shown=${this.queue.length} pending=${this.pendingQueueItems.length} startId=${startVideoId}, idx=${this.currentIndex}`);
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

  /** Move to next video. Returns null if at the end of the loaded queue. */
  next(): VideoItem | null {
    const nextIdx = this.currentIndex + 1;
    if (nextIdx >= this.queue.length) {
      return null;
    }
    return this.moveTo(nextIdx);
  }

  /** Move to next video, loading another queue page first if needed. */
  async nextOrLoadMore(): Promise<VideoItem | null> {
    if (!this.hasNext() && this.hasMorePages) {
      await this.loadMore();
    }
    return this.next();
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
   * Load the next visible batch or remote page.
   * REMOTE covers any YouTube playlist source, including favorited playlists.
   */
  async loadMore(): Promise<boolean> {
    if (this.isLoadingMore) {
      return false;
    }
    if (!this.hasMorePages) {
      return false;
    }

    this.isLoadingMore = true;
    this.notifyQueueChanged();
    try {
      const appended = this.appendPendingQueueItems();
      if (appended > 0) {
        return true;
      }

      if (this.sourceType === QueueSourceType.ADHOC) {
        return this.appendAutoQueueNext(this.QUEUE_BATCH_SIZE) > 0;
      }

      if (this.sourceType !== QueueSourceType.REMOTE || !this.nextPageToken) {
        return false;
      }

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
      this.notifyQueueChanged();
    }
  }

  get isLoadingNextPage(): boolean {
    return this.isLoadingMore;
  }

  get hasMorePages(): boolean {
    return this.pendingQueueItems.length > 0
      || (this.sourceType === QueueSourceType.REMOTE && this.nextPageToken !== null)
      || (this.sourceType === QueueSourceType.ADHOC && this.hasUnusedAutoQueueCandidates());
  }

  get hasMoreRemotePages(): boolean {
    return this.hasMorePages;
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
    this.pendingQueueItems = [];
    this.nextPageToken = null;
    this.visitorData = '';
    this.resetAutoQueueState();
    this.notifyQueueChanged();
    this.notifyCurrentIndexChanged(-1);
  }

  // ---- Auto-play queue (related videos) ----

  private autoQueueCandidates: VideoItem[] = [];
  private autoQueueUsedUrls: Set<string> = new Set();
  private autoQueueLocked: boolean = false;

  private hasUnusedAutoQueueCandidates(): boolean {
    if (this.autoQueueCandidates.length === 0) {
      return false;
    }
    return this.autoQueueCandidates.some((candidate) => !!candidate.videoId && !this.autoQueueUsedUrls.has(candidate.videoId));
  }

  /**
   * Store related videos as auto-play candidates.
   * Called from YouTubeExtractor after extracting relatedItems from nextResponse.
   */
  setAutoQueueCandidates(items: VideoItem[]): void {
    if (this.sourceType !== QueueSourceType.ADHOC) {
      logger.info(`setAutoQueueCandidates ignored: sourceType=${this.sourceType} items=${items.length}`);
      return;
    }
    if (this.autoQueueLocked) {
      logger.info(`setAutoQueueCandidates ignored: adhoc queue already locked items=${items.length}`);
      return;
    }
    logger.info(`setAutoQueueCandidates: items=${items.length}`);
    this.autoQueueCandidates = items;
    this.autoQueueUsedUrls = new Set();
    // Mark existing queue items as already used
    for (const item of this.queue) {
      if (item.videoId) {
        this.autoQueueUsedUrls.add(item.videoId);
      }
    }
    this.autoQueueLocked = true;
    this.appendAutoQueueNext(this.QUEUE_BATCH_SIZE);
    this.notifyQueueChanged();
  }

  /**
   * Append auto-queue candidates to the end of the queue.
   * - Skips candidates already in the queue (by videoId)
   * - Appends up to `maxCount` candidates at once (default 5)
   * Returns the number of candidates appended.
   */
  appendAutoQueueNext(maxCount: number = this.QUEUE_BATCH_SIZE): number {
    if (this.sourceType !== QueueSourceType.ADHOC) {
      return 0;
    }
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
        this.pendingQueueItems.push(candidate);
        addedCount++;
      }
    }
    if (addedCount > 0) {
      logger.info(`appendAutoQueueNext: staged ${addedCount} videos pending=${this.pendingQueueItems.length}`);
      this.appendPendingQueueItems(maxCount);
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
      videos: this.queue.slice(),
      createdAt: Date.now(),
    };
  }
}
