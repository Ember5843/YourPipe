import { url } from '@kit.ArkTS';

// 定义一个简单的异常类，对应 Java 的 ParsingException
export class ParsingException extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ParsingException";
  }
}

export class Utils {
  public static readonly HTTP: string = "http://";
  public static readonly HTTPS: string = "https://";

  // 在 JS/TS 中，正则通常不需要预编译为 Pattern 对象，直接定义即可
  private static readonly M_PATTERN: RegExp = /^(https?)?:\/\/m\./i;
  private static readonly WWW_PATTERN: RegExp = /^(https?)?:\/\/www\./i;

  private constructor() {
    // 禁止实例化
  }

  /**
   * Encodes a string to url.URL format using UTF-8.
   */
  public static encodeUrlUtf8(str: string): string {
    return encodeURIComponent(str);
  }

  /**
   * Decodes a url.URL using UTF-8.
   */
  public static decodeUrlUtf8(url: string): string {
    return decodeURIComponent(url);
  }

  /**
   * Remove all non-digit characters from a string.
   */
  public static removeNonDigitCharacters(toRemove: string): string {
    return toRemove.replace(/\D+/g, "");
  }

  /**
   * Check if the url matches the pattern.
   */
  public static checkUrl(pattern: string, url: string): void {
    if (Utils.isNullOrEmpty(url)) {
      throw new Error("Url can't be null or empty");
    }

    // 将字符串模式转换为正则，忽略大小写
    const regex = new RegExp(pattern, 'i');
    if (!regex.test(url)) {
      throw new ParsingException("Url don't match the pattern");
    }
  }

  public static replaceHttpWithHttps(url: string | null): string | null {
    if (url === null) {
      return null;
    }

    if (url.startsWith(Utils.HTTP)) {
      return Utils.HTTPS + url.substring(Utils.HTTP.length);
    }
    return url;
  }

  /**
   * Get the value of a url.URL-query by name.
   * 注意：这里参数 url 接收的是 url.URL 对象
   */
  public static getQueryValue(urlObj: url.URL, parameterName: string): string | null {
    // url.URL 对象自带 searchParams
    // 使用 new url.URLParams 来处理，以避免直接调用可能被标记为废弃的属性（视SDK版本而定）
    // 但在标准 ArkTS 中，urlObj.searchParams.get() 依然是最常用的方式
    const params = new url.URLParams(urlObj.search);
    return params.get(parameterName);
  }

  /**
   * Convert a string to a url.URL object.
   */
  public static stringToURL(urlStr: string): url.URL {
    try {
      return new url.URL(urlStr);
    } catch (e) {
      // 如果没有协议，尝试添加 https://
      // JS 的 url.URL 构造函数通常会抛出 TypeError 而不是 Malformedurl.URLException
      if (urlStr && !urlStr.match(/^[a-zA-Z]+:\/\//)) {
        try {
          return new url.URL(Utils.HTTPS + urlStr);
        } catch (ignored) {
          // 忽略内部错误，继续向下抛出主异常
        }
      }
      // 必须抛出 Error 对象，不能直接 throw e (如果 e 是 unknown)
      throw new ParsingException("Invalid URL: " + urlStr);
    }
  }

  public static isHTTP(url: url.URL): boolean {
    // JS url.URL protocol 包含冒号，例如 "http:"
    const protocol = url.protocol;
    if (protocol !== "http:" && protocol !== "https:") {
      return false;
    }
    // JS url.URL port 为空字符串表示使用默认端口
    return url.port === "" || url.port === "80" || url.port === "443";
  }

  public static removeMAndWWWFromUrl(url: string): string {
    let result = url;
    if (Utils.M_PATTERN.test(result)) {
      result = result.replace("m.", "");
    }
    if (Utils.WWW_PATTERN.test(result)) {
      result = result.replace("www.", "");
    }
    return result;
  }

  public static removeUTF8BOM(s: string): string {
    let result = s;
    if (result.startsWith("\uFEFF")) {
      result = result.substring(1);
    }
    if (result.endsWith("\uFEFF")) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  public static getBaseUrl(urlStr: string): string {
    try {
      const uri = Utils.stringToURL(urlStr);
      return uri.protocol + "//" + uri.host;
    } catch (e) {
      // ArkTS 要求 catch 块中的变量如果是 unknown，不能直接拼接字符串
      let msg = "Malformed url: " + urlStr;
      if (e instanceof Error) {
        msg += " (" + e.message + ")";
      }
      throw new ParsingException(msg);
    }
  }

  /**
   * 处理 Google 重定向链接
   */
  public static followGoogleRedirectIfNeeded(urlStr: string): string {
    try {
      const decoded = Utils.stringToURL(urlStr);
      if (decoded.hostname.includes("google") && decoded.pathname === "/url") {
        const params = new url.URLParams(decoded.search);
        const targetUrl = params.get("url");
        if (targetUrl) {
          return targetUrl;
        }
      }
    } catch (ignored) {
    }
    return urlStr;
  }

  // --- 判空工具 ---

  public static isNullOrEmpty(str: string | null | undefined): boolean {
    return !str || str.length === 0;
  }

  // 修复：将 any[] 改为 Object[]
  public static isCollectionNullOrEmpty(collection: Object[] | null | undefined): boolean {
    return !collection || collection.length === 0;
  }

  // 修复：将 Map<any, any> 改为 Map<Object, Object>，并明确类型
  public static isMapNullOrEmpty(map: Map<Object, Object> | Object | null | undefined): boolean {
    if (!map) return true;
    if (map instanceof Map) {
      return map.size === 0;
    }
    return Object.keys(map).length === 0;
  }

  public static isBlank(str: string | null | undefined): boolean {
    // 检查是否为 null, undefined, 空字符串或仅包含空白字符
    return !str || /^\s*$/.test(str);
  }

  // --- Join 工具 ---

  public static join(delimiter: string, mapJoin: string, elements: Map<string, string> | Record<string, string>): string {
    let entries: [string, string][];

    if (elements instanceof Map) {
      // Map 转 Array
      entries = [];
      elements.forEach((value, key) => {
        entries.push([key, value]);
      });
    } else {
      entries = Object.entries(elements);
    }

    return entries
    // 修复：ArkTS 不支持参数解构 ([key, value])，必须使用常规参数
      .map((entry: [string, string]) => {
        const key = entry[0];
        const value = entry[1];
        return key + mapJoin + value;
      })
      .join(delimiter);
  }

  public static nonEmptyAndNullJoin(delimiter: string, ...elements: (string | null | undefined)[]): string {
    return elements
      .filter(s => !Utils.isNullOrEmpty(s) && s !== "null")
      // 此时 s 可能是 string | null | undefined，但在 filter 后逻辑上是 string
      // 强制转换为 string 以满足 join 要求
      .map(s => s as string)
      .join(delimiter);
  }

  // --- 正则工具 ---

  /**
   * 在输入字符串中查找正则数组匹配的结果 (默认 Group 0)
   */
  public static getStringResultFromRegexArray(input: string, regexes: (string | RegExp)[], group: number = 0): string {
    for (const regexItem of regexes) {
      try {
        let regex: RegExp;
        if (typeof regexItem === 'string') {
          regex = new RegExp(regexItem);
        } else {
          regex = regexItem;
        }

        const match = regex.exec(input);
        if (match && match[group] !== undefined) {
          return match[group];
        }
      } catch (ignored) {
        // 忽略单个正则错误
      }
    }
    throw new ParsingException("No regex matched the input on group " + group);
  }
}