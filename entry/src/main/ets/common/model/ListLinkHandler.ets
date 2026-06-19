import { LinkHandler } from './LinkHandler'; // 确保引入父类

export class ListLinkHandler extends LinkHandler {
  protected readonly contentFilters: string[];
  protected readonly sortFilter: string;

  /**
   * 构造函数 - 对应 Java 的三个重载构造函数
   *
   * 1. 主构造函数: (originalUrl, url, id, contentFilters, sortFilter)
   * 2. 拷贝构造函数 (ListLinkHandler): (handler)
   * 3. 父类转换构造函数 (LinkHandler): (handler)
   */
  constructor(
    arg1: string | ListLinkHandler | LinkHandler,
    url?: string,
    id?: string,
    contentFilters?: string[],
    sortFilter?: string
  ) {
    // 情况 1: 传入的是 ListLinkHandler 实例 (拷贝构造)
    if (arg1 instanceof ListLinkHandler) {
      super(arg1.getOriginalUrl(), arg1.getUrl(), arg1.getId());
      // 模拟 Collections.unmodifiableList，这里使用浅拷贝防止外部修改
      this.contentFilters = [...arg1.contentFilters];
      this.sortFilter = arg1.sortFilter;
    }
    // 情况 2: 传入的是 LinkHandler 实例 (父类转子类)
    // 注意：因为 ListLinkHandler 也是 LinkHandler，所以这个判断必须放在 instanceof ListLinkHandler 之后
    else if (arg1 instanceof LinkHandler) {
      super(arg1.getOriginalUrl(), arg1.getUrl(), arg1.getId());
      this.contentFilters = []; // Collections.emptyList()
      this.sortFilter = "";
    }
    // 情况 3: 传入的是普通参数 (originalUrl, url, id, ...)
    else {
      // 这里的 arg1 是 string 类型
      super(arg1, url || '', id || '');
      // 确保 contentFilters 不为 undefined，并进行拷贝
      this.contentFilters = contentFilters ? [...contentFilters] : [];
      this.sortFilter = sortFilter || "";
    }
  }

  public getContentFilters(): string[] {
    return this.contentFilters;
  }

  public getSortFilter(): string {
    return this.sortFilter;
  }
}