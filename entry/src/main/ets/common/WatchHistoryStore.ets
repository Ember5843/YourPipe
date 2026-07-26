import { AppLog } from './AppLog';
import { PreferencesStore } from './PreferencesStore';

const logger = AppLog.getInstance('WatchHistoryStore');
const APP_STORAGE_KEY = 'watchHistory';

/** mergeRemoteHistory 内部使用：远端条目 + 是否为本地已知锚点。 */
interface HistoryMergeEntry {
  item: WatchHistoryItem;
  isAnchor: boolean;
}

export interface WatchHistoryItem {
  videoId: string;       // YouTube 视频 ID（唯一键）
  title: string;         // 视频标题
  author: string;        // 频道名
  thumbnailUrl: string;  // 缩略图 URL
  durationSec: number;   // 视频总时长（秒），0 = 未知
  progressSec: number;   // 上次停止位置（秒）
  lastWatchedAt: number; // 时间戳（ms），用于排序
  channelId: string;           // 频道 ID（用于跳转频道页）
  channelAvatarUrl: string;    // 频道头像
  channelHandle: string;       // 频道 handle
}

export class WatchHistoryStore {
  private static readonly KEY: string = 'watch_history';
  private static readonly MAX_COUNT: number = 100;
  /** 播放列表来源的历史条目：videoId 以此前缀编码（playlist:<playlistId>） */
  static readonly PLAYLIST_KEY_PREFIX: string = 'playlist:';
  /** 进度超过这个比例时视为完播，下次从头播放 */
  private static readonly FINISHED_THRESHOLD: number = 0.9;

  /** 从历史条目 key 解析播放列表 id；非播放列表条目返回 '' */
  static playlistIdOf(videoId: string): string {
    if (videoId && videoId.startsWith(WatchHistoryStore.PLAYLIST_KEY_PREFIX)) {
      return videoId.substring(WatchHistoryStore.PLAYLIST_KEY_PREFIX.length);
    }
    return '';
  }

  /**
   * 记录一条“播放列表”历史：从播放列表/本地队列进入播放时，
   * 历史保存列表本身而不是单个视频。按 playlistId 去重并置顶。
   */
  static recordPlaylist(playlistId: string, playlistName: string, thumbnailUrl: string): void {
    const id = (playlistId || '').trim();
    if (!id) return;
    const key = WatchHistoryStore.PLAYLIST_KEY_PREFIX + id;
    const all = WatchHistoryStore.getAll();
    const filtered = all.filter((item: WatchHistoryItem) => item.videoId !== key);
    const item: WatchHistoryItem = {
      videoId: key,
      title: playlistName || id,
      author: '',
      thumbnailUrl: thumbnailUrl || '',
      durationSec: 0,
      progressSec: 0,
      lastWatchedAt: Date.now(),
      channelId: '',
      channelAvatarUrl: '',
      channelHandle: ''
    };
    filtered.unshift(item);
    WatchHistoryStore.save(filtered.slice(0, WatchHistoryStore.MAX_COUNT));
    WatchHistoryStore.syncToAppStorage();
  }

  /**
   * 记录/更新一条观看历史，并保存当前进度。
   * 每次调用会将该视频移至列表顶部。
   */
  static record(
    videoId: string,
    title: string,
    author: string,
    thumbnailUrl: string,
    durationSec: number,
    progressSec: number,
    channelId: string = '',
    channelAvatarUrl: string = '',
    channelHandle: string = ''
  ): void {
    if (!videoId || videoId.trim().length === 0) return;

    const all = WatchHistoryStore.getAll();
    // 移除旧条目（如果已存在）
    const filtered = all.filter((item: WatchHistoryItem) => item.videoId !== videoId);

    const item: WatchHistoryItem = {
      videoId: videoId.trim(),
      title: title || videoId,
      author: author || '',
      thumbnailUrl: thumbnailUrl || '',
      durationSec: durationSec >= 0 ? durationSec : 0,
      progressSec: progressSec >= 0 ? progressSec : 0,
      lastWatchedAt: Date.now(),
      channelId: channelId || '',
      channelAvatarUrl: channelAvatarUrl || '',
      channelHandle: channelHandle || ''
    };
    filtered.unshift(item);

    WatchHistoryStore.save(filtered.slice(0, WatchHistoryStore.MAX_COUNT));
    WatchHistoryStore.syncToAppStorage();
  }

  /**
   * 查询某个视频上次停止的位置（秒）。
   * - 返回 0 表示从头播放（从未看过或已看完）
   * - 返回 > 0 表示从该位置恢复播放
   */
  static getProgress(videoId: string): number {
    if (!videoId) return 0;
    const all = WatchHistoryStore.getAll();
    const item = all.find((h: WatchHistoryItem) => h.videoId === videoId);
    if (!item) return 0;
    // 已看完（> 90%）→ 从头
    if (item.durationSec > 0 && item.progressSec / item.durationSec >= WatchHistoryStore.FINISHED_THRESHOLD) {
      return 0;
    }
    // 进度太短（< 5 秒）→ 从头，避免无意义的跳转
    if (item.progressSec < 5) return 0;
    return item.progressSec;
  }

  /** 获取全部历史，按最近观看时间降序 */
  static getAll(): WatchHistoryItem[] {
    const json = PreferencesStore.getString(WatchHistoryStore.KEY, '[]');
    try {
      return JSON.parse(json) as WatchHistoryItem[];
    } catch (err) {
      logger.error('Failed to parse watch history:', JSON.stringify(err));
      return [];
    }
  }

  /** 删除单条记录 */
  static remove(videoId: string): void {
    const all = WatchHistoryStore.getAll();
    WatchHistoryStore.save(all.filter((item: WatchHistoryItem) => item.videoId !== videoId));
    WatchHistoryStore.syncToAppStorage();
  }

  /** 清空所有记录 */
  static clear(): void {
    WatchHistoryStore.save([]);
    WatchHistoryStore.syncToAppStorage();
  }

  /** 完全替换所有记录（恢复用） */
  static replaceAll(items: WatchHistoryItem[]): void {
    WatchHistoryStore.save(items.slice(0, WatchHistoryStore.MAX_COUNT));
    WatchHistoryStore.syncToAppStorage();
  }

  /**
   * 用播放器侧补全到的元数据刷新已有历史条目（不改 lastWatchedAt / progress）。
   * 用于云端同步条目缺 author 等字段时，在打开视频后回填。
   */
  static enrichMetadata(
    videoId: string,
    title: string,
    author: string,
    thumbnailUrl: string,
    durationSec: number = 0,
    channelId: string = '',
    channelAvatarUrl: string = '',
    channelHandle: string = ''
  ): void {
    const id = (videoId || '').trim();
    if (!id) {
      return;
    }
    const all = WatchHistoryStore.getAll();
    let changed = false;
    const next = all.map((item: WatchHistoryItem) => {
      if (item.videoId !== id) {
        return item;
      }
      const merged: WatchHistoryItem = {
        videoId: id,
        title: (title && title.length > 0) ? title : item.title,
        author: (author && author.length > 0) ? author : item.author,
        thumbnailUrl: (thumbnailUrl && thumbnailUrl.length > 0) ? thumbnailUrl : item.thumbnailUrl,
        durationSec: item.durationSec > 0 ? item.durationSec : (durationSec > 0 ? durationSec : 0),
        progressSec: item.progressSec,
        lastWatchedAt: item.lastWatchedAt,
        channelId: item.channelId || channelId || '',
        channelAvatarUrl: item.channelAvatarUrl || channelAvatarUrl || '',
        channelHandle: item.channelHandle || channelHandle || ''
      };
      if (merged.title !== item.title
        || merged.author !== item.author
        || merged.thumbnailUrl !== item.thumbnailUrl
        || merged.durationSec !== item.durationSec
        || merged.channelId !== item.channelId
        || merged.channelAvatarUrl !== item.channelAvatarUrl
        || merged.channelHandle !== item.channelHandle) {
        changed = true;
      }
      return merged;
    });
    if (changed) {
      WatchHistoryStore.save(next);
      WatchHistoryStore.syncToAppStorage();
    }
  }

  /**
   * 单向合并云端历史（FEhistory 最新在前，但无真实时间戳）：
   * - 已有本地条目：保留 lastWatchedAt / progress / duration，只补全元数据，
   *   并作为时间「锚点」；
   * - 仅云端有的条目：不再一律按 now 赋时（那会每次同步都把整页云端历史
   *   冲顶），而是利用远端列表顺序在相邻锚点之间线性插值：
   *     · 位于两个锚点之间 → 取区间内递减插值，保持云端相对顺序且不会
   *       越过本地真正更新的记录；
   *     · 位于所有锚点之前（比本地任何记录都新）→ 从 now 递减，本就该置顶；
   *     · 位于所有锚点之后 → 从最旧锚点继续往下递减，沉到正确位置。
   * - 重复同步幂等：锚点时间戳不变，新条目插值结果稳定，不再乱序冲顶。
   */
  static mergeRemoteHistory(remote: WatchHistoryItem[]): void {
    if (!remote || remote.length === 0) {
      return;
    }
    const local = WatchHistoryStore.getAll();
    const localMap: Record<string, WatchHistoryItem> = {};
    local.forEach((item) => {
      localMap[item.videoId] = item;
    });

    const now = Date.now();
    const seen: Record<string, boolean> = {};
    const MERGE_GAP_MS = 60_000;

    // 1) 去重远端列表，区分锚点（本地已知）与新条目，保持远端最新在前的顺序。
    const entries: HistoryMergeEntry[] = [];
    remote.forEach((item) => {
      const id = (item.videoId || '').trim();
      if (!id || seen[id]) {
        return;
      }
      seen[id] = true;
      const prev = localMap[id];
      if (prev) {
        entries.push({
          item: {
            videoId: id,
            title: (item.title && item.title.length > 0) ? item.title : prev.title,
            author: (item.author && item.author.length > 0) ? item.author : prev.author,
            thumbnailUrl: (item.thumbnailUrl && item.thumbnailUrl.length > 0) ? item.thumbnailUrl : prev.thumbnailUrl,
            durationSec: prev.durationSec > 0 ? prev.durationSec : (item.durationSec || 0),
            progressSec: prev.progressSec,
            lastWatchedAt: prev.lastWatchedAt > 0 ? prev.lastWatchedAt : (item.lastWatchedAt || now),
            channelId: prev.channelId || item.channelId || '',
            channelAvatarUrl: prev.channelAvatarUrl || item.channelAvatarUrl || '',
            channelHandle: prev.channelHandle || item.channelHandle || ''
          },
          isAnchor: true
        });
      } else {
        entries.push({
          item: {
            videoId: id,
            title: item.title || id,
            author: item.author || '',
            thumbnailUrl: item.thumbnailUrl || '',
            durationSec: item.durationSec || 0,
            progressSec: 0,
            lastWatchedAt: 0,
            channelId: item.channelId || '',
            channelAvatarUrl: item.channelAvatarUrl || '',
            channelHandle: item.channelHandle || ''
          },
          isAnchor: false
        });
      }
    });

    // 2) 按连续段为新条目赋插值时间戳。
    let i = 0;
    while (i < entries.length) {
      if (entries[i].isAnchor) {
        i++;
        continue;
      }
      let j = i;
      while (j < entries.length && !entries[j].isAnchor) {
        j++;
      }
      const newerIdx = i - 1;
      const olderIdx = j < entries.length ? j : -1;
      const newerTs = newerIdx >= 0 ? entries[newerIdx].item.lastWatchedAt : -1;
      const olderTs = olderIdx >= 0 ? entries[olderIdx].item.lastWatchedAt : -1;
      for (let k = i; k < j; k++) {
        const offset = k - i + 1;
        let ts: number;
        if (newerTs > 0 && olderTs > 0 && newerTs > olderTs) {
          // 两个锚点之间线性插值（保持单调递减，不会越过任一锚点）。
          ts = newerTs - Math.floor((newerTs - olderTs) * offset / (j - i + 1));
        } else if (newerTs > 0) {
          // 最旧锚点之下：继续向下递减。
          ts = newerTs - offset * MERGE_GAP_MS;
        } else {
          // 所有锚点之上（比本地任何记录都新）：从 now 递减置顶。
          ts = now - k * MERGE_GAP_MS;
        }
        entries[k].item.lastWatchedAt = Math.max(1, ts);
      }
      i = j;
    }

    const merged: WatchHistoryItem[] = entries.map((entry) => entry.item);
    local.forEach((item) => {
      if (!seen[item.videoId]) {
        merged.push(item);
      }
    });

    merged.sort((a: WatchHistoryItem, b: WatchHistoryItem) => b.lastWatchedAt - a.lastWatchedAt);
    WatchHistoryStore.replaceAll(merged);
  }

  /** 从 Preferences 加载并同步到 AppStorage（用于应用启动时初始化） */
  static loadToAppStorage(): void {
    const all = WatchHistoryStore.getAll();
    AppStorage.setOrCreate(APP_STORAGE_KEY, [...all]);
  }

  private static syncToAppStorage(): void {
    const all = WatchHistoryStore.getAll();
    AppStorage.setOrCreate(APP_STORAGE_KEY, [...all]);
  }

  private static save(history: WatchHistoryItem[]): void {
    PreferencesStore.setString(WatchHistoryStore.KEY, JSON.stringify(history));
  }
}
