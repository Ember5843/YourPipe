import { SearchContentFilter } from "../model/SearchContentFilter";

export class YoutubeSearchQueryHandlerFactory {
  private static readonly INSTANCE: YoutubeSearchQueryHandlerFactory = new YoutubeSearchQueryHandlerFactory();

  static readonly ALL = SearchContentFilter.ALL;
  static readonly VIDEOS = SearchContentFilter.VIDEOS;
  static readonly CHANNELS = SearchContentFilter.CHANNELS;
  static readonly PLAYLISTS = SearchContentFilter.PLAYLISTS;

  static readonly MUSIC_SONGS = SearchContentFilter.MUSIC_SONGS;
  static readonly MUSIC_VIDEOS = SearchContentFilter.MUSIC_VIDEOS;
  static readonly MUSIC_ALBUMS = SearchContentFilter.MUSIC_ALBUMS;
  static readonly MUSIC_PLAYLISTS = SearchContentFilter.MUSIC_PLAYLISTS;
  static readonly MUSIC_ARTISTS = SearchContentFilter.MUSIC_ARTISTS;

  static readonly SEARCH_URL: string = "https://www.youtube.com/results?search_query=";
  static readonly MUSIC_SEARCH_URL: string = "https://music.youtube.com/search?q=";

  private constructor() {
  }

  static getInstance(): YoutubeSearchQueryHandlerFactory {
    return YoutubeSearchQueryHandlerFactory.INSTANCE;
  }

  getUrl(searchString: string, contentFilters: string[], sortFilter: string): string {
    const contentFilter = contentFilters.length > 0 ? contentFilters[0] : "";

    switch (contentFilter) {
      case YoutubeSearchQueryHandlerFactory.VIDEOS:
        return YoutubeSearchQueryHandlerFactory.SEARCH_URL +
        encodeURIComponent(searchString) + "&sp=EgIQAfABAQ%253D%253D";
      case YoutubeSearchQueryHandlerFactory.CHANNELS:
        return YoutubeSearchQueryHandlerFactory.SEARCH_URL +
        encodeURIComponent(searchString) + "&sp=EgIQAvABAQ%253D%253D";
      case YoutubeSearchQueryHandlerFactory.PLAYLISTS:
        return YoutubeSearchQueryHandlerFactory.SEARCH_URL +
        encodeURIComponent(searchString) + "&sp=EgIQA_ABAQ%253D%253D";
      case YoutubeSearchQueryHandlerFactory.MUSIC_SONGS:
      case YoutubeSearchQueryHandlerFactory.MUSIC_VIDEOS:
      case YoutubeSearchQueryHandlerFactory.MUSIC_ALBUMS:
      case YoutubeSearchQueryHandlerFactory.MUSIC_PLAYLISTS:
      case YoutubeSearchQueryHandlerFactory.MUSIC_ARTISTS:
        return YoutubeSearchQueryHandlerFactory.MUSIC_SEARCH_URL + encodeURIComponent(searchString);
      default:
        return YoutubeSearchQueryHandlerFactory.SEARCH_URL +
        encodeURIComponent(searchString) + "&sp=8AEB";
    }
  }

  getAvailableContentFilter(): string[] {
    return [
      YoutubeSearchQueryHandlerFactory.ALL,
      YoutubeSearchQueryHandlerFactory.VIDEOS,
      YoutubeSearchQueryHandlerFactory.CHANNELS,
      YoutubeSearchQueryHandlerFactory.PLAYLISTS,
      YoutubeSearchQueryHandlerFactory.MUSIC_SONGS,
      YoutubeSearchQueryHandlerFactory.MUSIC_VIDEOS,
      YoutubeSearchQueryHandlerFactory.MUSIC_ALBUMS,
      YoutubeSearchQueryHandlerFactory.MUSIC_PLAYLISTS
      // MUSIC_ARTISTS 可按需启用
    ];
  }

  static getSearchParameter(contentFilter: string | null): string {
    if (!contentFilter || contentFilter.length === 0) {
      return "8AEB";
    }

    switch (contentFilter) {
      case YoutubeSearchQueryHandlerFactory.VIDEOS:
        return "EgIQAfABAQ%3D%3D";
      case YoutubeSearchQueryHandlerFactory.CHANNELS:
        return "EgIQAvABAQ%3D%3D";
      case YoutubeSearchQueryHandlerFactory.PLAYLISTS:
        return "EgIQA_ABAQ%3D%3D";
      case YoutubeSearchQueryHandlerFactory.MUSIC_SONGS:
      case YoutubeSearchQueryHandlerFactory.MUSIC_VIDEOS:
      case YoutubeSearchQueryHandlerFactory.MUSIC_ALBUMS:
      case YoutubeSearchQueryHandlerFactory.MUSIC_PLAYLISTS:
      case YoutubeSearchQueryHandlerFactory.MUSIC_ARTISTS:
        return "";
      default:
        return "8AEB";
    }
  }
}
