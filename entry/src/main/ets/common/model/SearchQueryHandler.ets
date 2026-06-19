import { ListLinkHandler } from './ListLinkHandler';

export class SearchQueryHandler extends ListLinkHandler {

  /**
   * 构造函数 - 对应 Java 的两个重载构造函数
   *
   * 1. 主构造函数: (originalUrl, url, searchString, contentFilters, sortFilter)
   * 2. 拷贝构造函数: (handler: ListLinkHandler)
   */
  constructor(
    arg1: string | ListLinkHandler,
    url?: string,
    searchString?: string,
    contentFilters?: string[],
    sortFilter?: string
  ) {
    // 情况 1: 传入的是 ListLinkHandler 实例 (拷贝构造)
    // 对应 Java: public SearchQueryHandler(final ListLinkHandler handler)
    if (arg1 instanceof ListLinkHandler) {
      // Java 中调用了 this(...)，最终也是调用 super。
      // 这里我们直接提取 handler 的属性传给父类构造函数。
      super(
        arg1.getOriginalUrl(),
        arg1.getUrl(),
        arg1.getId(), // 这里 handler.id 就是 searchString
        arg1.getContentFilters(),
        arg1.getSortFilter()
      );
    }
    // 情况 2: 传入的是详细参数
    // 对应 Java: public SearchQueryHandler(originalUrl, url, searchString, contentFilters, sortFilter)
    else {
      // 注意参数顺序的映射：
      // Java: super(originalUrl, url, searchString, contentFilters, sortFilter);
      // 父类 ListLinkHandler 的第三个参数是 'id'，这里我们将 'searchString' 传进去。
      super(
        arg1, // originalUrl
        url,
        searchString, // 映射到父类的 id
        contentFilters,
        sortFilter
      );
    }
  }

  /**
   * Returns the search string. Since ListQIHandler is based on ListLinkHandler
   * getSearchString() is equivalent to calling getId().
   *
   * @return the search string
   */
  public getSearchString(): string {
    return this.getId();
  }
}