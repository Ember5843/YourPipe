import { YTCoreLogger } from '../common/YTCoreLogger';
import { preferences } from '@kit.ArkData';
import { url } from '@kit.ArkTS';

const logger = YTCoreLogger.getInstance('CookieJar');

/**
 * 用于持久化的 Cookie 数据类
 */
export class CookieData {
  name: string;
  value: string;
  domain: string;
  path: string;
  expires?: number;
  secure: boolean;
  httpOnly: boolean;
  sameSite?: string;
  hostOnly: boolean;

  constructor(
    name: string,
    value: string,
    domain: string = '',
    path: string = '/',
    expires?: number,
    secure: boolean = false,
    httpOnly: boolean = false,
    sameSite?: string,
    hostOnly: boolean = false
  ) {
    this.name = name;
    this.value = value;
    this.domain = domain;
    this.path = path;
    this.expires = expires;
    this.secure = secure;
    this.httpOnly = httpOnly;
    this.sameSite = sameSite;
    this.hostOnly = hostOnly;
  }
}

/**
 * Cookie 数据结构
 */
export class Cookie {
  name: string;
  value: string;
  domain: string;
  path: string;
  expires?: number; // 过期时间戳（毫秒）
  secure: boolean;
  httpOnly: boolean;
  sameSite?: string;
  /** 无 Domain 属性设置的 cookie（RFC 6265 host-only）：仅精确主机匹配，不下发子域 */
  hostOnly: boolean;

  constructor(
    name: string,
    value: string,
    domain: string = '',
    path: string = '/',
    expires?: number,
    secure: boolean = false,
    httpOnly: boolean = false,
    sameSite?: string,
    hostOnly: boolean = false
  ) {
    this.name = name;
    this.value = value;
    this.domain = domain;
    this.path = path;
    this.expires = expires;
    this.secure = secure;
    this.httpOnly = httpOnly;
    this.sameSite = sameSite;
    this.hostOnly = hostOnly;
  }

  /**
   * 检查 Cookie 是否过期
   */
  isExpired(): boolean {
    if (!this.expires) {
      return false; // 会话 Cookie，不过期
    }
    return Date.now() > this.expires;
  }

  /**
   * 检查 Cookie 是否匹配指定 URL
   */
  matches(targetUrl: string): boolean {
    try {
      const urlObj = new url.URL(targetUrl);
      
      // 检查 Domain
      if (this.domain) {
        const host = urlObj.hostname.toLowerCase();
        const domain = this.domain.toLowerCase();
        if (this.hostOnly) {
          // host-only cookie（设置时无 Domain 属性）：RFC 6265 要求精确主机匹配
          if (host !== domain) {
            return false;
          }
        } else if (domain.startsWith('.')) {
          // 点前缀域：host 必须等于裸域或是其子域，防止后缀撞名（如 notyoutube.com 命中 .youtube.com）
          const bareDomain = domain.substring(1);
          if (host !== bareDomain && !host.endsWith('.' + bareDomain)) {
            return false;
          }
        } else if (host !== domain && !host.endsWith('.' + domain)) {
          return false;
        }
      }

      // 检查 Path
      if (this.path) {
        const pathname = urlObj.pathname || '/';
        if (!pathname.startsWith(this.path)) {
          return false;
        }
      }

      // 检查 Secure（如果是 https，总是允许；如果是 http，要求 cookie 不是 secure）
      if (this.secure && urlObj.protocol !== 'https:') {
        return false;
      }

      return true;
    } catch (e) {
      return false;
    }
  }

  /**
   * 转换为 Cookie 字符串（name=value 格式）
   */
  toString(): string {
    return `${this.name}=${this.value}`;
  }
}

/** Cookie 持久化 preferences 存储名（"清除所有数据"需要按此名擦除，entry 侧经 Index 导出引用）。 */
export const YOUTUBE_COOKIE_STORAGE_NAME = 'youtube_cookies';

/**
 * RFC 6265 风格切分逗号拼接的 Set-Cookie 头值：netstack 可能把多个 Set-Cookie
 * 头合并成一个逗号分隔字符串。只在逗号后（跳过空白）出现的 token 在 ';' 之前
 * 含 '=' 时视为新 cookie 起点——expires 的 HTTP-date（"Wed, 21 Oct 2015 ..."）
 * 里的逗号不满足该条件，不会误切。AuthSessionManager.mergeAccountSetCookies 共用。
 */
export function splitSetCookieHeader(headerValue: string): string[] {
  const out: string[] = [];
  let start = 0;
  for (let i = 0; i < headerValue.length; i++) {
    if (headerValue.charAt(i) !== ',') {
      continue;
    }
    let j = i + 1;
    while (j < headerValue.length && (headerValue.charAt(j) === ' ' || headerValue.charAt(j) === '\t')) {
      j++;
    }
    let isNewCookie = false;
    for (let k = j; k < headerValue.length; k++) {
      const c = headerValue.charAt(k);
      if (c === ';' || c === ',') {
        break;
      }
      if (c === '=') {
        isNewCookie = true;
        break;
      }
    }
    if (isNewCookie) {
      out.push(headerValue.substring(start, i).trim());
      start = i + 1;
    }
  }
  const tail = headerValue.substring(start).trim();
  if (tail.length > 0) {
    out.push(tail);
  }
  return out;
}

/**
 * CookieJar - 管理 HTTP Cookie 的存储和检索
 */
export class CookieJar {
  private cookies: Map<string, Cookie> = new Map();
  private storageName: string = YOUTUBE_COOKIE_STORAGE_NAME;
  private context: Context;

  constructor(context: Context) {
    this.context = context;
  }

  /**
   * 从 Set-Cookie 响应头解析并存储 Cookie
   * @param setCookieHeader Set-Cookie 头值（可能包含多个，用逗号分隔）
   * @param url 请求 URL（用于提取默认 domain 和 path）
   */
  parseSetCookie(setCookieHeader: string | string[], requestUrl: string): void {
    if (!setCookieHeader) {
      return;
    }

    // 处理数组或字符串
    const headerValues = Array.isArray(setCookieHeader) ? setCookieHeader : [setCookieHeader];

    for (const headerValue of headerValues) {
      // netstack 可能把多个 Set-Cookie 逗号拼接成一个字符串，先切分再逐条解析
      const cookieStrings = splitSetCookieHeader(headerValue);
      for (const cookieString of cookieStrings) {
      // 按 ";" 分割属性
      const parts = cookieString.split(';');
      if (parts.length === 0) continue;

      // 第一部分是 name=value
      const nameValue = parts[0].trim();
      const equalIndex = nameValue.indexOf('=');
      if (equalIndex === -1) continue;

      const name = nameValue.substring(0, equalIndex).trim();
      const value = nameValue.substring(equalIndex + 1).trim();

      // 解析其他属性
      let domain = '';
      let path = '/';
      let expires: number | undefined;
      let secure = false;
      let httpOnly = false;
      let sameSite: string | undefined;

      for (let i = 1; i < parts.length; i++) {
        const part = parts[i].trim();
        const splitResult = part.split('=');
        const attrName = splitResult[0].trim();
        const attrValue = splitResult.length > 1 ? splitResult[1].trim() : '';
        const lowerAttrName = attrName.toLowerCase();

        switch (lowerAttrName) {
          case 'domain':
            domain = attrValue || '';
            break;
          case 'path':
            path = attrValue || '/';
            break;
          case 'expires':
            if (attrValue) {
              // 解析 HTTP-date 格式
              const date = new Date(attrValue);
              if (!isNaN(date.getTime())) {
                expires = date.getTime();
              }
            }
            break;
          case 'max-age':
            if (attrValue) {
              const maxAge = parseInt(attrValue, 10);
              if (!isNaN(maxAge)) {
                expires = Date.now() + maxAge * 1000;
              }
            }
            break;
          case 'secure':
            secure = true;
            break;
          case 'httponly':
            httpOnly = true;
            break;
          case 'samesite':
            sameSite = attrValue || 'Lax';
            break;
        }
      }

      // 如果没有指定 domain，从 URL 提取，并标记为 host-only（RFC 6265：不下发子域）
      let hostOnly = false;
      if (!domain) {
        hostOnly = true;
        try {
          const urlObj = new url.URL(requestUrl);
          domain = urlObj.hostname;
        } catch (e) {
          domain = '';
        }
      }

      // 创建 Cookie 对象并存储
      const cookie = new Cookie(name, value, domain, path, expires, secure, httpOnly, sameSite, hostOnly);
      const key = `${name}:${domain}:${path}`;
      this.cookies.set(key, cookie);

      logger.debug(`Stored cookie: ${name}, domain=${domain}, path=${path}`);
      }
    }
  }

  /**
   * 获取匹配指定 URL 的 Cookie 字符串
   * @param targetUrl 目标 URL
   * @returns Cookie 头字符串，如 "name1=value1; name2=value2"
   */
  getCookieHeader(targetUrl: string): string {
    const matchingCookies: Cookie[] = [];

    for (const cookie of this.cookies.values()) {
      if (!cookie.isExpired() && cookie.matches(targetUrl)) {
        matchingCookies.push(cookie);
      }
    }

    // 按路径长度排序（更具体的路径优先）
    matchingCookies.sort((a, b) => b.path.length - a.path.length);

    return matchingCookies.map(c => c.toString()).join('; ');
  }

  /**
   * 获取特定名称的 Cookie 值
   */
  getCookie(name: string): Cookie | undefined {
    for (const cookie of this.cookies.values()) {
      if (cookie.name === name && !cookie.isExpired()) {
        return cookie;
      }
    }
    return undefined;
  }

  /**
   * 设置 Cookie（手动添加）
   */
  setCookie(cookie: Cookie): void {
    const key = `${cookie.name}:${cookie.domain}:${cookie.path}`;
    this.cookies.set(key, cookie);
  }

  /**
   * 删除 Cookie
   */
  deleteCookie(name: string, domain?: string, path?: string): void {
    if (domain && path) {
      const key = `${name}:${domain}:${path}`;
      this.cookies.delete(key);
    } else {
      // 删除所有同名 Cookie
      const keysToDelete: string[] = [];
      this.cookies.forEach((cookie, key) => {
        if (cookie.name === name) {
          keysToDelete.push(key);
        }
      });
      keysToDelete.forEach(key => this.cookies.delete(key));
    }
  }

  /**
   * 清空所有 Cookie
   */
  clearAll(): void {
    this.cookies.clear();
    logger.debug('All cookies cleared');
  }

  /**
   * 获取所有 Cookie 数量
   */
  getCookieCount(): number {
    return this.cookies.size;
  }

  /**
   * 保存到持久化存储（Local Storage）
   */
  async save(): Promise<void> {
    try {
      const storage = preferences.getPreferencesSync(this.context, { name: this.storageName });

      // 转换为可序列化的数组
      const cookieArray: CookieData[] = [];
      for (const cookie of this.cookies.values()) {
        if (!cookie.isExpired()) {
          cookieArray.push(new CookieData(
            cookie.name,
            cookie.value,
            cookie.domain,
            cookie.path,
            cookie.expires,
            cookie.secure,
            cookie.httpOnly,
            cookie.sameSite,
            cookie.hostOnly
          ));
        }
      }

      storage.putSync('cookies', JSON.stringify(cookieArray));
      await storage.flush();
      logger.debug(`Saved ${cookieArray.length} cookies to storage`);
    } catch (e) {
      logger.error('Failed to save cookies:', e);
    }
  }

  /**
   * 从持久化存储加载（Local Storage）
   */
  async load(): Promise<void> {
    try {
      const storage = preferences.getPreferencesSync(this.context, { name: this.storageName });
      const cookieString = storage.getSync('cookies', '[]') as string;
      const cookieArray = JSON.parse(cookieString) as object[];

      this.cookies.clear();
      for (const obj of cookieArray) {
        const data = obj as CookieData;
        // JSON.parse 出来的是裸对象，没有 isExpired 方法；直接按 expires 字段判过期
        if (data.expires && Date.now() > data.expires) {
          continue;
        }
        const key = `${data.name}:${data.domain}:${data.path}`;
        this.cookies.set(key, new Cookie(
          data.name,
          data.value,
          data.domain,
          data.path,
          data.expires,
          data.secure,
          data.httpOnly,
          data.sameSite,
          data.hostOnly ?? false
        ));
      }

      logger.debug(`Loaded ${this.cookies.size} cookies from storage`);
    } catch (e) {
      logger.error('Failed to load cookies:', e);
    }
  }
}
