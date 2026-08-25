import { YTCoreLogger } from './YTCoreLogger';

const logger = YTCoreLogger.getInstance('YoutubeParsingHelper');

/**
 * Fix thumbnail URL: ensure https:// prefix and handle // shorthand.
 * Ported from org.schabi.newpipe.extractor.services.youtube.YoutubeParsingHelper.fixThumbnailUrl
 */
export function fixThumbnailUrl(url: string | undefined): string {
  if (!url) {
    return '';
  }
  let fixed = url;
  if (fixed.startsWith('//')) {
    fixed = 'https:' + fixed;
  } else if (fixed.startsWith('http://')) {
    fixed = fixed.replace('http://', 'https://');
  }
  return fixed;
}

/**
 * Always pick the highest-resolution thumbnail from a list of {url,width?,height?} objects.
 * Prefer width*height; upgrade standard /vi/{id}/ stills to maxresdefault.
 */
export function pickHighestThumbnailUrl(
  candidates: Array<Record<string, Object>>
): string {
  if (!candidates || candidates.length === 0) {
    return '';
  }
  let bestUrl = '';
  let bestScore = -1;
  for (let i = 0; i < candidates.length; i++) {
    const item = candidates[i] as Record<string, Object>;
    if (!item) {
      continue;
    }
    const raw = (item['url'] as string) || '';
    const url = fixThumbnailUrl(raw);
    if (url.length === 0) {
      continue;
    }
    const width = Number(item['width'] ?? 0);
    const height = Number(item['height'] ?? 0);
    let score = 0;
    if (width > 0 && height > 0) {
      score = width * height;
    } else if (width > 0) {
      score = width * 1000;
    } else if (height > 0) {
      score = height * 1000;
    } else {
      const lower = url.toLowerCase();
      if (lower.indexOf('maxresdefault') >= 0) {
        score = 100000;
      } else if (lower.indexOf('hq720') >= 0) {
        score = 90000;
      } else if (lower.indexOf('sddefault') >= 0) {
        score = 80000;
      } else if (lower.indexOf('hqdefault') >= 0) {
        score = 70000;
      } else if (lower.indexOf('mqdefault') >= 0) {
        score = 60000;
      } else if (lower.indexOf('default.jpg') >= 0 || lower.indexOf('/default.') >= 0) {
        score = 50000;
      } else {
        score = i;
      }
    }
    if (score >= bestScore) {
      bestScore = score;
      bestUrl = url;
    }
  }
  // Upgrade standard video stills to maxres when possible
  const match = /(?:^https?:\/\/)?(?:i\d*\.)?ytimg\.com\/vi(?:_webp)?\/([^/]+)\//i.exec(bestUrl);
  if (match && match[1] && match[1].length > 0) {
    return `https://i.ytimg.com/vi/${match[1]}/maxresdefault.jpg`;
  }
  return bestUrl;
}

/**
 * Extract text from a JSON object that may contain simpleText or runs.
 * Ported from org.schabi.newpipe.extractor.services.youtube.YoutubeParsingHelper.getTextFromObject
 */
export function getTextFromObject(obj: Record<string, Object> | undefined, returnHtml: boolean = false): string {
  if (!obj) {
    return '';
  }
  if (obj.simpleText) {
    return obj.simpleText as string;
  }
  if (obj.runs && Array.isArray(obj.runs)) {
    if (returnHtml) {
      // HTML mode: preserve formatting from navigationEndpoint if present
      return (obj.runs as Record<string, Object>[]).map((run: Record<string, Object>): string => {
        let text = run.text as string || '';
        const navEndpoint = run.navigationEndpoint as Record<string, Object>;
        if (navEndpoint) {
          const cmdMeta = navEndpoint.commandMetadata as Record<string, Object>;
          if (cmdMeta) {
            const webCmdMeta = cmdMeta.webCommandMetadata as Record<string, Object>;
            if (webCmdMeta) {
              const url = webCmdMeta.url as string;
              if (url) {
                text = `<a href="${url}">${text}</a>`;
              }
            }
          }
        }
        return text;
      }).join('');
    }
    return (obj.runs as Record<string, Object>[]).map((run: Record<string, Object>): string => run.text as string || '').join('');
  }
  return '';
}

/**
 * Generate a Content Playback Nonce (CPN).
 * YouTube uses a 16-character base64url-like string.
 * Ported from org.schabi.newpipe.extractor.services.youtube.YoutubeParsingHelper.generateContentPlaybackNonce
 */
export function generateContentPlaybackNonce(): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  let result = '';
  for (let i = 0; i < 16; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return result;
}

/**
 * Generate a random t-parameter for InnerTube requests.
 * Ported from org.schabi.newpipe.extractor.services.youtube.YoutubeParsingHelper.generateTParameter
 */
export function generateTParameter(): string {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  let result = '';
  for (let i = 0; i < 12; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return result;
}

/**
 * Check for default alerts in InnerTube response and throw if error.
 * Ported from org.schabi.newpipe.extractor.services.youtube.YoutubeParsingHelper.defaultAlertsCheck
 */
export function defaultAlertsCheck(response: Record<string, Object>): void {
  const alerts = response.alerts as Array<Record<string, Object>>;
  if (!alerts || !Array.isArray(alerts)) {
    return;
  }
  for (const alert of alerts) {
    const alertObj = alert as Record<string, Object>;
    const alertRenderer = alertObj.alertRenderer || alertObj.alertModelRenderer;
    if (alertRenderer) {
      const rendererObj = alertRenderer as Record<string, Object>;
      const text = getTextFromObject(rendererObj.text as Record<string, Object>);
      const type = rendererObj.type as string;
      if (type === 'ERROR') {
        throw new Error(`InnerTube alert: ${text}`);
      }
    }
  }
}

/**
 * Check if a channel is verified from badges array.
 * Ported from org.schabi.newpipe.extractor.services.youtube.YoutubeParsingHelper.isVerified
 */
export function isVerified(badges: Array<Record<string, Object>>): boolean {
  if (!badges || !Array.isArray(badges)) {
    return false;
  }
  return badges.some((badge: Record<string, Object>): boolean => {
    const renderer = badge.metadataBadgeRenderer as Record<string, Object>;
    if (!renderer) return false;
    const style = renderer.style as string || '';
    return style.includes('VERIFIED');
  });
}

/**
 * Extract a value from a nested JSON object by dot-separated path.
 */
export function getNestedValue(obj: Object, path: string): Object | null {
  const keys = path.split('.');
  let current: Object = obj;
  for (const key of keys) {
    if (current && typeof current === 'object') {
      const currentRecord = current as Record<string, Object>;
      const next = currentRecord[key];
      if (next !== undefined && next !== null) {
        current = next;
      } else {
        return null;
      }
    } else {
      return null;
    }
  }
  return current;
}

/**
 * Brace-matching extraction of a complete JSON object starting at `start`
 * (which must point at '{'). String/escape aware. Returns '' when no
 * matching closing brace exists. Shared by the watch-page player response
 * extractor and WebClientVersionResolver.
 */
export function braceMatchJsonObject(source: string, start: number): string {
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

/**
 * Shared K/M/B-suffixed number parser.
 * `fallback` is returned for empty input or no match; `round` selects
 * Math.round over Math.floor. Comma handling is left to the caller's regex.
 */
function parseSuffixedNumber(text: string | undefined, fallback: number, pattern: RegExp, round: boolean): number {
  if (!text) return fallback;
  const m = text.match(pattern);
  if (!m) return fallback;
  const num = parseFloat(m[1].replace(/,/g, ''));
  let multiplier = 1;
  const unit = m[2].toLowerCase();
  if (unit === 'k') multiplier = 1000;
  else if (unit === 'm') multiplier = 1000000;
  else if (unit === 'b') multiplier = 1000000000;
  const value = num * multiplier;
  return round ? Math.round(value) : Math.floor(value);
}

/**
 * Parse a number string that may contain K/M/B suffixes or commas.
 * Commas are stripped as thousand separators before matching.
 */
export function parseMixedNumber(text: string | undefined): number {
  if (!text) return 0;
  return parseSuffixedNumber(text.replace(/,/g, ''), 0, /(\d+(?:\.\d+)?)\s*([KMBkmb]?)/, false);
}

/**
 * Parse subscriber count text (e.g. "1.2M subscribers").
 * Ported from org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeStreamExtractor
 */
export function parseSubscriberCount(text: string | undefined): number {
  return parseSuffixedNumber(text, -1, /([\d,.]+)\s*([KMBkmb]?)/, true);
}

/**
 * Parse duration text in HH:MM:SS or MM:SS format.
 * Ported from org.schabi.newpipe.extractor.services.youtube.extractors.YoutubeStreamExtractor
 */
export function parseDurationText(text: string | undefined): number {
  if (!text) return 0;
  const parts = text.split(':').map(p => parseInt(p) || 0);
  if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  if (parts.length === 2) return parts[0] * 60 + parts[1];
  return parts[0] || 0;
}
