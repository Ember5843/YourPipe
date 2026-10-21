import { common } from '@kit.AbilityKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { VideoItem } from 'youtube_core';
import { AppLog } from './AppLog';
import { PreferencesStore } from './PreferencesStore';
import { LocalMediaProgressStore } from './LocalMediaProgressStore';

const logger = AppLog.getInstance('LocalMediaStore');

/** 导入到应用沙箱的本地视频（与下载库相互独立）。 */
@Observed
export class LocalMediaItem {
  @Track id: string;
  @Track title: string;
  @Track fileName: string;
  @Track path: string;
  @Track sizeBytes: number;
  @Track addedAt: number;

  constructor(id: string, title: string, fileName: string, path: string, sizeBytes: number, addedAt: number) {
    this.id = id;
    this.title = title;
    this.fileName = fileName;
    this.path = path;
    this.sizeBytes = sizeBytes;
    this.addedAt = addedAt;
  }
}

export interface LocalMediaImportResult {
  added: number;
  failed: number;
}

interface LocalMediaRecord {
  id: string;
  title: string;
  fileName: string;
  sizeBytes: number;
  addedAt: number;
}

/**
 * 本地文件库：
 * - 文件复制到 `filesDir/local_media/`，索引持久化为 `local_media_json`；
 * - 播放复用 PlaySession 的 LOCAL_FILE 通道（`/local:<id>` 续播键）；
 * - 属于用户媒体，和 `filesDir/downloads` 一样在「清除应用全部数据」时保留。
 */
export class LocalMediaStore {
  private static readonly KEY: string = 'local_media_json';
  private static readonly DIR: string = 'local_media';
  private static readonly MAX_IMPORT_FILES: number = 10;
  private static readonly VIDEO_EXTS: string[] = ['.mp4', '.m4v', '.mkv', '.webm', '.mov', '.ts', '.flv', '.avi'];

  private static context(): common.UIAbilityContext | undefined {
    return AppStorage.get<common.UIAbilityContext>('context');
  }

  private static dirPath(context: common.UIAbilityContext): string {
    return `${context.filesDir}/${LocalMediaStore.DIR}`;
  }

  /** 启动对账：索引里文件已不存在的条目直接丢弃。 */
  static restore(): void {
    const context = LocalMediaStore.context();
    if (!context) {
      logger.warn('restore skipped: no context');
      return;
    }
    const dir = LocalMediaStore.dirPath(context);
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      logger.warn(`restore mkdir failed: ${(e as Error).message || e}`);
    }

    let records: LocalMediaRecord[] = [];
    try {
      const raw = PreferencesStore.getString(LocalMediaStore.KEY, '');
      if (raw.length > 0) {
        records = JSON.parse(raw) as LocalMediaRecord[];
      }
    } catch (e) {
      logger.warn(`restore parse failed: ${(e as Error).message || e}`);
      records = [];
    }

    const items: LocalMediaItem[] = [];
    let dropped = 0;
    records.forEach((record: LocalMediaRecord) => {
      const path = `${dir}/${record.fileName}`;
      let exists = false;
      try {
        exists = fs.accessSync(path);
      } catch (_e) {
        exists = false;
      }
      if (!exists) {
        dropped += 1;
        return;
      }
      items.push(new LocalMediaItem(record.id, record.title, record.fileName, path,
        record.sizeBytes || 0, record.addedAt || 0));
    });
    if (dropped > 0) {
      LocalMediaStore.persist(items);
    }
    AppStorage.setOrCreate('localMedia', items);
    logger.info(`restore: restored=${items.length} dropped=${dropped}`);
  }

  static items(): LocalMediaItem[] {
    return AppStorage.get<LocalMediaItem[]>('localMedia') ?? [];
  }

  /** 「清除应用全部数据」：删除所有导入文件与索引。 */
  static clearAll(): void {
    const items = LocalMediaStore.items().slice();
    items.forEach((item: LocalMediaItem) => {
      try {
        if (fs.accessSync(item.path)) {
          fs.unlinkSync(item.path);
        }
      } catch (e) {
        logger.warn(`clearAll unlink failed id=${item.id}: ${(e as Error).message || e}`);
      }
      LocalMediaProgressStore.remove(`local:${item.id}`);
    });
    LocalMediaStore.publish([]);
    logger.info(`clearAll: removed=${items.length}`);
  }

  /** 系统文件选择器 → 复制进沙箱并落索引。 */
  static async importFromUris(uris: string[]): Promise<LocalMediaImportResult> {
    const context = LocalMediaStore.context();
    if (!context) {
      return { added: 0, failed: uris.length };
    }
    const dir = LocalMediaStore.dirPath(context);
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (e) {
      logger.error(`import mkdir failed: ${(e as Error).message || e}`);
      return { added: 0, failed: uris.length };
    }

    const all = LocalMediaStore.items().slice();
    let added = 0;
    let failed = 0;
    const limit = Math.min(uris.length, LocalMediaStore.MAX_IMPORT_FILES);
    for (let i = 0; i < limit; i++) {
      const uri = uris[i];
      try {
        // fileUri.FileUri(...).path 同时适用于 picker 返回的 file:// URI 与普通沙箱路径。
        const srcPath = uri.startsWith('file://') ? new fileUri.FileUri(uri).path : uri;
        const ext = LocalMediaStore.extensionOf(srcPath);
        if (!LocalMediaStore.isSupportedVideo(ext)) {
          failed += 1;
          logger.warn(`import skipped unsupported ext=${ext || '-'}`);
          continue;
        }
        let size = 0;
        try {
          size = fs.statSync(srcPath).size;
        } catch (_e) {
          size = 0;
        }
        const id = `imp_${Date.now()}_${i}`;
        const fileName = `${id}${ext}`;
        const dstPath = `${dir}/${fileName}`;
        fs.copyFileSync(srcPath, dstPath);
        const title = LocalMediaStore.titleOf(srcPath);
        all.push(new LocalMediaItem(id, title, fileName, dstPath, size, Date.now()));
        added += 1;
        logger.info(`import ok id=${id} ext=${ext} size=${size}`);
      } catch (e) {
        failed += 1;
        logger.error(`import failed uri=${LocalMediaStore.redactUri(uri)}: ${(e as Error).message || e}`);
      }
    }
    if (added > 0) {
      LocalMediaStore.publish(all);
    }
    logger.info(`import done added=${added} failed=${failed} requested=${uris.length}`);
    return { added, failed };
  }

  static delete(item: LocalMediaItem): void {
    try {
      if (fs.accessSync(item.path)) {
        fs.unlinkSync(item.path);
      }
    } catch (e) {
      logger.warn(`delete file failed id=${item.id}: ${(e as Error).message || e}`);
    }
    LocalMediaProgressStore.remove(`local:${item.id}`);
    const next = LocalMediaStore.items().filter((it: LocalMediaItem) => it.id !== item.id);
    LocalMediaStore.publish(next);
    logger.info(`delete id=${item.id} remaining=${next.length}`);
  }

  /** 本地条目 → 播放用的 VideoItem（videoId 同时是本地续播键）。 */
  static toVideoItem(item: LocalMediaItem): VideoItem {
    const video = new VideoItem(0, `local:${item.id}`, item.title, '', '', '', false,
      '#1A1A1A', '', '', '');
    video.localMediaPath = item.path;
    return video;
  }

  private static publish(items: LocalMediaItem[]): void {
    AppStorage.setOrCreate('localMedia', items);
    LocalMediaStore.persist(items);
  }

  private static persist(items: LocalMediaItem[]): void {
    const records: LocalMediaRecord[] = items.map((item: LocalMediaItem): LocalMediaRecord => {
      const record: LocalMediaRecord = {
        id: item.id,
        title: item.title,
        fileName: item.fileName,
        sizeBytes: item.sizeBytes,
        addedAt: item.addedAt
      };
      return record;
    });
    try {
      PreferencesStore.setString(LocalMediaStore.KEY, JSON.stringify(records));
    } catch (e) {
      logger.warn(`persist failed: ${(e as Error).message || e}`);
    }
  }

  private static extensionOf(path: string): string {
    const dot = path.lastIndexOf('.');
    if (dot < 0) return '';
    return path.substring(dot).toLowerCase();
  }

  private static isSupportedVideo(ext: string): boolean {
    return LocalMediaStore.VIDEO_EXTS.includes(ext);
  }

  private static titleOf(path: string): string {
    const slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    const name = slash >= 0 ? path.substring(slash + 1) : path;
    const dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  private static redactUri(uri: string): string {
    const slash = Math.max(uri.lastIndexOf('/'), uri.lastIndexOf('\\'));
    return slash >= 0 ? `…${uri.substring(slash)}` : uri;
  }
}
