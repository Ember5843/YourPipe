
export class SearchQueryHandlerFactory{
  private static instance: SearchQueryHandlerFactory;

  public static readonly ALL: string = "all";
  public static readonly VIDEOS: string = "videos";
  public static readonly CHANNELS: string = "channels";
  public static readonly PLAYLISTS: string = "playlists";

  public static readonly MUSIC_SONGS: string = "music_songs";
  public static readonly MUSIC_VIDEOS: string = "music_videos";
  public static readonly MUSIC_ALBUMS: string = "music_albums";
  public static readonly MUSIC_PLAYLISTS: string = "music_playlists";
  public static readonly MUSIC_ARTISTS: string = "music_artists";

  public static readonly SEARCH_URL: string = "https://www.youtube.com/results?search_query=";
  public static readonly MUSIC_SEARCH_URL: string = "https://music.youtube.com/search?q=";


  /**
   * 获取单例实例
   */
  public static getInstance(): SearchQueryHandlerFactory {
    if (!SearchQueryHandlerFactory.instance) {
      SearchQueryHandlerFactory.instance = new SearchQueryHandlerFactory();
    }
    return SearchQueryHandlerFactory.instance;
  }

  /**
   * 生成搜索 URL
   */
  public getUrl(searchString: string, contentFilters: string[], sortFilter: string): string {
    // 获取第一个过滤器，如果数组为空则为空字符串
    const contentFilter: string = (contentFilters && contentFilters.length > 0) ? contentFilters[0] : "";

    // 使用 encodeURIComponent 进行 URL 编码
    const encodedSearchString = encodeURIComponent(searchString);

    switch (contentFilter) {
      case SearchQueryHandlerFactory.VIDEOS:
        // 注意：保留了 Java 代码中的双重编码 (%253D%253D)
        return SearchQueryHandlerFactory.SEARCH_URL + encodedSearchString + "&sp=EgIQAfABAQ%253D%253D";
      case SearchQueryHandlerFactory.CHANNELS:
        return SearchQueryHandlerFactory.SEARCH_URL + encodedSearchString + "&sp=EgIQAvABAQ%253D%253D";
      case SearchQueryHandlerFactory.PLAYLISTS:
        return SearchQueryHandlerFactory.SEARCH_URL + encodedSearchString + "&sp=EgIQA_ABAQ%253D%253D";
      case SearchQueryHandlerFactory.MUSIC_SONGS:
      case SearchQueryHandlerFactory.MUSIC_VIDEOS:
      case SearchQueryHandlerFactory.MUSIC_ALBUMS:
      case SearchQueryHandlerFactory.MUSIC_PLAYLISTS:
      case SearchQueryHandlerFactory.MUSIC_ARTISTS:
        return SearchQueryHandlerFactory.MUSIC_SEARCH_URL + encodedSearchString;
      default:
        return SearchQueryHandlerFactory.SEARCH_URL + encodedSearchString + "&sp=8AEB";
    }
  }

  /**
   * 获取可用的内容过滤器列表
   */
  public getAvailableContentFilter(): string[] {
    return [
      SearchQueryHandlerFactory.ALL,
      SearchQueryHandlerFactory.VIDEOS,
      SearchQueryHandlerFactory.CHANNELS,
      SearchQueryHandlerFactory.PLAYLISTS,
      SearchQueryHandlerFactory.MUSIC_SONGS,
      SearchQueryHandlerFactory.MUSIC_VIDEOS,
      SearchQueryHandlerFactory.MUSIC_ALBUMS,
      SearchQueryHandlerFactory.MUSIC_PLAYLISTS
      // MUSIC_ARTISTS 被注释掉了，保持原样
    ];
  }

  /**
   * 获取搜索参数后缀
   */
  public static getSearchParameter(contentFilter: string): string {
    if (!contentFilter || contentFilter.length === 0) {
      return "8AEB";
    }

    switch (contentFilter) {
      case SearchQueryHandlerFactory.VIDEOS:
        return "EgIQAfABAQ%3D%3D";
      case SearchQueryHandlerFactory.CHANNELS:
        return "EgIQAvABAQ%3D%3D";
      case SearchQueryHandlerFactory.PLAYLISTS:
        return "EgIQA_ABAQ%3D%3D";
      case SearchQueryHandlerFactory.MUSIC_SONGS:
      case SearchQueryHandlerFactory.MUSIC_VIDEOS:
      case SearchQueryHandlerFactory.MUSIC_ALBUMS:
      case SearchQueryHandlerFactory.MUSIC_PLAYLISTS:
      case SearchQueryHandlerFactory.MUSIC_ARTISTS:
        return "";
      default:
        return "8AEB";
    }
  }
}