import { AppLog } from './AppLog';
import { preferences } from '@kit.ArkData';
import { BusinessError } from '@kit.BasicServicesKit';
import common from '@ohos.app.ability.common';

const logger = AppLog.getInstance('PreferencesStore');

export class PreferencesStore {
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
    PreferencesStore.instance.flush((err: BusinessError) => {
      if (err) {
        logger.error(`Preferences flush failed. Code:${err.code}, message:${err.message}`);
      }
    });
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

  /** 批量写入 PreferencesStore（恢复用），会先清空 */
  static setAllEntries(entries: Record<string, string>): void {
    if (!PreferencesStore.instance) {
      return;
    }
    try {
      PreferencesStore.instance.clearSync();
      for (const key of Object.keys(entries)) {
        PreferencesStore.instance.putSync(key, entries[key]);
      }
      PreferencesStore.instance.flush((err: BusinessError) => {
        if (err) {
          logger.error(`Preferences setAllEntries flush failed. Code:${err.code}, message:${err.message}`);
        }
      });
      logger.info('PreferencesStore setAllEntries done');
    } catch (e) {
      logger.error('Failed to set all preferences entries:', JSON.stringify(e));
    }
  }

  /** 清除 PreferencesStore 中的所有数据 */
  static clearAll(): void {
    if (!PreferencesStore.instance) {
      return;
    }
    try {
      PreferencesStore.instance.clearSync();
      PreferencesStore.instance.flush((err: BusinessError) => {
        if (err) {
          logger.error(`Preferences clear flush failed. Code:${err.code}, message:${err.message}`);
        }
      });
      logger.info('PreferencesStore cleared all data');
    } catch (e) {
      logger.error('Failed to clear PreferencesStore:', JSON.stringify(e));
    }
  }
}
