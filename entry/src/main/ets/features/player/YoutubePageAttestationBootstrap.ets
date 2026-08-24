/**
 * Port of PipePipe 5.3.0 YoutubePageAttestationBootstrap.kt.
 *
 * YouTube binds the initial BotGuard attestation challenge to the page
 * session's EVENT_ID and embeds it in the home page HTML (window.ytAtN).
 * A challenge fetched out-of-band via /youtubei/v1/att/get produces PoTokens
 * the SABR server rejects at the ~60s boundary (protection status 2 -> 3),
 * so the bootstrap MUST come from parsing the home page itself.
 */

export type YoutubePoTokenBinding = 'content' | 'session' | 'none';

export interface SabrAttChallengeData {
  program: string;
  globalName: string;
  interpreterJavascript?: string;
  interpreterUrl?: string;
}

export interface YoutubePageAttestationBootstrap {
  visitorData: string;
  dataSyncId?: string;
  clientName: string;
  clientVersion: string;
  binding: YoutubePoTokenBinding;
  eventId: string;
  challenge: SabrAttChallengeData;
}

interface JavascriptObjectCall {
  start: number;
  argument: string;
}

interface ConfigCall {
  call: JavascriptObjectCall;
  config: JsonObject;
}

const YTCFG_CALLEE = 'ytcfg.set';
const INITIAL_ATTESTATION_CALLEE = 'window.ytAtN';
const INITIAL_ATTESTATION_RESPONSE: RegExp = new RegExp('[\'"]R[\'"]\\s*:\\s*([\'"])');

type JsonObject = Record<string, Object>;

function asObject(value: Object | undefined | null): JsonObject | undefined {
  if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
    return value as JsonObject;
  }
  return undefined;
}

function asNonEmptyString(value: Object | undefined | null): string | undefined {
  if (typeof value === 'string' && value.length > 0) {
    return value;
  }
  return undefined;
}

export function parseYoutubePageAttestationBootstrap(pageHtml: string): YoutubePageAttestationBootstrap {
  const configCalls: ConfigCall[] = [];
  for (const call of extractObjectCallArguments(pageHtml, YTCFG_CALLEE)) {
    try {
      const parsed = asObject(JSON.parse(call.argument) as Object);
      if (parsed) {
        const entry: ConfigCall = { call: call, config: parsed };
        configCalls.push(entry);
      }
    } catch (_e) {
      // Not a plain JSON object literal; skip like PipePipe's nanojson failure path.
    }
  }

  let challengeCall: JavascriptObjectCall | undefined = undefined;
  let challenge: SabrAttChallengeData | undefined = undefined;
  for (const call of extractObjectCallArguments(pageHtml, INITIAL_ATTESTATION_CALLEE)) {
    const parsed = parseInitialAttestationChallenge(call.argument);
    if (parsed) {
      challengeCall = call;
      challenge = parsed;
      break;
    }
  }
  if (!challengeCall || !challenge) {
    throw new Error('YouTube home has no initial attestation challenge');
  }

  const configs = configCalls
    .filter((entry) => entry.call.start < challengeCall!.start)
    .map((entry) => entry.config);

  let clientConfig: JsonObject | undefined = undefined;
  for (const config of configs) {
    if (config['INNERTUBE_CONTEXT'] !== undefined) {
      clientConfig = config;
    }
  }
  if (!clientConfig) {
    throw new Error('YouTube home has no client context');
  }

  let eventId: string | undefined = undefined;
  for (const config of configs) {
    const value = asNonEmptyString(config['EVENT_ID']);
    if (value) {
      eventId = value;
    }
  }
  if (!eventId) {
    throw new Error('YouTube home has no EVENT_ID');
  }

  const rawVisitorData = asNonEmptyString(clientConfig['EOM_VISITOR_DATA'])
    ?? asNonEmptyString(clientConfig['VISITOR_DATA']);
  if (!rawVisitorData) {
    throw new Error('YouTube home has no anonymous visitor data');
  }
  const visitorData = rawVisitorData.replace(/%3D/gi, '=');

  let dataSyncId: string | undefined = undefined;
  for (const config of configs) {
    const value = asNonEmptyString(config['DATASYNC_ID']);
    if (value) {
      dataSyncId = value;
    }
  }

  const client = asObject(asObject(clientConfig['INNERTUBE_CONTEXT'])?.['client']);
  if (!client) {
    throw new Error('YouTube home has no Innertube client context');
  }
  const clientName = asNonEmptyString(client['clientName']);
  if (!clientName) {
    throw new Error('YouTube home has no client name');
  }
  if (clientName !== 'WEB') {
    throw new Error(`Unsupported YouTube home client: ${clientName}`);
  }
  const clientVersion = asNonEmptyString(client['clientVersion']);
  if (!clientVersion) {
    throw new Error('YouTube home has no client version');
  }

  const watchConfig = asObject(asObject(clientConfig['WEB_PLAYER_CONTEXT_CONFIGS'])
    ?.['WEB_PLAYER_CONTEXT_CONFIG_ID_KEVLAR_WATCH']);
  const experimentFlags = parseExperimentFlags(
    asNonEmptyString(watchConfig?.['serializedExperimentFlags']) ?? '');

  let binding: YoutubePoTokenBinding;
  if (experimentFlags.get('html5_generate_content_po_token') === 'true') {
    binding = 'content';
  } else if (experimentFlags.get('html5_generate_session_po_token') === 'true') {
    binding = 'session';
  } else if (!watchConfig) {
    binding = 'content';
  } else {
    binding = 'none';
  }

  return {
    visitorData: visitorData,
    dataSyncId: dataSyncId,
    clientName: clientName,
    clientVersion: clientVersion,
    binding: binding,
    eventId: eventId,
    challenge: challenge
  };
}

function parseInitialAttestationChallenge(argument: string): SabrAttChallengeData | undefined {
  const responseProperty = INITIAL_ATTESTATION_RESPONSE.exec(argument);
  if (!responseProperty) {
    return undefined;
  }
  const quote = responseProperty[1];
  const rawChallenge = decodeJavascriptString(
    argument, responseProperty.index + responseProperty[0].length, quote);
  if (rawChallenge.length === 0) {
    return undefined;
  }
  try {
    return parseSabrAttChallengeData(rawChallenge);
  } catch (_e) {
    return undefined;
  }
}

export function parseSabrAttChallengeData(rawAttestationData: string): SabrAttChallengeData {
  const root = asObject(JSON.parse(rawAttestationData) as Object);
  const challenge = asObject(root?.['bgChallenge']);
  if (!challenge) {
    throw new Error('Attestation response has no BotGuard challenge');
  }
  const interpreterJavascript = asNonEmptyString(
    asObject(challenge['interpreterJavascript'])?.['privateDoNotAccessOrElseSafeScriptWrappedValue']);
  const rawInterpreterUrl = asNonEmptyString(
    asObject(challenge['interpreterUrl'])?.['privateDoNotAccessOrElseTrustedResourceUrlWrappedValue']);
  let interpreterUrl: string | undefined = undefined;
  if (rawInterpreterUrl) {
    interpreterUrl = rawInterpreterUrl.startsWith('//') ? `https:${rawInterpreterUrl}` : rawInterpreterUrl;
  }
  if (!interpreterJavascript && !interpreterUrl) {
    throw new Error('Attestation challenge has no interpreter script or URL');
  }
  const program = asNonEmptyString(challenge['program']);
  if (!program) {
    throw new Error('Attestation challenge has no program');
  }
  const globalName = asNonEmptyString(challenge['globalName']);
  if (!globalName) {
    throw new Error('Attestation challenge has no global name');
  }
  return {
    program: program,
    globalName: globalName,
    interpreterJavascript: interpreterJavascript,
    interpreterUrl: interpreterUrl
  };
}

function extractObjectCallArguments(source: string, callee: string): JavascriptObjectCall[] {
  const results: JavascriptObjectCall[] = [];
  let searchFrom = 0;
  while (true) {
    const callStart = source.indexOf(callee, searchFrom);
    if (callStart < 0) {
      return results;
    }
    let openingParenthesis = callStart + callee.length;
    while (openingParenthesis < source.length && isWhitespace(source.charAt(openingParenthesis))) {
      openingParenthesis++;
    }
    if (openingParenthesis >= source.length || source.charAt(openingParenthesis) !== '(') {
      searchFrom = callStart + callee.length;
      continue;
    }
    let objectStart = openingParenthesis + 1;
    while (objectStart < source.length && isWhitespace(source.charAt(objectStart))) {
      objectStart++;
    }
    if (objectStart >= source.length || source.charAt(objectStart) !== '{') {
      searchFrom = openingParenthesis + 1;
      continue;
    }
    const objectEnd = findJavascriptObjectEnd(source, objectStart);
    if (objectEnd < 0) {
      searchFrom = objectStart + 1;
      continue;
    }
    results.push({ start: callStart, argument: source.substring(objectStart, objectEnd + 1) });
    searchFrom = objectEnd + 1;
  }
}

function isWhitespace(character: string): boolean {
  return character === ' ' || character === '\t' || character === '\n' || character === '\r'
    || character === '\f' || character === '\v';
}

function findJavascriptObjectEnd(source: string, start: number): number {
  let depth = 0;
  let quote = '';
  let escaped = false;
  for (let index = start; index < source.length; index++) {
    const character = source.charAt(index);
    if (quote !== '') {
      if (escaped) {
        escaped = false;
      } else if (character === '\\') {
        escaped = true;
      } else if (character === quote) {
        quote = '';
      }
      continue;
    }
    if (character === '\'' || character === '"') {
      quote = character;
    } else if (character === '{') {
      depth++;
    } else if (character === '}') {
      depth--;
      if (depth === 0) {
        return index;
      }
    }
  }
  return -1;
}

function parseExperimentFlags(serializedFlags: string): Map<string, string> {
  const flags = new Map<string, string>();
  if (serializedFlags.length === 0) {
    return flags;
  }
  for (const part of serializedFlags.split('&')) {
    const separator = part.indexOf('=');
    if (separator < 0) {
      flags.set(part, 'true');
    } else {
      flags.set(part.substring(0, separator), part.substring(separator + 1));
    }
  }
  return flags;
}

function decodeJavascriptString(source: string, start: number, quote: string): string {
  let result = '';
  let index = start;
  while (index < source.length) {
    const character = source.charAt(index++);
    if (character === quote) {
      return result;
    }
    if (character !== '\\') {
      result += character;
      continue;
    }
    if (index >= source.length) {
      return '';
    }
    const escaped = source.charAt(index++);
    if (escaped === 'b') {
      result += '\b';
    } else if (escaped === 'f') {
      result += '\f';
    } else if (escaped === 'n') {
      result += '\n';
    } else if (escaped === 'r') {
      result += '\r';
    } else if (escaped === 't') {
      result += '\t';
    } else if (escaped === 'v') {
      result += '\v';
    } else if (escaped === 'x') {
      const value = readJavascriptHex(source, index, 2);
      if (value < 0) {
        return '';
      }
      result += String.fromCharCode(value);
      index += 2;
    } else if (escaped === 'u') {
      const value = readJavascriptHex(source, index, 4);
      if (value < 0) {
        return '';
      }
      result += String.fromCharCode(value);
      index += 4;
    } else if (escaped === '\n') {
      // Line continuation: append nothing.
    } else if (escaped === '\r') {
      if (index < source.length && source.charAt(index) === '\n') {
        index++;
      }
    } else {
      result += escaped;
    }
  }
  // Unterminated string: treat as unparseable like PipePipe's IllegalArgumentException.
  return '';
}

function readJavascriptHex(source: string, start: number, length: number): number {
  if (start + length > source.length) {
    return -1;
  }
  let value = 0;
  for (let offset = 0; offset < length; offset++) {
    const digit = parseInt(source.charAt(start + offset), 16);
    if (isNaN(digit)) {
      return -1;
    }
    value = value * 16 + digit;
  }
  return value;
}
