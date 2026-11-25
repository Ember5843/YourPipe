import { AppLog } from './AppLog';
import { preferences } from '@kit.ArkData';
import common from '@ohos.app.ability.common';

const logger = AppLog.getInstance('PreferencesStore');

export class PreferencesStore {
  private static scheduledFlush: Promise<void> | null = null;
  private static flushTail: Promise<void> = Promise.resolve();
  private static instance: preferences.Preferences | null = null;
  private static readonly STORE_NAME: string = 'yourtube_store';

  static init(context: common.UIAbilityContext): void {
    if (PreferencesStore.instance) {
      return;
    }
    const options: preferences.Options = { name: PreferencesStore.STORE_NAME };
    PreferencesStore.instance = preferences.getPreferencesSync(context, options);
  }

  static getString(key: string, fallback: string): string {
    if (!PreferencesStore.instance) {
      return fallback;
    }
    return PreferencesStore.instance.getSync(key, fallback) as string;
  }

  static setString(key: string, value: string): void {
    if (!PreferencesStore.instance) {
      return;
    }
    PreferencesStore.instance.putSync(key, value);
    PreferencesStore.scheduleFlush().catch((err: Error) => logger.error(`Preferences flush failed: ${err.message}`));
  }

  /** One flush for all synchronous writes in a logical settings update. */
  private static scheduleFlush(): Promise<void> {
    if (PreferencesStore.scheduledFlush) return PreferencesStore.scheduledFlush;
    const storage = PreferencesStore.instance;
    if (!storage) return Promise.resolve();
    const scheduled = Promise.resolve().then(() => {
      PreferencesStore.scheduledFlush = null;
      const task = PreferencesStore.flushTail.catch((e: Error) => {
        logger.warn(`previous preferences flush failed: ${e.message}`);
      }).then(() => storage.flush());
      PreferencesStore.flushTail = task;
      return task;
    });
    PreferencesStore.scheduledFlush = scheduled;
    return scheduled;
  }

  static async flushPending(): Promise<void> {
    let pending: Promise<void>;
    do {
      pending = PreferencesStore.scheduledFlush ?? PreferencesStore.flushTail;
      await pending;
    } while (PreferencesStore.scheduledFlush !== null || pending !== PreferencesStore.flushTail);
  }

  static async setStrings(entries: Record<string, string>): Promise<void> {
    if (!PreferencesStore.instance) throw new Error('Preferences are not initialized');
    for (const key of Object.keys(entries)) PreferencesStore.instance.putSync(key, entries[key]);
    await PreferencesStore.scheduleFlush();
  }

  /** 获取 PreferencesStore 中的所有键值对（导出用） */
  static getAllEntries(): Record<string, string> {
    const result: Record<string, string> = {};
    if (!PreferencesStore.instance) {
      return result;
    }
    try {
      const all = PreferencesStore.instance.getAllSync() as Record<string, Object>;
      for (const key of Object.keys(all)) {
        const value = all[key];
        result[key] = typeof value === 'string' ? value : JSON.stringify(value);
      }
    } catch (e) {
      logger.error('Failed to get all preferences entries:', JSON.stringify(e));
    }
    return result;
  }

  /** 恢复设置用：只覆盖写入 cfg_ 前缀键，绝不清空历史/订阅等其他数据 */
  static async restoreConfigEntries(entries: Record<string, string>): Promise<void> {
    if (!PreferencesStore.instance) {
      return;
    }
    try {
      for (const key of Object.keys(entries)) {
        if (!key.startsWith('cfg_')) {
          continue;
        }
        PreferencesStore.instance.putSync(key, entries[key]);
      }
      await PreferencesStore.scheduleFlush();
      logger.info('PreferencesStore restoreConfigEntries done');
    } catch (e) {
      logger.error('Failed to restore config entries:', JSON.stringify(e));
      throw e as Error;
    }
  }

  /** 清除 PreferencesStore 中的所有数据 */
  static async clearAll(): Promise<void> {
    if (!PreferencesStore.instance) {
      return;
    }
    try {
      PreferencesStore.instance.clearSync();
      await PreferencesStore.scheduleFlush();
      logger.info('PreferencesStore cleared all data');
    } catch (e) {
      logger.error('Failed to clear PreferencesStore:', JSON.stringify(e));
      throw e as Error;
    }
  }
}
