import { AuthSessionManager, SearchInfoItem } from 'youtube_core';
import { AppLog } from '../../common/AppLog';
import { AppDataEpoch } from '../../common/AppDataEpoch';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { FeedDataSource } from '../../common/model/FeedDataSource';

const logger = AppLog.getInstance('SearchViewModel');

/** Owns request state; the page owns input, navigation and keyboard presentation. */
@Observed
export class SearchViewModel {
  @Track results: SearchInfoItem[] = [];
  @Track suggestions: string[] = [];
  @Track isSearching: boolean = false;
  @Track isSuggesting: boolean = false;
  @Track isLoadingMore: boolean = false;
  @Track hasSearched: boolean = false;
  @Track nextPageToken: string | null = null;
  @Track errorMessage: ResourceStr = '';
  @Track isResultMode: boolean = false;
  @Track feedSource: FeedDataSource = new FeedDataSource();
  private active: boolean = false;
  private generation: number = 0;
  private suggestionGeneration: number = 0;
  private suggestionTimer: number = -1;
  private filters: string[] = [];

  activate(): void { this.active = true; }

  deactivate(): void {
    this.active = false;
    this.generation++;
    this.clearSuggestions();
    this.isSearching = false;
    this.isLoadingMore = false;
  }

  private setResults(items: SearchInfoItem[]): void {
    this.results = items;
    this.feedSource.setData(items, (item: Object): string => (item as SearchInfoItem).id.toString());
  }

  private accountContext(): string {
    return AuthSessionManager.getInstance()?.getUserDataContextKey() ?? 'guest';
  }

  async search(query: string, filters: string[], reset: boolean): Promise<void> {
    const keyword = query.trim();
    if (reset || !keyword) {
      this.generation++;
      this.clearSuggestions();
    }
    const generation = this.generation;
    if (!keyword) {
      this.setResults([]);
      this.nextPageToken = null;
      this.hasSearched = false;
      this.isResultMode = false;
      this.isSearching = false;
      this.isLoadingMore = false;
      this.errorMessage = '';
      return;
    }
    if (reset) {
      this.filters = filters.slice();
      this.isResultMode = true;
      this.isSearching = true;
      this.isLoadingMore = false;
      this.setResults([]);
      this.nextPageToken = null;
      this.hasSearched = true;
    } else {
      if (this.isSearching || this.isLoadingMore || !this.nextPageToken) return;
      this.isLoadingMore = true;
    }
    this.errorMessage = '';
    const token = this.nextPageToken ?? '';
    const epoch = AppDataEpoch.capture();
    const account = this.accountContext();
    const ownsRequest = (): boolean => this.active && generation === this.generation;
    const canCommit = (): boolean => ownsRequest() && AppDataEpoch.isCurrent(epoch) && account === this.accountContext();
    try {
      const service = FeedServiceProvider.getInstance().getSearchService();
      service.setFilters(this.filters.slice());
      const startId = reset ? 1 : this.results.length + 1;
      const page = reset ? await service.searchInitial(keyword, startId) : await service.searchNext(token, startId);
      if (!canCommit()) return;
      this.setResults(reset ? page.items : this.results.concat(page.items));
      this.nextPageToken = page.nextPageToken;
    } catch (e) {
      if (!canCommit()) return;
      logger.error(`search failed generation=${generation}: ${(e as Error).message}`);
      this.errorMessage = $r('app.string.yt_error_search_failed');
    } finally {
      if (ownsRequest()) {
        this.isSearching = false;
        this.isLoadingMore = false;
      }
    }
  }

  clearSuggestions(): void {
    this.suggestionGeneration++;
    if (this.suggestionTimer >= 0) clearTimeout(this.suggestionTimer);
    this.suggestionTimer = -1;
    this.suggestions = [];
    this.isSuggesting = false;
  }

  scheduleSuggestions(query: string): void {
    this.clearSuggestions();
    const keyword = query.trim();
    if (!keyword || !this.active) return;
    const generation = this.suggestionGeneration;
    this.isSuggesting = true;
    this.suggestionTimer = setTimeout(() => {
      this.suggestionTimer = -1;
      this.fetchSuggestions(keyword, generation);
    }, 280);
  }

  private async fetchSuggestions(keyword: string, generation: number): Promise<void> {
    try {
      const service = FeedServiceProvider.getInstance().getSearchSuggestionService();
      const suggestions = await service.fetchSuggestions(keyword);
      if (!this.active || generation !== this.suggestionGeneration) return;
      this.suggestions = suggestions.slice(0, 12);
    } catch (e) {
      if (!this.active || generation !== this.suggestionGeneration) return;
      logger.warn(`suggestions failed generation=${generation}: ${(e as Error).message}`);
      this.suggestions = [];
    } finally {
      if (this.active && generation === this.suggestionGeneration) this.isSuggesting = false;
    }
  }
}
