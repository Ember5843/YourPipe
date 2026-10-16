import { AppLog } from './AppLog';
import { PreferencesStore } from './PreferencesStore';

const logger = AppLog.getInstance('LocalMediaProgressStore');

/** 单个本地文件（下载物 / 导入物）的续播进度。 */
export interface LocalMediaProgress {
  resumeSec: number;
  durationSec: number;
  updatedAt: number;
}

/**
 * 本地文件续播进度：独立于 YouTube 观看历史。
 * WatchHistoryStore 以 YouTube videoId 为唯一键，且本地队列来源会提前 return，
 * 因此本地文件进度按本地条目 id（'local:<taskId>'）单独存这里，绝不写入观看历史。
 */
export class LocalMediaProgressStore {
  private static readonly KEY: string = 'local_media_progress';
  /** 进度超过这个比例视为完播，下次从头播放 */
  private static readonly FINISHED_THRESHOLD: number = 0.9;
  private static cache: Record<string, LocalMediaProgress> | null = null;

  private static load(): Record<string, LocalMediaProgress> {
    if (LocalMediaProgressStore.cache) {
      return LocalMediaProgressStore.cache;
    }
    let parsed: Record<string, LocalMediaProgress> = {};
    try {
      const raw = PreferencesStore.getString(LocalMediaProgressStore.KEY, '');
      if (raw) {
        parsed = JSON.parse(raw) as Record<string, LocalMediaProgress>;
      }
    } catch (e) {
      logger.warn(`load failed: ${e}`);
      parsed = {};
    }
    LocalMediaProgressStore.cache = parsed;
    return parsed;
  }

  private static persist(): void {
    try {
      PreferencesStore.setString(LocalMediaProgressStore.KEY, JSON.stringify(LocalMediaProgressStore.cache ?? {}));
    } catch (e) {
      logger.warn(`persist failed: ${e}`);
    }
  }

  /** 记录/更新本地文件的播放进度。 */
  static record(localId: string, progressSec: number, durationSec: number): void {
    if (!localId) return;
    const all = LocalMediaProgressStore.load();
    all[localId] = {
      resumeSec: progressSec >= 0 ? progressSec : 0,
      durationSec: durationSec >= 0 ? durationSec : 0,
      updatedAt: Date.now()
    };
    LocalMediaProgressStore.persist();
    logger.debug(`progress saved id=${localId} at ${(progressSec || 0).toFixed(1)}s`);
  }

  /**
   * 上次停止位置（秒）。0 = 从头（从未看过 / 已看完 / 进度太短）。
   */
  static getProgress(localId: string): number {
    if (!localId) return 0;
    const item = LocalMediaProgressStore.load()[localId];
    if (!item) return 0;
    if (item.durationSec > 0 && item.resumeSec / item.durationSec >= LocalMediaProgressStore.FINISHED_THRESHOLD) {
      return 0;
    }
    if (item.resumeSec < 5) return 0;
    return item.resumeSec;
  }

  static remove(localId: string): void {
    if (!localId) return;
    const all = LocalMediaProgressStore.load();
    const next: Record<string, LocalMediaProgress> = {};
    for (const key of Object.keys(all)) {
      if (key !== localId) {
        next[key] = all[key];
      }
    }
    LocalMediaProgressStore.cache = next;
    LocalMediaProgressStore.persist();
  }

  static clearAll(): void {
    LocalMediaProgressStore.cache = {};
    LocalMediaProgressStore.persist();
  }
}
