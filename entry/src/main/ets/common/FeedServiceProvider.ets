import { HomeFeedService } from '../features/home/HomeFeedService';
import { SearchService } from '../features/home/SearchService';
import { PlaylistService } from '../features/home/PlaylistService';
import { ChannelService } from '../features/home/ChannelService';
import { SearchSuggestionService } from '../features/home/SearchSuggestionService';
import { SearchLocaleManager } from './SearchLocaleManager';

export class FeedServiceProvider {
  private static instance: FeedServiceProvider;
  private homeFeedService: HomeFeedService | null = null;
  private searchService: SearchService | null = null;
  private playlistService: PlaylistService | null = null;
  private channelService: ChannelService | null = null;
  private searchSuggestionService: SearchSuggestionService | null = null;
  private lastLanguage: string = '';
  private lastCountry: string = '';

  static getInstance(): FeedServiceProvider {
    if (!FeedServiceProvider.instance) {
      FeedServiceProvider.instance = new FeedServiceProvider();
    }
    return FeedServiceProvider.instance;
  }

  private ensureServices(): void {
    const locale = SearchLocaleManager.getSearchLocaleBundle();
    const lang = locale.localization.getLanguageCode();
    const country = locale.contentCountry.getCountryCode();
    if (!this.homeFeedService || this.lastLanguage !== lang || this.lastCountry !== country) {
      this.homeFeedService = new HomeFeedService(locale.localization, locale.contentCountry);
      this.searchService = new SearchService(locale.localization, locale.contentCountry);
      this.playlistService = new PlaylistService(locale.localization, locale.contentCountry);
      this.channelService = new ChannelService(locale.localization, locale.contentCountry);
      this.searchSuggestionService = new SearchSuggestionService(locale.localization, locale.contentCountry);
      this.lastLanguage = lang;
      this.lastCountry = country;
    }
  }

  getHomeFeedService(): HomeFeedService {
    this.ensureServices();
    return this.homeFeedService!;
  }

  getSearchService(): SearchService {
    this.ensureServices();
    return this.searchService!;
  }

  getPlaylistService(): PlaylistService {
    this.ensureServices();
    return this.playlistService!;
  }

  getChannelService(): ChannelService {
    this.ensureServices();
    return this.channelService!;
  }

  getSearchSuggestionService(): SearchSuggestionService {
    this.ensureServices();
    return this.searchSuggestionService!;
  }

  invalidate(): void {
    this.homeFeedService = null;
    this.searchService = null;
    this.playlistService = null;
    this.channelService = null;
    this.searchSuggestionService = null;
  }
}
