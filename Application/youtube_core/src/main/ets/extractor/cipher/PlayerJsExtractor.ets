import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { buffer } from '@kit.ArkTS';
import { YTCoreLogger } from '../../common/YTCoreLogger';
import { YouTubeHttpClient } from '../../network/YouTubeHttpClient';

const logger = YTCoreLogger.getInstance('PlayerJsExtractor');

const PLAYER_JS_URL_PATTERNS: RegExp[] = [
  /"PLAYER_JS_URL"\s*:\s*"([^"]+)"/,
  /"jsUrl"\s*:\s*"([^"]+)"/,
];

const PLAYER_ID_PATTERN = /\/s\/player\/([a-fA-F0-9]{8,})\//;
const SIGNATURE_TIMESTAMP_PATTERN = /signatureTimestamp[=:](\d+)/;

const IFRAME_API_URL = 'https://www.youtube.com/iframe_api';
const IFRAME_PLAYER_VERSION_PATTERN = /player\\?\/([0-9a-fA-F]{8})\\?\//;

export class PlayerJsExtractor {
  /**
   * 从 watch 页 HTML 抽 player.js URL。
   * 返回完整 URL（含 https:// 前缀），找不到返回 null。
   */
  static extractPlayerJsUrl(html: string): string | null {
    for (const pattern of PLAYER_JS_URL_PATTERNS) {
      const match = pattern.exec(html);
      if (match && match[1]) {
        let url = match[1].replace(/\\\//g, '/');
        if (url.startsWith('//')) {
          url = 'https:' + url;
        } else if (url.startsWith('/')) {
          url = 'https://www.youtube.com' + url;
        }
        return url;
      }
    }
    return null;
  }

  /**
   * 从 player.js URL 抽 8+ 位 hex 的 player ID。
   */
  static extractPlayerId(playerJsUrl: string): string | null {
    const match = PLAYER_ID_PATTERN.exec(playerJsUrl);
    return match && match[1] ? match[1] : null;
  }

  /**
   * 退化方案:从 iframe_api 抓 player ID 后拼出标准 player.js URL。
   */
  static async fetchPlayerJsUrlFromIframeApi(client: YouTubeHttpClient): Promise<string | null> {
    try {
      const response = await client.get(IFRAME_API_URL);
      if (response.responseCode !== 200) {
        logger.warn(`iframe_api HTTP ${response.responseCode}`);
        return null;
      }
      const html = response.result as string;
      const match = IFRAME_PLAYER_VERSION_PATTERN.exec(html);
      if (!match || !match[1]) {
        logger.warn('iframe_api: player version not found');
        return null;
      }
      return `https://www.youtube.com/s/player/${match[1]}/player_ias.vflset/en_US/base.js`;
    } catch (e) {
      logger.warn('iframe_api fetch failed:', e);
      return null;
    }
  }

  /**
   * 从 player.js 文本抽 signatureTimestamp。
   */
  static extractSignatureTimestamp(playerJs: string): number | null {
    const match = SIGNATURE_TIMESTAMP_PATTERN.exec(playerJs);
    if (!match || !match[1]) {
      return null;
    }
    const sts = Number(match[1]);
    return Number.isFinite(sts) && sts > 0 ? sts : null;
  }

  /**
   * 计算 player.js 的 sha256 hex,与云端 crypto.createHash('sha256').update(playerJs).digest('hex') 一致。
   */
  static async computePlayerHash(playerJs: string): Promise<string> {
    const md = cryptoFramework.createMd('SHA256');
    const inputBlob: cryptoFramework.DataBlob = {
      data: new Uint8Array(buffer.from(playerJs, 'utf-8').buffer),
    };
    await md.update(inputBlob);
    const digest = await md.digest();
    return PlayerJsExtractor.bytesToHex(digest.data);
  }

  /**
   * 拉取 player.js 文本。
   */
  static async fetchPlayerJs(playerJsUrl: string, client: YouTubeHttpClient): Promise<string> {
    const response: http.HttpResponse = await client.get(playerJsUrl);
    if (response.responseCode !== 200) {
      throw new Error(`Fetch player.js failed: HTTP ${response.responseCode}`);
    }
    const body = response.result;
    if (typeof body === 'string') {
      return body;
    }
    if (body instanceof ArrayBuffer) {
      const bytes = new Uint8Array(body);
      let result = '';
      for (let i = 0; i < bytes.length; i++) {
        result += String.fromCharCode(bytes[i]);
      }
      return result;
    }
    throw new Error('player.js response has unexpected body type');
  }

  private static bytesToHex(bytes: Uint8Array): string {
    const out: string[] = [];
    for (let i = 0; i < bytes.length; i++) {
      const b = bytes[i];
      out.push(((b >> 4) & 0x0f).toString(16));
      out.push((b & 0x0f).toString(16));
    }
    return out.join('');
  }
}
