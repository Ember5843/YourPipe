import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { AppLog } from '../AppLog';
import { ExperimentalConfig } from './ExperimentalConfig';
import { CommunityHttp } from './CommunityHttp';

const logger = AppLog.getInstance('AiListStore');

const BLOCK_URL: string = 'https://raw.githubusercontent.com/Override92/AiSList/main/AiSList/aislist_blocklist.txt';
const WARN_URL: string = 'https://raw.githubusercontent.com/Override92/AiSList/main/AiSList/aislist_warnlist.txt';
const DIR_NAME: string = 'community';
const BLOCK_FILE: string = 'aislist_blocklist.txt';
const WARN_FILE: string = 'aislist_warnlist.txt';
const META_FILE: string = 'aislist_meta.json';

interface AiListMeta {
  lastSyncMs?: number;
  blockCount?: number;
  warnCount?: number;
}

/** 供设置页响应式展示的同步状态（放 AppStorage('aiListStatus')）。 */
@Observed
export class AiListStatus {
  @Track syncing: boolean = false;
  @Track lastSyncMs: number = 0;
  @Track blockCount: number = 0;
  @Track warnCount: number = 0;
  @Track error: string = '';
}

/**
 * AiSList 频道黑名单：blocklist / warnlist 纯文本，按 @handle 或 UC channelId 匹配。
 * 数据来自 https://github.com/Override92/AiSList（CC BY-NC 4.0）。
 */
export class AiListStore {
  private static instance: AiListStore | null = null;

  private status: AiListStatus = new AiListStatus();
  private blockKeys: Set<string> = new Set();
  private warnKeys: Set<string> = new Set();
  private context: common.UIAbilityContext | null = null;
  private initialized: boolean = false;
  private syncPromise: Promise<void> | null = null;

  static getInstance(): AiListStore {
    if (!AiListStore.instance) {
      AiListStore.instance = new AiListStore();
    }
    return AiListStore.instance;
  }

  init(context: common.UIAbilityContext): void {
    if (this.initialized) {
      return;
    }
    this.initialized = true;
    this.context = context;
    AppStorage.setOrCreate('aiListStatus', this.status);
    this.loadCache();
    this.syncIfNeeded();
  }

  getStatus(): AiListStatus {
    return this.status;
  }

  /** 'block' | 'warn' | ''；未启用时始终为空。 */
  flagFor(channelId: string, channelHandle: string): string {
    const cfg = AiListStore.config();
    if (!cfg || !cfg.aiListEnabled) {
      return '';
    }
    if (this.matches(this.blockKeys, channelId, channelHandle)) {
      return 'block';
    }
    if (this.matches(this.warnKeys, channelId, channelHandle)) {
      return 'warn';
    }
    return '';
  }

  isBlocked(channelId: string, channelHandle: string): boolean {
    return this.flagFor(channelId, channelHandle) === 'block';
  }

  /** 条件同步：按 aiListSyncDays 判断是否过期（0 = 仅手动）。 */
  syncIfNeeded(): void {
    const cfg = AiListStore.config();
    if (!cfg || !cfg.aiListEnabled) {
      return;
    }
    const days = cfg.aiListSyncDays;
    const stale = days > 0 && Date.now() - cfg.aiListLastSyncMs > days * 24 * 60 * 60 * 1000;
    if (!stale || this.status.syncing) {
      return;
    }
    this.sync().catch((_e: Error) => {});
  }

  /** 用户点「立即更新」。 */
  syncNow(): Promise<void> {
    return this.sync();
  }

  clear(): void {
    const dir = this.dir();
    if (dir.length > 0) {
      for (const name of [BLOCK_FILE, WARN_FILE, META_FILE]) {
        try {
          const path = `${dir}/${name}`;
          if (fileIo.accessSync(path)) {
            fileIo.unlinkSync(path);
          }
        } catch (_e) {
          // 单个文件清理失败不阻塞
        }
      }
    }
    this.blockKeys.clear();
    this.warnKeys.clear();
    this.status.lastSyncMs = 0;
    this.status.blockCount = 0;
    this.status.warnCount = 0;
    this.status.error = '';
    AppStorage.setOrCreate('aiListVersion', Date.now());
    logger.info('cleared');
  }

  private sync(): Promise<void> {
    if (this.syncPromise) {
      return this.syncPromise;
    }
    this.syncPromise = this.runSync().finally(() => {
      this.syncPromise = null;
    });
    return this.syncPromise;
  }

  private async runSync(): Promise<void> {
    const cfg = AiListStore.config();
    if (!cfg) {
      return;
    }
    this.status.syncing = true;
    this.status.error = '';
    const startedAt = Date.now();
    logger.info(`sync start warnlist=${cfg.aiListWarnList}`);
    try {
      const blockText = await CommunityHttp.getText(BLOCK_URL, 30000);
      if (blockText.status !== 200 || blockText.body.length === 0) {
        throw new Error(`blocklist HTTP ${blockText.status}`);
      }
      const blockSet: Set<string> = new Set();
      AiListStore.parseInto(blockText.body, blockSet);
      this.blockKeys = blockSet;
      this.writeText(BLOCK_FILE, blockText.body);

      let warnSet: Set<string> = new Set();
      if (cfg.aiListWarnList) {
        const warnText = await CommunityHttp.getText(WARN_URL, 30000);
        if (warnText.status === 200 && warnText.body.length > 0) {
          AiListStore.parseInto(warnText.body, warnSet);
          this.writeText(WARN_FILE, warnText.body);
        }
      } else {
        try {
          const warnPath = `${this.dir()}/${WARN_FILE}`;
          if (fileIo.accessSync(warnPath)) {
            fileIo.unlinkSync(warnPath);
          }
        } catch (_e) {
          // ignore
        }
      }
      this.warnKeys = warnSet;

      const now = Date.now();
      this.status.lastSyncMs = now;
      this.status.blockCount = this.blockKeys.size;
      this.status.warnCount = this.warnKeys.size;
      this.writeMeta(now);
      cfg.aiListLastSyncMs = now;
      cfg.saveToPreferences();
      AppStorage.setOrCreate('aiListVersion', now);
      logger.info(`sync done blocks=${this.status.blockCount} warns=${this.status.warnCount} `
        + `elapsed=${Date.now() - startedAt}ms`);
    } catch (e) {
      this.status.error = (e as Error).message || String(e);
      logger.warn(`sync failed: ${this.status.error}`);
    } finally {
      this.status.syncing = false;
    }
  }

  private loadCache(): void {
    const blockText = this.readText(BLOCK_FILE);
    if (blockText.length > 0) {
      const set: Set<string> = new Set();
      AiListStore.parseInto(blockText, set);
      this.blockKeys = set;
    }
    const warnText = this.readText(WARN_FILE);
    if (warnText.length > 0) {
      const set: Set<string> = new Set();
      AiListStore.parseInto(warnText, set);
      this.warnKeys = set;
    }
    const metaText = this.readText(META_FILE);
    if (metaText.length > 0) {
      try {
        const meta = JSON.parse(metaText) as AiListMeta;
        if (typeof meta.lastSyncMs === 'number') {
          this.status.lastSyncMs = meta.lastSyncMs;
        }
      } catch (_e) {
        // ignore corrupt meta
      }
    }
    this.status.blockCount = this.blockKeys.size;
    this.status.warnCount = this.warnKeys.size;
    logger.info(`cache loaded blocks=${this.status.blockCount} warns=${this.status.warnCount} `
      + `lastSync=${this.status.lastSyncMs}`);
  }

  private static parseInto(text: string, target: Set<string>): void {
    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0 || line.startsWith('!')) {
        continue;
      }
      const key = AiListStore.normalizeKey(line);
      if (key.length > 0) {
        target.add(key);
      }
    }
  }

  private static normalizeKey(raw: string): string {
    const value = raw.trim();
    if (value.length === 0) {
      return '';
    }
    if (value.startsWith('@')) {
      return value.substring(1).toLowerCase();
    }
    if (value.startsWith('UC') && value.length >= 20) {
      return value;
    }
    return value.toLowerCase();
  }

  private matches(keys: Set<string>, channelId: string, channelHandle: string): boolean {
    const id = (channelId || '').trim();
    if (id.length > 0 && keys.has(id)) {
      return true;
    }
    const handle = (channelHandle || '').trim();
    if (handle.length === 0) {
      return false;
    }
    const normalized = handle.startsWith('@') ? handle.substring(1).toLowerCase() : handle.toLowerCase();
    return keys.has(normalized);
  }

  private static config(): ExperimentalConfig | null {
    return AppStorage.get<ExperimentalConfig>('experimentalConfig') ?? null;
  }

  private dir(): string {
    return this.context ? `${this.context.cacheDir}/${DIR_NAME}` : '';
  }

  private readText(name: string): string {
    const dir = this.dir();
    if (dir.length === 0) {
      return '';
    }
    try {
      const path = `${dir}/${name}`;
      if (!fileIo.accessSync(path)) {
        return '';
      }
      return fileIo.readTextSync(path);
    } catch (e) {
      logger.warn(`read ${name} failed: ${(e as Error).message || e}`);
      return '';
    }
  }

  private writeText(name: string, text: string): void {
    const dir = this.dir();
    if (dir.length === 0) {
      return;
    }
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const file = fileIo.openSync(`${dir}/${name}`,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      fileIo.closeSync(file);
    } catch (e) {
      logger.warn(`write ${name} failed: ${(e as Error).message || e}`);
    }
  }

  private writeMeta(lastSyncMs: number): void {
    this.writeText(META_FILE, JSON.stringify({
      lastSyncMs: lastSyncMs,
      blockCount: this.status.blockCount,
      warnCount: this.status.warnCount
    } as AiListMeta));
  }
}
