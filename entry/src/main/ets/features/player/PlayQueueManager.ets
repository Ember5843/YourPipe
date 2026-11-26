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

export type QueueLoopMode = 'none' | 'all' | 'one';

export interface RemovedQueueItem {
  item: VideoItem;
  index: number;
  wasCurrent: boolean;
}

/** Hints passed from the caller to pre-configure the play queue before opening the player. */
export interface PlayQueueSourceHint {
  /**
   * 'downloads' = the download library injected wholesale as one playable list.
   * 'localFiles' = user-imported files (independent of downloads).
   * 'localMedia' = one shared queue: completed downloads first, imported files after.
   */
  type: 'playlist' | 'local' | 'downloads' | 'localFiles' | 'localMedia';
  playlistId: string;
  playlistName: string;
  loadedItems?: VideoItem[];
  startIndex?: number;
  nextPageToken?: string | null;
  visitorData?: string;
}

export interface PlayQueueSnapshot {
  items: VideoItem[];
  currentIndex: number;
  sourceType: QueueSourceType;
  sourceId: string;
  sourceName: string;
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

  // Loop & shuffle state
  private _loopMode: QueueLoopMode = 'none';
  private _isShuffled: boolean = false;
  private originalOrder: VideoItem[] = [];

  // Remote pagination
  private nextPageToken: string | null = null;
  private visitorData: string = '';
  private isLoadingMore: boolean = false;
  private queueGeneration: number = 0;
  /** Independent playback session ID owning this queue. */
  private sessionId: number = 0;

  // Listeners
  private listeners: QueueChangeListener[] = [];

  /**
   * Callback fired when the current video changes (via moveTo/next/prev).
   * Carries the owning sessionId so stale callbacks from a closed session are discarded.
   */
  onSwitchVideo: ((video: VideoItem, sessionId: number) => void) | null = null;

  get boundSessionId(): number {
    return this.sessionId;
  }

  /** Reset queue state completely for a brand-new independent playback session. */
  resetForSession(sessionId: number): void {
    this.sessionId = sessionId;
    this.clear();
  }

  /** Rebind an existing queue snapshot (e.g. continuation restore) to a new session ID. */
  rebindSession(sessionId: number): void {
    this.sessionId = sessionId;
    this.queueGeneration++;
  }

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
    this.queueGeneration++;
    this.isLoadingMore = false;
    this.autoQueueCandidates = [];
    this.autoQueueUsedUrls = new Set<string>();
    this.autoQueueLocked = false;
    this.resetShuffleState();
  }

  private resetShuffleState(): void {
    this._isShuffled = false;
    this.originalOrder = [];
  }

  // ---- Loop & shuffle controls ----

  get loopMode(): QueueLoopMode {
    return this._loopMode;
  }

  setLoopMode(mode: QueueLoopMode): void {
    if (this._loopMode === mode) {
      return;
    }
    this._loopMode = mode;
    logger.info(`setLoopMode: ${mode}`);
    this.notifyQueueChanged();
  }

  cycleLoopMode(): QueueLoopMode {
    const nextMode: QueueLoopMode = this._loopMode === 'none'
      ? 'all'
      : (this._loopMode === 'all' ? 'one' : 'none');
    this.setLoopMode(nextMode);
    return nextMode;
  }

  get isShuffled(): boolean {
    return this._isShuffled;
  }

  get totalLoadedCount(): number {
    return this.queue.length + this.pendingQueueItems.length;
  }

  isLocalFileOnlyQueue(): boolean {
    const total = this.queue.length + this.pendingQueueItems.length;
    if (total === 0) {
      return false;
    }
    const allShownLocal = this.queue.every((v: VideoItem): boolean => !!v.localMediaPath);
    const allPendingLocal = this.pendingQueueItems.every((v: VideoItem): boolean => !!v.localMediaPath);
    return allShownLocal && allPendingLocal;
  }

  private shuffleInPlace(items: VideoItem[]): void {
    for (let i = items.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      const tmp = items[i];
      items[i] = items[j];
      items[j] = tmp;
    }
  }

  setShuffle(enabled: boolean): void {
    if (this._isShuffled === enabled) {
      return;
    }
    if (enabled) {
      const allItems: VideoItem[] = this.queue.concat(this.pendingQueueItems);
      this.originalOrder = allItems.slice();
      const hasCurrent = this.currentIndex >= 0 && this.currentIndex < this.queue.length;
      const prefix: VideoItem[] = hasCurrent ? this.queue.slice(0, this.currentIndex + 1) : [];
      const tailShown: VideoItem[] = hasCurrent ? this.queue.slice(this.currentIndex + 1) : this.queue.slice();
      const tailAll: VideoItem[] = tailShown.concat(this.pendingQueueItems);
      if (tailAll.length > 1) {
        this.shuffleInPlace(tailAll);
      }
      const shownTailCount = tailShown.length;
      this.queue = prefix.concat(tailAll.slice(0, shownTailCount));
      this.pendingQueueItems = tailAll.slice(shownTailCount);
      this._isShuffled = true;
      logger.info(`setShuffle: ON fixed=${prefix.length} shuffled=${tailAll.length}`);
      this.notifyQueueChanged();
      return;
    }

    // Restore originalOrder cleanly while preserving removals and newly added items.
    const currentVideo = this.getCurrent();
    const prevShownCount = this.queue.length;
    const allCurrent: VideoItem[] = this.queue.concat(this.pendingQueueItems);
    const remainingSet: Set<VideoItem> = new Set<VideoItem>(allCurrent);
    const restored: VideoItem[] = [];
    const seenInRestored: Set<VideoItem> = new Set<VideoItem>();
    for (const orig of this.originalOrder) {
      if (remainingSet.has(orig) && !seenInRestored.has(orig)) {
        restored.push(orig);
        seenInRestored.add(orig);
      }
    }
    for (const cur of allCurrent) {
      if (!seenInRestored.has(cur)) {
        restored.push(cur);
        seenInRestored.add(cur);
      }
    }

    let newIndex = currentVideo ? restored.indexOf(currentVideo) : -1;
    if (newIndex < 0 && currentVideo && currentVideo.videoId) {
      newIndex = restored.findIndex((v: VideoItem): boolean => v.videoId === currentVideo.videoId);
    }
    if (restored.length === 0) {
      this.queue = [];
      this.pendingQueueItems = [];
      this.currentIndex = -1;
    } else {
      const safeIndex = newIndex >= 0 && newIndex < restored.length ? newIndex : 0;
      const visibleCount = Math.min(
        restored.length,
        Math.max(this.QUEUE_BATCH_SIZE, prevShownCount, safeIndex + 1)
      );
      this.queue = restored.slice(0, visibleCount);
      this.pendingQueueItems = restored.slice(visibleCount);
      this.currentIndex = safeIndex;
    }
    this._isShuffled = false;
    this.originalOrder = [];
    logger.info(`setShuffle: OFF restored=${restored.length} idx=${this.currentIndex}`);
    this.notifyQueueChanged();
    this.notifyCurrentIndexChanged(this.currentIndex);
  }

  toggleShuffle(): boolean {
    this.setShuffle(!this._isShuffled);
    return this._isShuffled;
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
    const prevAutoUsedUrls: Set<string> = new Set<string>(this.autoQueueUsedUrls);
    const prevAutoLocked: boolean = this.autoQueueLocked;
    const prevIsShuffled: boolean = this._isShuffled;
    const prevOriginalOrder: VideoItem[] = this.originalOrder.slice();

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
    const generation = this.queueGeneration;

    try {
      const service = FeedServiceProvider.getInstance().getPlaylistService();
      const result = await service.fetchPlaylistInitial(playlistId, 1);
      if (generation !== this.queueGeneration) return;
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
        if (generation !== this.queueGeneration) return;
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
      if (generation !== this.queueGeneration) return;
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
      this._isShuffled = prevIsShuffled;
      this.originalOrder = prevOriginalOrder;
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
    // Notify PlayerSession to reload the video within the owning session
    if (this.onSwitchVideo) {
      this.onSwitchVideo(video, this.sessionId);
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
    const generation = this.queueGeneration;
    if (!this.hasNext() && this.hasMorePages) {
      await this.loadMore();
    }
    return generation === this.queueGeneration ? this.next() : null;
  }

  /** Move to previous video. Returns null if at start. */
  prev(): VideoItem | null {
    return this.moveTo(this.currentIndex - 1);
  }

  /** Whether there is a next item available */
  hasNext(): boolean {
    return this.currentIndex + 1 < this.queue.length;
  }

  /** Peek the next queue item without consuming it (used by playback prefetch). */
  peekNext(): VideoItem | null {
    if (this.hasNext()) {
      return this.queue[this.currentIndex + 1];
    }
    if (this._loopMode === 'all' && !this.hasMorePages && this.queue.length > 1) {
      return this.queue[0];
    }
    return null;
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

    const generation = this.queueGeneration;
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
      if (generation !== this.queueGeneration) return false;

      if (result.items && result.items.length > 0) {
        const oldLen = this.queue.length;
        this.queue = this.queue.concat(result.items);
        if (this._isShuffled) {
          this.originalOrder = this.originalOrder.concat(result.items);
        }
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
      if (generation === this.queueGeneration) {
        this.isLoadingMore = false;
        this.notifyQueueChanged();
      }
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

  /**
   * Add a single video to the end of the queue.
   * Deduplicates across both visible `queue` and `pendingQueueItems`, and records
   * the videoId in `autoQueueUsedUrls` so ad-hoc autoplay never re-adds it.
   * Returns true if added, false if invalid or already present.
   */
  addToQueue(video: VideoItem): boolean {
    const vid = (video?.videoId || '').trim();
    if (!vid) {
      return false;
    }
    this.autoQueueUsedUrls.add(vid);
    const inQueue = this.queue.some((v: VideoItem): boolean => v.videoId === vid);
    const inPending = this.pendingQueueItems.some((v: VideoItem): boolean => v.videoId === vid);
    if (inQueue || inPending) {
      return false;
    }
    if (this.pendingQueueItems.length > 0) {
      this.pendingQueueItems.push(video);
    } else {
      this.queue.push(video);
    }
    if (this._isShuffled) {
      this.originalOrder.push(video);
    }
    if (this.sourceType === QueueSourceType.NONE) {
      this.sourceType = QueueSourceType.ADHOC;
    }
    if (this.currentIndex < 0 && this.queue.length > 0) {
      this.currentIndex = 0;
      this.notifyCurrentIndexChanged(this.currentIndex);
    }
    logger.info(`addToQueue: videoId=${vid} shown=${this.queue.length} pending=${this.pendingQueueItems.length}`);
    this.notifyQueueChanged();
    return true;
  }

  /**
   * Insert a video immediately after `currentIndex`.
   * If already present elsewhere in `queue` or `pendingQueueItems`, moves it to
   * `currentIndex + 1`. Returns false if invalid or if it is already playing.
   */
  insertNext(video: VideoItem): boolean {
    const vid = (video?.videoId || '').trim();
    if (!vid) {
      return false;
    }
    this.autoQueueUsedUrls.add(vid);

    if (this.queue.length === 0) {
      this.queue.push(video);
      this.currentIndex = 0;
      if (this.sourceType === QueueSourceType.NONE) {
        this.sourceType = QueueSourceType.ADHOC;
      }
      if (this._isShuffled) {
        this.originalOrder.push(video);
      }
      logger.info(`insertNext (empty): videoId=${vid}`);
      this.notifyQueueChanged();
      this.notifyCurrentIndexChanged(this.currentIndex);
      return true;
    }

    const existingQueueIdx = this.queue.findIndex((v: VideoItem): boolean => v.videoId === vid);
    if (existingQueueIdx >= 0) {
      if (existingQueueIdx === this.currentIndex) {
        return false;
      }
      const nextSlot = Math.max(0, Math.min(this.queue.length, this.currentIndex + 1));
      if (existingQueueIdx === nextSlot) {
        return true;
      }
      const moved: VideoItem = this.queue.splice(existingQueueIdx, 1)[0];
      let indexChanged = false;
      if (existingQueueIdx < this.currentIndex) {
        this.currentIndex--;
        indexChanged = true;
      }
      const targetIdx = Math.max(0, Math.min(this.queue.length, this.currentIndex + 1));
      this.queue.splice(targetIdx, 0, moved);
      logger.info(`insertNext (moved from queue[${existingQueueIdx}]): videoId=${vid} -> ${targetIdx}`);
      this.notifyQueueChanged();
      if (indexChanged) {
        this.notifyCurrentIndexChanged(this.currentIndex);
      }
      return true;
    }

    const existingPendingIdx = this.pendingQueueItems.findIndex((v: VideoItem): boolean => v.videoId === vid);
    const targetIdx = Math.max(0, Math.min(this.queue.length, this.currentIndex + 1));
    if (existingPendingIdx >= 0) {
      const moved: VideoItem = this.pendingQueueItems.splice(existingPendingIdx, 1)[0];
      this.queue.splice(targetIdx, 0, moved);
      logger.info(`insertNext (moved from pending[${existingPendingIdx}]): videoId=${vid} -> ${targetIdx}`);
      this.notifyQueueChanged();
      return true;
    }

    this.queue.splice(targetIdx, 0, video);
    if (this._isShuffled) {
      this.originalOrder.push(video);
    }
    logger.info(`insertNext (inserted): videoId=${vid} -> ${targetIdx}`);
    this.notifyQueueChanged();
    return true;
  }

  /** Remove video at index. Adjust currentIndex if needed. Returns removed item, original index, and whether it was current for Undo. */
  removeAt(index: number): RemovedQueueItem | null {
    if (index < 0 || index >= this.queue.length) {
      return null;
    }
    const wasCurrent = index === this.currentIndex;
    const removed: VideoItem = this.queue.splice(index, 1)[0];
    if (index < this.currentIndex) {
      this.currentIndex--;
    } else if (wasCurrent) {
      // Current video removed — clamp
      if (this.currentIndex >= this.queue.length) {
        this.currentIndex = this.queue.length - 1;
      }
      this.notifyCurrentIndexChanged(this.currentIndex);
    }
    this.notifyQueueChanged();
    return { item: removed, index: index, wasCurrent: wasCurrent };
  }

  /** Insert a video at a specific index (used for Undo restore). */
  insertAt(index: number, item: VideoItem, restoreAsCurrent: boolean = false): boolean {
    if (!item) {
      return false;
    }
    const vid = (item.videoId || '').trim();
    if (vid.length > 0) {
      if (this.queue.some((v: VideoItem): boolean => v.videoId === vid)
        || this.pendingQueueItems.some((v: VideoItem): boolean => v.videoId === vid)) {
        return false;
      }
      this.autoQueueUsedUrls.add(vid);
    }
    const prevCurrentIndex = this.currentIndex;
    const targetIdx = Math.max(0, Math.min(this.queue.length, index));
    this.queue.splice(targetIdx, 0, item);
    if (restoreAsCurrent) {
      this.currentIndex = targetIdx;
    } else if (this.currentIndex < 0) {
      this.currentIndex = 0;
    } else if (targetIdx <= this.currentIndex) {
      this.currentIndex++;
    }
    if (this._isShuffled && !this.originalOrder.includes(item)) {
      this.originalOrder.push(item);
    }
    logger.info(`insertAt: idx=${targetIdx} videoId=${vid} restoreAsCurrent=${restoreAsCurrent} cur=${this.currentIndex}`);
    this.notifyQueueChanged();
    if (this.currentIndex !== prevCurrentIndex) {
      this.notifyCurrentIndexChanged(this.currentIndex);
    }
    return true;
  }

  /** Reorder: move item from fromIndex to toIndex */
  reorder(fromIndex: number, toIndex: number): void {
    if (fromIndex === toIndex ||
        fromIndex < 0 || fromIndex >= this.queue.length ||
        toIndex < 0 || toIndex >= this.queue.length) {
      return;
    }
    const item: VideoItem = this.queue.splice(fromIndex, 1)[0];
    this.queue.splice(toIndex, 0, item);

    // Adjust currentIndex
    const prevCurrentIndex = this.currentIndex;
    if (fromIndex === this.currentIndex) {
      this.currentIndex = toIndex;
    } else if (fromIndex < this.currentIndex && toIndex >= this.currentIndex) {
      this.currentIndex--;
    } else if (fromIndex > this.currentIndex && toIndex <= this.currentIndex) {
      this.currentIndex++;
    }

    this.notifyQueueChanged();
    if (this.currentIndex !== prevCurrentIndex) {
      this.notifyCurrentIndexChanged(this.currentIndex);
    }
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
    this._loopMode = 'none';
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
    // Mark existing queue and pending items as already used
    for (const item of this.queue) {
      if (item.videoId) {
        this.autoQueueUsedUrls.add(item.videoId);
      }
    }
    for (const item of this.pendingQueueItems) {
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
   * Combines loaded `queue` and `pendingQueueItems` so queues >12 items aren't truncated.
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
      videos: this.queue.concat(this.pendingQueueItems),
      createdAt: Date.now(),
    };
  }

  exportSnapshot(maxItems: number = 50): PlayQueueSnapshot {
    const limit = maxItems > 0 ? maxItems : 50;
    return {
      items: this.queue.concat(this.pendingQueueItems).slice(0, limit),
      currentIndex: this.currentIndex,
      sourceType: this.sourceType,
      sourceId: this.sourceId,
      sourceName: this.sourceName
    };
  }

  restoreSnapshot(snapshot: PlayQueueSnapshot): void {
    if (!snapshot || !snapshot.items || snapshot.items.length === 0) {
      return;
    }
    const startIndex = snapshot.currentIndex >= 0 && snapshot.currentIndex < snapshot.items.length
      ? snapshot.currentIndex
      : 0;
    this.sourceType = snapshot.sourceType;
    this.sourceId = snapshot.sourceId || '';
    this.sourceName = snapshot.sourceName || '';
    this.nextPageToken = null;
    this.visitorData = '';
    this.resetAutoQueueState();
    this.applyLazyQueue(snapshot.items, startIndex);
    logger.info(`restoreSnapshot: type=${this.sourceType} total=${snapshot.items.length} shown=${this.queue.length} idx=${this.currentIndex}`);
    this.notifyQueueChanged();
    this.notifyCurrentIndexChanged(this.currentIndex);
  }
}
