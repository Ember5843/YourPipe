import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { url } from '@kit.ArkTS';
import { YTCoreLogger } from '../common/YTCoreLogger';

const logger = YTCoreLogger.getInstance('ChallengeCookies');

export const CHALLENGE_COOKIE_STORAGE_NAME: string = 'yourpipe_challenge_cookies';
const KEY_DOMAIN_MAP: string = 'domain_cookies_json';

/**
 * Stores challenge cookies (reCAPTCHA / anti-bot) per registrable domain
 * (PipePipe ChallengeCookies parity) so a challenge solved for one domain
 * is never leaked to unrelated hosts.
 */
export class ChallengeCookies {
  private static cookies: Map<string, string> = new Map<string, string>();
  private static appContext: common.Context | undefined = undefined;

  private constructor() {}

  static init(context: common.Context): void {
    ChallengeCookies.appContext = context;
    ChallengeCookies.cookies.clear();
    try {
      const store = preferences.getPreferencesSync(context, { name: CHALLENGE_COOKIE_STORAGE_NAME });
      const raw = store.getSync(KEY_DOMAIN_MAP, '{}') as string;
      const parsed = JSON.parse(raw) as Record<string, string>;
      if (parsed && typeof parsed === 'object') {
        Object.keys(parsed).forEach((domain: string): void => {
          const val = parsed[domain];
          if (typeof val === 'string' && val.length > 0) {
            ChallengeCookies.cookies.set(domain.toLowerCase(), val);
          }
        });
      }
      logger.info(`initialized domainCount=${ChallengeCookies.cookies.size}`);
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      logger.warn(`init load failed: ${msg}`);
    }
  }

  /**
   * Extract registrable domain (eTLD+1 approximation sufficient for YouTube/Google/CDNs)
   * or literal IP/localhost when the host is not a DNS suffix domain.
   */
  static domainOf(rawUrl: string): string {
    const trimmed = (rawUrl || '').trim();
    if (!trimmed) {
      return '';
    }
    let host = '';
    try {
      const parsed = url.URL.parseURL(trimmed);
      host = (parsed.hostname || '').toLowerCase();
    } catch (_e) {
      return '';
    }
    if (!host) {
      return '';
    }
    if (host === 'localhost' || /^\d+\.\d+\.\d+\.\d+$/.test(host) || host.indexOf(':') >= 0) {
      return host;
    }
    const parts = host.split('.');
    if (parts.length <= 2) {
      return host;
    }
    // Common multi-label public suffixes used by media/service hosts (e.g. .co.uk, .com.br, .co.jp)
    const last = parts[parts.length - 1];
    const secondLast = parts[parts.length - 2];
    if (parts.length >= 3 && last.length === 2
      && (secondLast === 'co' || secondLast === 'com' || secondLast === 'org' || secondLast === 'net')) {
      return `${parts[parts.length - 3]}.${secondLast}.${last}`;
    }
    return `${secondLast}.${last}`;
  }

  static get(rawUrl: string): string | undefined {
    const domain = ChallengeCookies.domainOf(rawUrl);
    if (!domain) {
      return undefined;
    }
    return ChallengeCookies.cookies.get(domain);
  }

  static put(domain: string, cookie: string): void {
    const normalized = (domain || '').trim().toLowerCase();
    if (!normalized) {
      return;
    }
    if (!cookie || cookie.trim().length === 0) {
      ChallengeCookies.cookies.delete(normalized);
    } else {
      ChallengeCookies.cookies.set(normalized, cookie.trim());
    }
    ChallengeCookies.persist();
  }

  static isEmpty(): boolean {
    return ChallengeCookies.cookies.size === 0;
  }

  static clear(): void {
    ChallengeCookies.cookies.clear();
    const ctx = ChallengeCookies.appContext;
    if (!ctx) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(ctx, { name: CHALLENGE_COOKIE_STORAGE_NAME });
      store.clearSync();
      store.flush().catch((e: Error): void => {
        logger.warn(`clear flush failed: ${e.message || String(e)}`);
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      logger.warn(`clear failed: ${msg}`);
    }
  }

  private static persist(): void {
    const ctx = ChallengeCookies.appContext;
    if (!ctx) {
      return;
    }
    try {
      const store = preferences.getPreferencesSync(ctx, { name: CHALLENGE_COOKIE_STORAGE_NAME });
      const record: Record<string, string> = {};
      ChallengeCookies.cookies.forEach((value: string, key: string): void => {
        record[key] = value;
      });
      store.putSync(KEY_DOMAIN_MAP, JSON.stringify(record));
      store.flush().catch((e: Error): void => {
        logger.warn(`persist flush failed: ${e.message || String(e)}`);
      });
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      logger.warn(`persist failed: ${msg}`);
    }
  }
}
