import { fileIo as fs, fileUri, picker } from '@kit.CoreFileKit';
import common from '@ohos.app.ability.common';
import { AuthSessionManager, AuthBackupState } from 'youtube_core';
import { AppLog } from './AppLog';
import { PreferencesStore } from './PreferencesStore';
import { LocalStore } from './LocalStore';
import { WatchHistoryStore, WatchHistoryItem } from './WatchHistoryStore';
import { SearchHistoryStore, SearchHistoryItem } from './SearchHistoryStore';
import { UIConfig } from './AppState';
import { PlaybackConfig } from './PlaybackConfig';
import { SubscriptionUser } from './SubscriptionModel';
import { PlaylistItem, StoredLocalQueue } from './PlaylistModel';
import { VideoItem } from 'youtube_core';
import {
  AppBackupData,
  BackupItemKey,
  BackupItems,
  ALL_BACKUP_ITEM_KEYS
} from './model/BackupModels';

const logger = AppLog.getInstance('DataBackupManager');
const BACKUP_APP_ID: string = 'net.yourpipe';
const BACKUP_VERSION: number = 1;
const APP_VERSION: string = '0.5.1';

export class BackupError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'BackupError';
  }
}

export class DataBackupManager {
  static buildBackup(selected: BackupItemKey[]): AppBackupData {
    const items: BackupItems = {
      settings: undefined,
      subscriptions: undefined,
      favorites: undefined,
      playlists: undefined,
      localQueues: undefined,
      watchHistory: undefined,
      searchHistory: undefined,
      auth: undefined
    };

    for (const key of selected) {
      switch (key) {
        case 'settings':
          items.settings = DataBackupManager.collectSettings();
          break;
        case 'subscriptions':
          items.subscriptions = AppStorage.get<SubscriptionUser[]>('subscriptions') ?? [];
          break;
        case 'favorites':
          items.favorites = AppStorage.get<VideoItem[]>('favorites') ?? [];
          break;
        case 'playlists':
          items.playlists = AppStorage.get<PlaylistItem[]>('playlists') ?? [];
          break;
        case 'localQueues':
          items.localQueues = AppStorage.get<StoredLocalQueue[]>('localQueues') ?? [];
          break;
        case 'watchHistory':
          items.watchHistory = WatchHistoryStore.getAll();
          break;
        case 'searchHistory':
          items.searchHistory = SearchHistoryStore.getSearchHistory();
          break;
        case 'auth': {
          const authManager = AuthSessionManager.getInstance();
          items.auth = authManager ? authManager.exportAuthState() : undefined;
          break;
        }
      }
    }

    return {
      appId: BACKUP_APP_ID,
      appVersion: APP_VERSION,
      backupVersion: BACKUP_VERSION,
      exportedAt: Date.now(),
      items
    };
  }

  private static collectSettings(): Record<string, string> {
    const all = PreferencesStore.getAllEntries();
    const settings: Record<string, string> = {};
    for (const key of Object.keys(all)) {
      if (key.startsWith('cfg_')) {
        settings[key] = all[key];
      }
    }
    return settings;
  }

  static async saveBackupToFile(backup: AppBackupData): Promise<string> {
    const context = AppStorage.get<common.UIAbilityContext>('context');
    if (!context) {
      throw new BackupError('无法获取应用上下文');
    }

    const filePicker = new picker.DocumentViewPicker(context);
    const options = new picker.DocumentSaveOptions();
    const dateStr = DataBackupManager.formatDate(new Date(backup.exportedAt));
    options.newFileNames = [`yourpipe_backup_${dateStr}.json`];
    options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;

    const result = await filePicker.save(options);
    if (!result || result.length === 0) {
      throw new BackupError('未选择保存路径');
    }

    const dirUri = result[0];
    const fileName = options.newFileNames[0];
    const path = new fileUri.FileUri(`${dirUri}/${fileName}`).path;
    const content = JSON.stringify(backup);

    const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content);
      fs.fsync(file.fd);
    } finally {
      fs.closeSync(file);
    }

    logger.info(`Backup saved to ${path}`);
    return path;
  }

  static async loadBackupFromFile(): Promise<AppBackupData> {
    const context = AppStorage.get<common.UIAbilityContext>('context');
    if (!context) {
      throw new BackupError('无法获取应用上下文');
    }

    const filePicker = new picker.DocumentViewPicker(context);
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['.json'];

    const result = await filePicker.select(options);
    if (!result || result.length === 0) {
      throw new BackupError('未选择文件');
    }

    const path = new fileUri.FileUri(result[0]).path;
    const content = fs.readTextSync(path);

    let backup: AppBackupData;
    try {
      backup = JSON.parse(content) as AppBackupData;
    } catch (e) {
      throw new BackupError('备份文件格式错误');
    }

    if (backup.appId !== BACKUP_APP_ID) {
      throw new BackupError('备份文件不属于本应用');
    }
    if (backup.backupVersion !== BACKUP_VERSION) {
      throw new BackupError('备份文件版本不受支持');
    }
    if (!backup.items) {
      throw new BackupError('备份文件内容为空');
    }

    logger.info(`Backup loaded from ${path}`);
    return backup;
  }

  static getAvailableItems(backup: AppBackupData): BackupItemKey[] {
    const available: BackupItemKey[] = [];
    const items = backup.items;
    const checkItem = (key: BackupItemKey): Object | undefined => {
      switch (key) {
        case 'settings': return items.settings;
        case 'subscriptions': return items.subscriptions;
        case 'favorites': return items.favorites;
        case 'playlists': return items.playlists;
        case 'localQueues': return items.localQueues;
        case 'watchHistory': return items.watchHistory;
        case 'searchHistory': return items.searchHistory;
        case 'auth': return items.auth;
        default: return undefined;
      }
    };
    for (const key of ALL_BACKUP_ITEM_KEYS) {
      const value = checkItem(key);
      if (value !== undefined && value !== null) {
        available.push(key);
      }
    }
    return available;
  }

  static applyBackup(backup: AppBackupData, selected: BackupItemKey[]): void {
    const items = backup.items;
    const getItem = (key: BackupItemKey): Object | undefined => {
      switch (key) {
        case 'settings': return items.settings;
        case 'subscriptions': return items.subscriptions;
        case 'favorites': return items.favorites;
        case 'playlists': return items.playlists;
        case 'localQueues': return items.localQueues;
        case 'watchHistory': return items.watchHistory;
        case 'searchHistory': return items.searchHistory;
        case 'auth': return items.auth;
        default: return undefined;
      }
    };
    for (const key of selected) {
      const value = getItem(key);
      if (value === undefined || value === null) {
        continue;
      }
      switch (key) {
        case 'settings':
          DataBackupManager.restoreSettings(value as Record<string, string>);
          break;
        case 'subscriptions':
          DataBackupManager.restoreSubscriptions(value as SubscriptionUser[]);
          break;
        case 'favorites':
          DataBackupManager.restoreFavorites(value as VideoItem[]);
          break;
        case 'playlists':
          DataBackupManager.restorePlaylists(value as PlaylistItem[]);
          break;
        case 'localQueues':
          DataBackupManager.restoreLocalQueues(value as StoredLocalQueue[]);
          break;
        case 'watchHistory':
          WatchHistoryStore.replaceAll(value as WatchHistoryItem[]);
          break;
        case 'searchHistory':
          SearchHistoryStore.replaceAll(value as SearchHistoryItem[]);
          break;
        case 'auth':
          DataBackupManager.restoreAuth(value as AuthBackupState);
          break;
      }
    }
    logger.info(`Backup applied for items: ${selected.join(', ')}`);
  }

  private static restoreSettings(entries: Record<string, string>): void {
    const validEntries: Record<string, string> = {};
    for (const key of Object.keys(entries)) {
      if (key.startsWith('cfg_')) {
        validEntries[key] = entries[key];
      }
    }
    PreferencesStore.setAllEntries(validEntries);
    const uiConfig = UIConfig.loadFromPreferences();
    const playbackConfig = PlaybackConfig.loadFromPreferences();
    AppStorage.setOrCreate('uiConfig', uiConfig);
    AppStorage.setOrCreate('playbackConfig', playbackConfig);
  }

  private static restoreSubscriptions(items: SubscriptionUser[]): void {
    const list = Array.isArray(items) ? items : [];
    AppStorage.setOrCreate('subscriptions', list);
    PreferencesStore.setString('subscriptionsJson', LocalStore.saveSubscriptions(list));
  }

  private static restoreFavorites(items: VideoItem[]): void {
    const list = Array.isArray(items) ? items : [];
    AppStorage.setOrCreate('favorites', list);
    PreferencesStore.setString('favoritesJson', LocalStore.saveFavorites(list));
  }

  private static restorePlaylists(items: PlaylistItem[]): void {
    const list = Array.isArray(items) ? items : [];
    AppStorage.setOrCreate('playlists', list);
    PreferencesStore.setString('playlistsJson', LocalStore.savePlaylists(list));
  }

  private static restoreLocalQueues(items: StoredLocalQueue[]): void {
    const list = Array.isArray(items) ? items : [];
    AppStorage.setOrCreate('localQueues', list);
    PreferencesStore.setString('localQueuesJson', LocalStore.saveLocalQueues(list));
  }

  private static restoreAuth(state: AuthBackupState): void {
    const authManager = AuthSessionManager.getInstance();
    if (authManager) {
      authManager.importAuthState(state);
    }
  }

  private static formatDate(date: Date): string {
    const pad = (n: number): string => (n < 10 ? `0${n}` : `${n}`);
    return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}_${pad(date.getHours())}${pad(date.getMinutes())}${pad(date.getSeconds())}`;
  }
}
