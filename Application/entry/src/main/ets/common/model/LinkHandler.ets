import { Utils } from "../common/Utils";

export class LinkHandler {
  protected readonly originalUrl: string;
  protected readonly url: string;
  protected readonly id: string;

  // ArkTS/TS 不支持像 Java 那样的多构造函数重载。
  // 我们可以使用联合类型或者可选参数，但针对拷贝构造函数模式，
  // 更推荐的做法是让调用者明确传递参数，或者在内部判断参数类型。
  // 这里提供一种兼容两种调用的方式：
  constructor(originalUrlOrHandler: string | LinkHandler, url?: string, id?: string) {
    if (originalUrlOrHandler instanceof LinkHandler) {
      // 对应 Java 的: public LinkHandler(final LinkHandler handler)
      this.originalUrl = originalUrlOrHandler.originalUrl;
      this.url = originalUrlOrHandler.url;
      this.id = originalUrlOrHandler.id;
    } else {
      // 对应 Java 的: public LinkHandler(final String originalUrl, final String url, final String id)
      // 这里需要断言 url 和 id 存在，或者在方法签名里处理
      this.originalUrl = originalUrlOrHandler;
      this.url = url || ''; // 提供默认值防止 undefined
      this.id = id || '';
    }
  }

  public getOriginalUrl(): string {
    return this.originalUrl;
  }

  public getUrl(): string {
    return this.url;
  }

  public getId(): string {
    return this.id;
  }

  // 对应 Java 的 throws ParsingException
  // TS 中不需要显式声明 throws，但逻辑保持一致
  public getBaseUrl(): string {
    return Utils.getBaseUrl(this.url);
  }
}