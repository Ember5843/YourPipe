import { AppLog } from './AppLog';
import { PreferencesStore } from './PreferencesStore';

const logger = AppLog.getInstance('WatchHistoryStore');
const APP_STORAGE_KEY = 'watchHistory';

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
  /** 进度超过这个比例时视为完播，下次从头播放 */
  private static readonly FINISHED_THRESHOLD: number = 0.9;

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
