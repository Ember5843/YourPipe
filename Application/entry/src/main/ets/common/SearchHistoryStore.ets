import { AppLog } from './AppLog';
import { PreferencesStore } from './PreferencesStore';

const logger = AppLog.getInstance('SearchHistoryStore');

export interface SearchHistoryItem {
  query: string;
  timestamp: number;
}

export class SearchHistoryStore {
  private static readonly KEY: string = 'search_history';
  private static readonly MAX_COUNT: number = 30;

  static addSearchHistory(query: string): void {
    if (!query || query.trim().length === 0) {
      return;
    }

    const history = SearchHistoryStore.getSearchHistory();

    const filteredHistory = history.filter((item: SearchHistoryItem) => item.query !== query.trim());

    const newItem: SearchHistoryItem = {
      query: query.trim(),
      timestamp: Date.now()
    };
    filteredHistory.unshift(newItem);

    const trimmedHistory = filteredHistory.slice(0, SearchHistoryStore.MAX_COUNT);

    SearchHistoryStore.saveSearchHistory(trimmedHistory);
  }

  static getSearchHistory(): SearchHistoryItem[] {
    const json = PreferencesStore.getString(SearchHistoryStore.KEY, '[]');
    try {
      return JSON.parse(json) as SearchHistoryItem[];
    } catch (err) {
      logger.error('Failed to parse search history:', JSON.stringify(err));
      return [];
    }
  }

  static deleteSearchHistory(query: string): void {
    const history = SearchHistoryStore.getSearchHistory();
    const filteredHistory = history.filter((item: SearchHistoryItem) => item.query !== query);
    SearchHistoryStore.saveSearchHistory(filteredHistory);
  }

  static clearSearchHistory(): void {
    SearchHistoryStore.saveSearchHistory([]);
  }

  private static saveSearchHistory(history: SearchHistoryItem[]): void {
    const json = JSON.stringify(history);
    PreferencesStore.setString(SearchHistoryStore.KEY, json);
  }
}
