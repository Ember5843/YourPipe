import { ClientsConstants } from '../model/ClientsConstants';
import { YouTubeHttpClient } from '../network/YouTubeHttpClient';
import { YTCoreLogger } from './YTCoreLogger';

const logger = YTCoreLogger.getInstance('WebClientVersionResolver');

/**
 * PipePipe YoutubeParsingHelper.getClientVersion():
 * process cache → sw.js → results HTML → WEB_HARDCODED_CLIENT_VERSION.
 * Shared by mweb stream player, WEB metadata /player, and /next.
 */
export class WebClientVersionResolver {
  private static cachedVersion: string = '';
  private static resolvePromise: Promise<string> | undefined = undefined;

  private static readonly VERSION_REGEXES: string[] = [
    'INNERTUBE_CONTEXT_CLIENT_VERSION":"([0-9\\.]+?)"',
    'innertube_context_client_version":"([0-9\\.]+?)"',
    'client\\.version=([0-9\\.]+)'
  ];

  private constructor() {}

  /** Sync read: cache if resolved, else hardcoded fallback (no network). */
  static getCachedOrHardcoded(): string {
    if (WebClientVersionResolver.cachedVersion.length > 0) {
      return WebClientVersionResolver.cachedVersion;
    }
    return ClientsConstants.WEB_HARDCODED_CLIENT_VERSION;
  }

  static getCachedOrHardcodedSource(): string {
    return WebClientVersionResolver.cachedVersion.length > 0 ? 'cache' : 'builtin';
  }

  static peekCached(): string {
    return WebClientVersionResolver.cachedVersion;
  }

  /** Force a known version (tests / local injection). */
  static setCached(version: string): void {
    if (version && version.length > 0) {
      WebClientVersionResolver.cachedVersion = version;
    }
  }

  static clearCache(): void {
    WebClientVersionResolver.cachedVersion = '';
    WebClientVersionResolver.resolvePromise = undefined;
  }

  /**
   * Ensure process-level WEB client version is available.
   * Concurrent callers share one in-flight resolve.
   */
  static async getClientVersion(httpClient: YouTubeHttpClient): Promise<string> {
    if (WebClientVersionResolver.cachedVersion.length > 0) {
      return WebClientVersionResolver.cachedVersion;
    }
    if (WebClientVersionResolver.resolvePromise) {
      return WebClientVersionResolver.resolvePromise;
    }
    WebClientVersionResolver.resolvePromise =
      WebClientVersionResolver.resolveFromNetwork(httpClient);
    try {
      const version = await WebClientVersionResolver.resolvePromise;
      return version;
    } finally {
      WebClientVersionResolver.resolvePromise = undefined;
    }
  }

  private static async resolveFromNetwork(httpClient: YouTubeHttpClient): Promise<string> {
    try {
      const fromSw = await WebClientVersionResolver.extractFromSwJs(httpClient);
      if (fromSw) {
        WebClientVersionResolver.cachedVersion = fromSw;
        logger.info(`[WEB_VER] from sw.js: ${fromSw}`);
        return fromSw;
      }
    } catch (e) {
      logger.warn('[WEB_VER] sw.js extract failed:', e);
    }

    try {
      const fromHtml = await WebClientVersionResolver.extractFromResultsHtml(httpClient);
      if (fromHtml) {
        WebClientVersionResolver.cachedVersion = fromHtml;
        logger.info(`[WEB_VER] from results HTML: ${fromHtml}`);
        return fromHtml;
      }
    } catch (e) {
      logger.warn('[WEB_VER] results HTML extract failed:', e);
    }

    const fallback = ClientsConstants.WEB_HARDCODED_CLIENT_VERSION;
    WebClientVersionResolver.cachedVersion = fallback;
    logger.info(`[WEB_VER] hardcoded fallback: ${fallback}`);
    return fallback;
  }

  private static async extractFromSwJs(httpClient: YouTubeHttpClient): Promise<string> {
    const headers: Record<string, string> = {
      'Origin': 'https://www.youtube.com',
      'Referer': 'https://www.youtube.com/'
    };
    const response = await httpClient.get('https://www.youtube.com/sw.js', headers, false);
    if (response.responseCode !== 200 || !response.result) {
      return '';
    }
    return WebClientVersionResolver.matchVersion(response.result as string);
  }

  private static async extractFromResultsHtml(httpClient: YouTubeHttpClient): Promise<string> {
    // Empty query keeps payload smaller (PipePipe extractClientVersionFromHtmlSearchResultsPage).
    const url = 'https://www.youtube.com/results?search_query=&ucbcb=1';
    const response = await httpClient.get(url, undefined, false);
    if (response.responseCode !== 200 || !response.result) {
      return '';
    }
    const html = response.result as string;
    const fromCsi = WebClientVersionResolver.matchFromServiceTracking(html, 'CSI', 'cver');
    if (fromCsi) {
      return fromCsi;
    }
    const fromRegex = WebClientVersionResolver.matchVersion(html);
    if (fromRegex) {
      return fromRegex;
    }
    return WebClientVersionResolver.matchFromServiceTracking(html, 'ECATCHER', 'client.version');
  }

  private static matchVersion(input: string): string {
    for (const pattern of WebClientVersionResolver.VERSION_REGEXES) {
      const match = new RegExp(pattern).exec(input);
      if (match && match[1] && match[1].length > 0) {
        return match[1];
      }
    }
    return '';
  }

  /**
   * Best-effort parse of ytInitialData serviceTrackingParams (CSI cver / ECATCHER).
   * Falls back to empty when JSON brace-match fails.
   */
  private static matchFromServiceTracking(
    html: string,
    service: string,
    key: string
  ): string {
    const marker = 'ytInitialData';
    const idx = html.indexOf(marker);
    if (idx < 0) {
      return '';
    }
    const braceStart = html.indexOf('{', idx + marker.length);
    if (braceStart < 0) {
      return '';
    }
    const jsonText = WebClientVersionResolver.braceMatchObject(html, braceStart);
    if (!jsonText) {
      return '';
    }
    try {
      const data = JSON.parse(jsonText) as Record<string, Object>;
      const responseContext = data['responseContext'] as Record<string, Object> | undefined;
      const params = responseContext?.['serviceTrackingParams'] as Object[] | undefined;
      if (!params || params.length === 0) {
        return '';
      }
      for (const entry of params) {
        const obj = entry as Record<string, Object>;
        if ((obj['service'] as string) !== service) {
          continue;
        }
        const arr = obj['params'] as Object[] | undefined;
        if (!arr) {
          continue;
        }
        for (const p of arr) {
          const pair = p as Record<string, Object>;
          if ((pair['key'] as string) === key) {
            const value = pair['value'] as string;
            if (value && value.length > 0) {
              return value;
            }
          }
        }
      }
    } catch (_e) {
      return '';
    }
    return '';
  }

  private static braceMatchObject(source: string, start: number): string {
    let depth = 0;
    let inString = false;
    let escaped = false;
    for (let i = start; i < source.length; i++) {
      const ch = source.charAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch === '\\') {
          escaped = true;
        } else if (ch === '"') {
          inString = false;
        }
        continue;
      }
      if (ch === '"') {
        inString = true;
        continue;
      }
      if (ch === '{') {
        depth++;
      } else if (ch === '}') {
        depth--;
        if (depth === 0) {
          return source.substring(start, i + 1);
        }
      }
    }
    return '';
  }
}
