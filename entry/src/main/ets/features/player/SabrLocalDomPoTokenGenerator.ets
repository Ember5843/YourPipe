import { HttpDownloader, WebClientVersionResolver } from 'youtube_core';
import web_webview from '@ohos.web.webview';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';
import { AppLog } from '../../common/AppLog';

const logger = AppLog.getInstance('SabrLocalDomPoToken');
const API_KEY = 'AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw';
const REQUEST_KEY = 'O43z0dpjhgX20SCx4KAo';
const USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
  + '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.3';

interface ChallengeResponse {
  bgChallenge: BgChallenge;
}

interface BgChallenge {
  program: string;
  globalName: string;
  interpreterUrl: WrappedUrl;
}

interface WrappedUrl {
  privateDoNotAccessOrElseTrustedResourceUrlWrappedValue: string;
}

class AttClient {
  clientName: string = 'WEB';
  clientVersion: string = WebClientVersionResolver.getCachedOrHardcoded();
}

class AttContext {
  client: AttClient = new AttClient();
}

class AttRequest {
  context: AttContext = new AttContext();
  engagementType: string = 'ENGAGEMENT_TYPE_UNBOUND';
}

class BotGuardInput {
  program: string;
  globalName: string;
  interpreterJavascript: string;

  constructor(program: string, globalName: string, interpreterJavascript: string) {
    this.program = program;
    this.globalName = globalName;
    this.interpreterJavascript = interpreterJavascript;
  }
}

export class SabrLocalDomPoTokenGenerator {
  private controller: web_webview.WebviewController;
  private resourceManager: resourceManager.ResourceManager;
  private initializedVisitorData: string = '';
  private expiresAtMs: number = 0;

  constructor(controller: web_webview.WebviewController, resourceManager: resourceManager.ResourceManager) {
    this.controller = controller;
    this.resourceManager = resourceManager;
  }

  async mint(visitorData: string, videoId: string, forceRefresh: boolean): Promise<Uint8Array | undefined> {
    if (forceRefresh || this.initializedVisitorData !== visitorData || Date.now() >= this.expiresAtMs) {
      await this.initialize(visitorData);
    }
    return await this.mintIdentifier(videoId);
  }

  private async initialize(visitorData: string): Promise<void> {
    logger.info('initialization start');
    const helperBytes: Uint8Array = this.resourceManager.getRawFileContentSync('sabr_po_token.js');
    const helper = new util.TextDecoder('utf-8').decodeWithStream(helperBytes);
    await this.runJs(helper);

    const challengeBody = await requestText(
      'https://www.youtube.com/youtubei/v1/att/get?prettyPrint=false',
      http.RequestMethod.POST,
      JSON.stringify(new AttRequest()),
      'application/json');
    const challengeResponse = JSON.parse(challengeBody) as ChallengeResponse;
    const challenge = challengeResponse.bgChallenge;
    let interpreterUrl = challenge.interpreterUrl.privateDoNotAccessOrElseTrustedResourceUrlWrappedValue;
    if (interpreterUrl.startsWith('//')) {
      interpreterUrl = `https:${interpreterUrl}`;
    }
    const interpreter = await requestText(interpreterUrl, http.RequestMethod.GET, undefined, undefined);
    const botGuardInput = new BotGuardInput(challenge.program, challenge.globalName, interpreter);
    const runScript = `yourpipeRunBotGuard(${JSON.stringify(botGuardInput)});true`;
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
    await this.mintIdentifier(visitorData);
    this.initializedVisitorData = visitorData;
    this.expiresAtMs = Date.now() + Math.max(60, expirationSeconds - 600) * 1000;
    logger.info(`initialization complete expiresIn=${expirationSeconds}s`);
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

async function requestText(
  url: string,
  method: http.RequestMethod,
  body?: string,
  contentType?: string
): Promise<string> {
  const request = http.createHttp();
  try {
    const headers: Record<string, string> = {
      'User-Agent': USER_AGENT,
      'Accept': contentType ? 'application/json' : '*/*'
    };
    if (contentType) {
      headers['Content-Type'] = contentType;
      headers['x-goog-api-key'] = API_KEY;
      headers['x-user-agent'] = 'grpc-web-javascript/0.1';
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
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/').replace(/\./g, '=');
  const table = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const out: number[] = [];
  let buffer = 0;
  let bits = 0;
  for (let i = 0; i < normalized.length; i++) {
    const digit = table.indexOf(normalized.charAt(i));
    if (digit < 0) break;
    buffer = (buffer << 6) | digit;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((buffer >> bits) & 0xff);
    }
  }
  return new Uint8Array(out);
}

function bytesToCsv(bytes: Uint8Array): string {
  let result = '';
  for (let i = 0; i < bytes.length; i++) {
    if (i > 0) result += ',';
    result += bytes[i].toString();
  }
  return result;
}

const BASE64URL_CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

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
