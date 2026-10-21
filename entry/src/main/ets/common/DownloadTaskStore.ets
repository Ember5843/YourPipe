import { AppLog } from './AppLog';
import { PreferencesStore } from './PreferencesStore';

const logger = AppLog.getInstance('DownloadTaskStore');

/**
 * 下载条目的持久化 DTO。
 * 运行时 StreamInfo / context 不可序列化，不落盘；已完成条目重启后按 outputPath 还原。
 */
export interface DownloadTaskRecord {
  id: string;
  videoId: string;
  title: string;
  author: string;
  thumbnailUrl: string;
  outputPath: string;
  taskDir: string;
  createdAt: number;
  totalSize: number;
  status: string;
  /** 手动导出到的路径（条目与导出文件对应；删除条目不触碰该副本）。 */
  exportedPath: string;
  /** 暂停任务的断点续传身份：分片文件对应的流 itag（重启后仍能续）。 */
  resumeVideoItag: number;
  resumeAudioItag: number;
}

/**
 * 下载条目索引：PreferencesStore key `download_tasks_json`。
 * 这是 filesDir/downloads 下文件的唯一索引 —— 条目丢了文件就成了孤儿，
 * 因此它在"清除全部数据"下刻意保留（与 filesDir/downloads 的约定一致）。
 */
export class DownloadTaskStore {
  private static readonly KEY: string = 'download_tasks_json';

  static save(records: DownloadTaskRecord[]): void {
    try {
      PreferencesStore.setString(DownloadTaskStore.KEY, JSON.stringify(records));
    } catch (e) {
      logger.warn(`save failed: ${e}`);
    }
  }

  static load(): DownloadTaskRecord[] {
    try {
      const raw = PreferencesStore.getString(DownloadTaskStore.KEY, '');
      if (!raw) {
        return [];
      }
      return JSON.parse(raw) as DownloadTaskRecord[];
    } catch (e) {
      logger.warn(`load failed: ${e}`);
      return [];
    }
  }
}
