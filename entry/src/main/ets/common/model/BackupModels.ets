export type BackupItemKey =
  | 'settings'
  | 'subscriptions'
  | 'subscriptionFeed'
  | 'favorites'
  | 'playlists'
  | 'localQueues'
  | 'watchHistory'
  | 'searchHistory'
  | 'auth';

export const ALL_BACKUP_ITEM_KEYS: BackupItemKey[] = [
  'settings',
  'subscriptions',
  'subscriptionFeed',
  'favorites',
  'playlists',
  'localQueues',
  'watchHistory',
  'searchHistory',
  'auth'
];

export interface BackupItems {
  settings: Object | undefined;
  subscriptions: Object | undefined;
  subscriptionFeed: Object | undefined;
  favorites: Object | undefined;
  playlists: Object | undefined;
  localQueues: Object | undefined;
  watchHistory: Object | undefined;
  searchHistory: Object | undefined;
  auth: Object | undefined;
}

export interface AppBackupData {
  appId: string;
  appVersion: string;
  backupVersion: number;
  exportedAt: number;
  items: BackupItems;
}

export interface BackupManifest {
  appId: string;
  appVersion: string;
  backupVersion: number;
  exportedAt: number;
  availableItems: BackupItemKey[];
}
