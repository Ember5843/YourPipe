import { AuthSessionManager, HttpDownloader, SessionIdentityManager } from 'youtube_core';
import web_webview from '@ohos.web.webview';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';
import { AppLog } from '../../common/AppLog';
import {
  parseYoutubePageAttestationBootstrap,
  SabrAttChallengeData,
  YoutubePageAttestationBootstrap
} from './YoutubePageAttestationBootstrap';

const logger = AppLog.getInstance('SabrLocalDomPoToken');
const API_KEY = 'AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw';
const REQUEST_KEY = 'O43z0dpjhgX20SCx4KAo';
const YOUTUBE_HOME = 'https://www.youtube.com';
const ANONYMOUS_COOKIE = 'PREF=hl=en&gl=US';
/** Matches PipePipe SharedWebViewRuntime.USER_AGENT (home fetch + WebView runtime). */
export const SABR_POTOKEN_USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
  + 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.3';
/** PipePipe EXPIRY_MARGIN_MS: treat the minter as expired 60s before GenerateIT expiry. */
const EXPIRY_MARGIN_SECONDS = 60;

/**
 * Local-DOM PoToken generator (PipePipe 5.3.0 LocalDomPoTokenProvider parity).
 *
 * The BotGuard attestation bootstrap is parsed from the YouTube home page
 * (ytcfg.set / window.ytAtN): the embedded challenge is bound to the page
 * session's EVENT_ID, which is injected into the WebView before BotGuard
 * runs. Tokens minted from an out-of-band /att/get challenge are rejected by
 * SABR at the ~60s boundary (PipePipe issue #2820 / BgUtils PR#44).
 *
 * The minted token binding follows the home page experiment flags:
 * content -> mint per identifier (videoId); session -> mint once against the
 * DataSync ID (signed-in) or the bootstrap visitorData (anonymous) and reuse.
 */
export class SabrLocalDomPoTokenGenerator {
  private controller: web_webview.WebviewController;
  private resourceManager: resourceManager.ResourceManager;
  private bootstrap?: YoutubePageAttestationBootstrap;
  private sessionPoToken?: Uint8Array;
  private expiresAtMs: number = 0;
  /** In-flight initialize() guard: concurrent mints share one bootstrap pass. */
  private initPromise?: Promise<void>;

  constructor(controller: web_webview.WebviewController, resourceManager: resourceManager.ResourceManager) {
    this.controller = controller;
    this.resourceManager = resourceManager;
  }

  async mint(_visitorData: string, identifier: string, forceRefresh: boolean): Promise<Uint8Array | undefined> {
    if (forceRefresh || !this.bootstrap || Date.now() >= this.expiresAtMs) {
      await this.initialize();
    }
    const bootstrap = this.bootstrap!;
    if (bootstrap.binding === 'session') {
      return this.sessionPoToken;
    }
    return await this.mintIdentifier(identifier);
  }

  /**
   * PipePipe LocalDomPoTokenProvider.invalidate(): drop the current bootstrap
   * and minter so the next mint re-fetches the home page and starts a fresh
   * attestation session (identity rotation / credential change).
   */
  invalidate(): void {
    this.bootstrap = undefined;
    this.sessionPoToken = undefined;
    this.expiresAtMs = 0;
  }

  /**
   * Idempotent bootstrap: while one initialization is running, later callers
   * (e.g. the startup warmRuntime racing a real mint) await the same promise
   * instead of duplicating the home-page fetch and interleaving runJavaScript
   * on the singleton BotGuard state. The guard clears on settle — a failure
   * leaves no stale promise so the next mint retries, and a success is
   * re-entered once the bootstrap expires (mint() gates on expiresAtMs).
   */
  private initialize(): Promise<void> {
    if (this.initPromise) {
      return this.initPromise;
    }
    const pending = this.doInitialize();
    this.initPromise = pending;
    const clear = (): void => {
      if (this.initPromise === pending) {
        this.initPromise = undefined;
      }
    };
    pending.then(clear, clear);
    return pending;
  }

  private async doInitialize(): Promise<void> {
    logger.info('initialization start');
    const helperBytes: Uint8Array = this.resourceManager.getRawFileContentSync('sabr_po_token.js');
    const helper = new util.TextDecoder('utf-8').decodeWithStream(helperBytes);
    await this.runJs(helper);

    const auth = AuthSessionManager.getInstance();
    const loggedIn = auth?.hasCookieAuthForUserData() === true;
    const loginCookie = loggedIn ? (auth?.getCookieStringForUserData() || '') : '';
    const pageHtml = await requestText(
      YOUTUBE_HOME,
      http.RequestMethod.GET,
      undefined,
      undefined,
      {
        'Accept-Language': 'en-US',
        'Cookie': loginCookie.length > 0 ? loginCookie : ANONYMOUS_COOKIE
      });
    const bootstrap = parseYoutubePageAttestationBootstrap(pageHtml);
    if (bootstrap.binding === 'none') {
      throw new Error('YouTube home does not enable a supported PO token binding');
    }
    logger.info(`bootstrap parsed client=${bootstrap.clientName} version=${bootstrap.clientVersion} `
      + `binding=${bootstrap.binding} loggedIn=${loggedIn}`);

    let interpreter = bootstrap.challenge.interpreterJavascript;
    if (!interpreter) {
      interpreter = await requestText(
        bootstrap.challenge.interpreterUrl!, http.RequestMethod.GET, undefined, undefined);
    }

    const runScript = `yourpipeRunBotGuard(${JSON.stringify(bootstrap.eventId)},`
      + `${JSON.stringify(buildChallengePayload(bootstrap.challenge, interpreter))});true`;
    await this.runJs(runScript);
    await this.waitForStatus('botguard-ready', 15000);
    const botguardResult = await this.runJs('window.__yourpipeSabr.botguardResponse');
    const botguardResponse = decodeJsString(botguardResult);

    const integrityBody = await requestText(
      'https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa/GenerateIT',
      http.RequestMethod.POST,
      JSON.stringify([REQUEST_KEY, botguardResponse]),
      'application/json+protobuf');
    const integrity = JSON.parse(integrityBody) as Object[];
    const integrityBase64 = String(integrity[0]);
    const expirationSeconds = Number(integrity[1]);
    const integrityBytes = decodeBase64Url(integrityBase64);
    const createResult = await this.runJs(
      `yourpipeCreateMinter(new Uint8Array([${bytesToCsv(integrityBytes)}]))`);
    const createStatus = decodeJsString(createResult);
    if (createStatus !== 'minter-ready') {
      const jsError = decodeJsString(
        await this.runJs('window.__yourpipeSabr.error'));
      throw new Error(`Local DOM minter creation failed: ${jsError || createStatus}`);
    }

    let sessionPoToken: Uint8Array | undefined = undefined;
    if (bootstrap.binding === 'session') {
      let sessionBinding: string;
      if (loggedIn) {
        if (!bootstrap.dataSyncId) {
          throw new Error('Authenticated YouTube home has no Data Sync ID');
        }
        sessionBinding = bootstrap.dataSyncId;
      } else {
        sessionBinding = bootstrap.visitorData;
      }
      sessionPoToken = await this.mintIdentifier(sessionBinding);
    }

    this.bootstrap = bootstrap;
    this.sessionPoToken = sessionPoToken;
    this.expiresAtMs = Date.now()
      + Math.max(EXPIRY_MARGIN_SECONDS, expirationSeconds - EXPIRY_MARGIN_SECONDS) * 1000;

    // PipePipe parity: the mweb PoToken path runs on the bootstrap identity —
    // the home page visitorData drives /player, the UMP session and (for
    // anonymous session binding) the session token itself.
    SessionIdentityManager.pin(bootstrap.visitorData);
    logger.info(`initialization complete expiresIn=${expirationSeconds}s binding=${bootstrap.binding}`);
  }

  private async mintIdentifier(identifier: string): Promise<Uint8Array | undefined> {
    const result = await this.runJs(
      `yourpipeMintPoToken(${JSON.stringify(identifier)})`);
    const csv = decodeJsString(result);
    if (!csv) {
      return undefined;
    }
    const parts = csv.split(',');
    const bytes = new Uint8Array(parts.length);
    for (let i = 0; i < parts.length; i++) {
      bytes[i] = parseInt(parts[i], 10) & 0xff;
    }
    return bytes;
  }

  /**
   * runJavaScript with a hard cap: a wedged ArkWeb bridge must fail fast so the
   * mint layer above can drop the poisoned promise instead of hanging playback.
   */
  private runJs(script: string, timeoutMs: number = 6000): Promise<string> {
    return Promise.race([
      this.controller.runJavaScript(script),
      new Promise<never>((_resolve, reject) => {
        setTimeout(() => reject(new Error(`runJavaScript timeout ${timeoutMs}ms`)), timeoutMs);
      })
    ]);
  }

  private async waitForStatus(expected: string, timeoutMs: number): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const raw = await this.runJs('window.__yourpipeSabr.status', 3000);
      const status = decodeJsString(raw);
      if (status === expected) {
        return;
      }
      if (status === 'error') {
        const error = decodeJsString(await this.runJs('window.__yourpipeSabr.error', 3000));
        throw new Error(error || 'Local DOM BotGuard failed');
      }
      await sleep(50);
    }
    throw new Error(`Local DOM status timeout: ${expected}`);
  }
}

/** PipePipe buildSabrAttChallengeData: the JS helper reads the wrapped shape. */
function buildChallengePayload(
  challenge: SabrAttChallengeData,
  interpreterJavascript: string
): Record<string, Object> {
  return {
    'interpreterJavascript': {
      'privateDoNotAccessOrElseSafeScriptWrappedValue': interpreterJavascript
    } as Record<string, Object>,
    'program': challenge.program,
    'globalName': challenge.globalName
  };
}

async function requestText(
  url: string,
  method: http.RequestMethod,
  body?: string,
  contentType?: string,
  extraHeaders?: Record<string, string>
): Promise<string> {
  const request = http.createHttp();
  try {
    const headers: Record<string, string> = {
      'User-Agent': SABR_POTOKEN_USER_AGENT,
      'Accept': contentType ? 'application/json' : '*/*'
    };
    if (contentType) {
      headers['Content-Type'] = contentType;
      headers['x-goog-api-key'] = API_KEY;
      headers['x-user-agent'] = 'grpc-web-javascript/0.1';
    }
    if (extraHeaders) {
      Object.keys(extraHeaders).forEach((key: string) => {
        headers[key] = extraHeaders[key];
      });
    }
    const options: http.HttpRequestOptions = {
      method: method,
      header: headers,
      extraData: body,
      connectTimeout: 15000,
      readTimeout: 30000
    };
    HttpDownloader.applyProxyToOptions(options, url);
    const response = await request.request(url, options);
    if (response.responseCode !== 200) {
      throw new Error(`HTTP ${response.responseCode} for ${url}`);
    }
    return typeof response.result === 'string' ? response.result : String(response.result);
  } finally {
    request.destroy();
  }
}

function decodeJsString(value: string): string {
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    return JSON.parse(value) as string;
  }
  return value;
}

function decodeBase64Url(value: string): Uint8Array {
  // Normalize base64url (RFC 4648 §5, '.' as padding) to standard base64 and
  // decode via the platform API. The previous hand-rolled decoder stopped at
  // the first non-alphabet character and never required '=' padding; keep that
  // tolerance by decoding only the valid alphabet prefix, padded to a full
  // quantum (a lone leftover char carries 6 bits and decodes to nothing).
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/').replace(/\./g, '=');
  const match = normalized.match(/^[A-Za-z0-9+/]*/);
  let prefix = match ? match[0] : '';
  if (prefix.length % 4 === 1) {
    prefix = prefix.substring(0, prefix.length - 1);
  }
  while (prefix.length % 4 !== 0) {
    prefix += '=';
  }
  return new util.Base64Helper().decodeSync(prefix);
}

function bytesToCsv(bytes: Uint8Array): string {
  let result = '';
  for (let i = 0; i < bytes.length; i++) {
    if (i > 0) result += ',';
    result += bytes[i].toString();
  }
  return result;
}

function bytesToBase64Url(bytes: Uint8Array): string {
  // Standard base64 from platform API, then make it URL-safe (RFC 4648 §5):
  //   '+' -> '-', '/' -> '_', strip '=' padding.
  const helper = new util.Base64Helper();
  const standard = helper.encodeToStringSync(bytes);
  let out = '';
  for (let i = 0; i < standard.length; i++) {
    const c = standard.charAt(i);
    if (c === '+') {
      out += '-';
    } else if (c === '/') {
      out += '_';
    } else if (c === '=') {
      break;
    } else {
      out += c;
    }
  }
  return out;
}

export function poTokenBytesToString(token: Uint8Array): string {
  return bytesToBase64Url(token);
}

function sleep(ms: number): Promise<void> {
  return new Promise<void>((resolve) => setTimeout(resolve, ms));
}
