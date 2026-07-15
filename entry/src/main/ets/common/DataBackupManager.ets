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
const APP_VERSION: string = '0.5.3';

export type BackupErrorCode =
  | 'no_context'
  | 'no_save_path'
  | 'no_file'
  | 'format_error'
  | 'wrong_app'
  | 'version_unsupported'
  | 'empty'
  | 'export_failed'
  | 'restore_failed';

export class BackupError extends Error {
  code: BackupErrorCode;
  resourceKey: string;
  constructor(code: BackupErrorCode, message: string, resourceKey: string) {
    super(message);
    this.name = 'BackupError';
    this.code = code;
    this.resourceKey = resourceKey;
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
      throw new BackupError('no_context', 'Unable to get app context', 'yt_backup_error_no_context');
    }

    const filePicker = new picker.DocumentViewPicker(context);
    const options = new picker.DocumentSaveOptions();
    const dateStr = DataBackupManager.formatDate(new Date(backup.exportedAt));
    options.newFileNames = [`yourpipe_backup_${dateStr}.json`];
    options.pickerMode = picker.DocumentPickerMode.DOWNLOAD;

    const result = await filePicker.save(options);
    if (!result || result.length === 0) {
      throw new BackupError('no_save_path', 'No save path selected', 'yt_backup_error_no_save_path');
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
      throw new BackupError('no_context', 'Unable to get app context', 'yt_backup_error_no_context');
    }

    const filePicker = new picker.DocumentViewPicker(context);
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['.json'];

    const result = await filePicker.select(options);
    if (!result || result.length === 0) {
      throw new BackupError('no_file', 'No file selected', 'yt_backup_error_no_file');
    }

    const path = new fileUri.FileUri(result[0]).path;
    const content = fs.readTextSync(path);

    let backup: AppBackupData;
    try {
      backup = JSON.parse(content) as AppBackupData;
    } catch (e) {
      throw new BackupError('format_error', 'Backup file format error', 'yt_backup_error_format');
    }

    if (backup.appId !== BACKUP_APP_ID) {
      throw new BackupError('wrong_app', 'Backup file does not belong to this app', 'yt_backup_error_wrong_app');
    }
    if (backup.backupVersion !== BACKUP_VERSION) {
      throw new BackupError('version_unsupported', 'Backup file version not supported', 'yt_backup_error_version');
    }
    if (!backup.items) {
      throw new BackupError('empty', 'Backup file is empty', 'yt_backup_error_empty');
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
