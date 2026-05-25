import { YTCoreLogger } from '../common/YTCoreLogger';
import { ContentCountry } from "../model/ContentCountry";
import { ClientsConstants } from "../model/ClientsConstants";
import { Localization } from "../model/Localization";
import { YoutubeSearchQueryHandlerFactory } from "../common/YoutubeSearchQueryHanderFactory";
import { SearchContentFilter } from "../model/SearchContentFilter";
import { Utils } from "../common/Utils";
import { HttpDownloader } from "../network/HttpDownloader";
import { http } from "@kit.NetworkKit";
import { JSON } from "@kit.ArkTS";

const logger = YTCoreLogger.getInstance('YoutubeApi');

const YOUTUBEI_V1_URL = "https://www.youtube.com/youtubei/v1/";
const YOUTUBE_MUSICI_V1_URL = "https://music.youtube.com/youtubei/v1/";
const DISABLE_PRETTY_PRINT_PARAMETER = "prettyPrint=false";
const YOUTUBE_SUGGEST_URL = "https://suggestqueries-clients6.youtube.com/complete/search?client=youtube&ds=yt&xhr=t";

const REGEX_PATTERNS: Record<string, Array<string>> = {
  "INNERTUBE_CONTEXT_CLIENT_VERSION_REGEXES": [
    'INNERTUBE_CONTEXT_CLIENT_VERSION":"([0-9\\.]+?)"',
    'innertube_context_client_version":"([0-9\\.]+?)"',
    'client.version=([0-9\\.]+)'
  ],
  "INNERTUBE_API_KEY_REGEXES": [
    'INNERTUBE_API_KEY":"([^"]+)"',
    'innertube_api_key":"([^"]+)"',
    'INNERTUBE_API_KEY=\\\\\"([^\\\\\"]+)\\\\\"'
  ]
};

const downloader: HttpDownloader = new HttpDownloader();

function getStringResultFromRegexArray(input: string, regexArray: string[], group: number = 1): string {
  for (let pattern of regexArray) {
    if (!pattern) continue;
    const regex = new RegExp(pattern, "s");
    const match = regex.exec(input);
    if (match && match[group] !== undefined) {
      return match[group];
    }
  }
  return '';
}

async function getClientVersion(localization: Localization): Promise<string> {
  const url: string = "https://www.youtube.com/sw.js";
  const urlList = ["https://www.youtube.com"];
  const referrerHeaders = {
    "Origin": urlList,
    "Referer": urlList
  } as Record<string, string[]>;
  const headers: Record<string, string | string[]> = downloader.processHeaders(referrerHeaders, localization);
  const body: http.HttpResponse = await downloader.request('GET', url, headers, undefined, localization);
  const clientVersion = getStringResultFromRegexArray(
    body.result as string,
    REGEX_PATTERNS['INNERTUBE_CONTEXT_CLIENT_VERSION_REGEXES'],
    1
  );
  return clientVersion === '' ? "2.20251212.01.00" : clientVersion;
}

async function getClientInfoHeaders(localization: Localization): Promise<Record<string, string[]>> {
  const urlList = ["https://www.youtube.com"];
  const headers = {
    "Origin": urlList,
    "Referer": urlList
  } as Record<string, string[]>;

  const clientVersion = await getClientVersion(localization);
  const head = {
    "X-YouTube-Client-Name": [ClientsConstants.WEB_CLIENT_ID],
    "X-YouTube-Client-Version": [clientVersion]
  } as Record<string, string[]>;
  const keys = Object.keys(head);
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i];
    headers[key] = head[key];
  }
  return headers;
}

async function getMusicClientInfoHeaders(localization: Localization): Promise<Record<string, string[]>> {
  const urlList = ["https://music.youtube.com"];
  const headers = {
    "Origin": urlList,
    "Referer": urlList
  } as Record<string, string[]>;

  const clientVersion: string = ClientsConstants.WEB_REMIX_HARDCODED_CLIENT_VERSION;
  headers["X-YouTube-Client-Name"] = [ClientsConstants.WEB_REMIX_CLIENT_ID];
  headers["X-YouTube-Client-Version"] = [clientVersion];
  return headers;
}

async function getYoutubeHeaders(localization: Localization): Promise<Record<string, string[]>> {
  const headers: Record<string, string[]> = {};
  const infoHeaders: Record<string, string[]> = await getClientInfoHeaders(localization);
  Object.entries(infoHeaders).forEach((entry) => {
    const key = entry[0];
    const value = entry[1];
    headers[key] = value;
  });
  headers['Cookie'] = ["SOCS=CAISAiAD"];
  return headers;
}

async function getYoutubeMusicHeaders(localization: Localization): Promise<Record<string, string[]>> {
  const headers: Record<string, string[]> = {};
  const infoHeaders: Record<string, string[]> = await getMusicClientInfoHeaders(localization);
  Object.entries(infoHeaders).forEach((entry) => {
    const key = entry[0];
    const value = entry[1];
    headers[key] = value;
  });
  headers['Cookie'] = ["SOCS=CAISAiAD"];
  return headers;
}

async function prepareDesktopJsonBuilder(
  localization: Localization,
  contentCountry: ContentCountry,
  visitorData?: string
): Promise<Record<string, Object>> {
  const jsonStruct: Record<string, Object> = {
    "context": {
      "client": {
        "hl": localization.getLanguageCode(),
        "gl": contentCountry.getCountryCode(),
        "clientName": ClientsConstants.WEB_CLIENT_NAME,
        "clientVersion": await getClientVersion(localization),
        "originalUrl": "https://www.youtube.com",
        "platform": ClientsConstants.DESKTOP_CLIENT_PLATFORM,
        "utcOffsetMinutes": 0
      } as Record<string, Object>,
      "request": {
        "internalExperimentFlags": [],
        "useSsl": true
      } as Record<string, Object>,
      "user": {
        "lockedSafetyMode": false
      } as Record<string, Object>
    } as Record<string, Object>
  };

  if (visitorData && visitorData.length > 0) {
    const context = jsonStruct["context"] as Record<string, Object>;
    const client = context["client"] as Record<string, Object>;
    client["visitorData"] = visitorData;
  }

  return jsonStruct;
}

async function prepareMusicJsonBuilder(
  localization: Localization,
  contentCountry: ContentCountry
): Promise<Record<string, Object>> {
  return {
    "context": {
      "client": {
        "hl": localization.getLanguageCode(),
        "gl": contentCountry.getCountryCode(),
        "clientName": ClientsConstants.WEB_REMIX_CLIENT_NAME,
        "clientVersion": ClientsConstants.WEB_REMIX_HARDCODED_CLIENT_VERSION,
        "platform": ClientsConstants.DESKTOP_CLIENT_PLATFORM,
        "utcOffsetMinutes": 0
      } as Record<string, Object>,
      "request": {
        "internalExperimentFlags": [],
        "useSsl": true
      } as Record<string, Object>,
      "user": {
        "lockedSafetyMode": false
      } as Record<string, Object>
    } as Record<string, Object>
  };
}

async function getJsonPostResponse(
  endpoint: string,
  body: string,
  localization: Localization,
  apiKey?: string
): Promise<Object | null> {
  const headers = await getYoutubeHeaders(localization);
  const params: string[] = [DISABLE_PRETTY_PRINT_PARAMETER];
  if (apiKey && apiKey.length > 0) {
    params.unshift(`key=${apiKey}`);
  }
  const response: http.HttpResponse = await downloader.post(
    YOUTUBEI_V1_URL + endpoint + '?' + params.join('&'),
    body,
    headers,
    localization,
    "application/json"
  );
  const responseObject = JSON.parse(response.result as string);
  return responseObject;
}

async function getJsonPostResponseMusic(
  url: string,
  body: string,
  localization: Localization
): Promise<Object | null> {
  const headers = await getYoutubeMusicHeaders(localization);
  const response: http.HttpResponse = await downloader.post(
    url,
    body,
    headers,
    localization,
    "application/json"
  );
  const responseObject = JSON.parse(response.result as string);
  return responseObject;
}

function isMusicSearchType(contentFilter: string | null): boolean {
  return !!contentFilter && contentFilter.startsWith('music_');
}

function getMusicSearchParameter(contentFilter: string | null): string {
  switch (contentFilter) {
    case SearchContentFilter.MUSIC_SONGS:
      return "Eg-KAQwIARAAGAAgACgAMABqChAEEAUQAxAKEAk%3D";
    case SearchContentFilter.MUSIC_VIDEOS:
      return "Eg-KAQwIABABGAAgACgAMABqChAEEAUQAxAKEAk%3D";
    case SearchContentFilter.MUSIC_ALBUMS:
      return "Eg-KAQwIABAAGAEgACgAMABqChAEEAUQAxAKEAk%3D";
    case SearchContentFilter.MUSIC_PLAYLISTS:
      return "Eg-KAQwIABAAGAAgACgBMABqChAEEAUQAxAKEAk%3D";
    case SearchContentFilter.MUSIC_ARTISTS:
      return "Eg-KAQwIABAAGAAgASgAMABqChAEEAUQAxAKEAk%3D";
    default:
      return "";
  }
}

export async function fetchSearchPage(
  localization: Localization,
  contentCountry: ContentCountry,
  query: string,
  contentFilters: string[],
  _softFilter: string
): Promise<Object | null> {
  const searchType = contentFilters && contentFilters.length > 0 ? contentFilters[0] : null;
  if (isMusicSearchType(searchType)) {
    const jsonStruct: Record<string, Object> = await prepareMusicJsonBuilder(
      localization,
      contentCountry
    );
    jsonStruct["query"] = query;
    const musicParam = getMusicSearchParameter(searchType);
    if (!Utils.isNullOrEmpty(musicParam)) {
      jsonStruct["params"] = musicParam;
    }
    return getJsonPostResponseMusic(
      YOUTUBE_MUSICI_V1_URL + "search?" + DISABLE_PRETTY_PRINT_PARAMETER,
      JSON.stringify(jsonStruct),
      localization
    );
  }

  const searchParameter: string = YoutubeSearchQueryHandlerFactory.getSearchParameter(searchType);
  const jsonStruct: Record<string, Object> = await prepareDesktopJsonBuilder(
    localization,
    contentCountry
  );
  jsonStruct["query"] = query;
  if (!Utils.isNullOrEmpty(searchParameter)) {
    jsonStruct["params"] = searchParameter;
  }

  return getJsonPostResponse(
    "search",
    JSON.stringify(jsonStruct),
    localization
  );
}

export async function fetchSearchContinuation(
  localization: Localization,
  contentCountry: ContentCountry,
  continuationToken: string,
  contentFilters: string[] = []
): Promise<Object | null> {
  const searchType = contentFilters && contentFilters.length > 0 ? contentFilters[0] : null;
  if (isMusicSearchType(searchType)) {
    const jsonStruct: Record<string, Object> = await prepareMusicJsonBuilder(
      localization,
      contentCountry
    );
    jsonStruct["continuation"] = continuationToken;
    const encoded = encodeURIComponent(continuationToken);
    return getJsonPostResponseMusic(
      YOUTUBE_MUSICI_V1_URL + `search?ctoken=${encoded}&continuation=${encoded}&` + DISABLE_PRETTY_PRINT_PARAMETER,
      JSON.stringify(jsonStruct),
      localization
    );
  }

  const jsonStruct: Record<string, Object> = await prepareDesktopJsonBuilder(
    localization,
    contentCountry
  );
  jsonStruct["continuation"] = continuationToken;

  return getJsonPostResponse(
    "search",
    JSON.stringify(jsonStruct),
    localization
  );
}

export async function fetchBrowsePage(
  localization: Localization,
  contentCountry: ContentCountry,
  browseId: string,
  params: string,
  visitorData?: string
): Promise<Object | null> {
  let id = browseId;
  let ajaxJson: Object | null = null;
  
  let level = 0;
  while (level < 3) {
    const jsonStruct: Record<string, Object> = await prepareDesktopJsonBuilder(
      localization,
      contentCountry,
      visitorData
    );
    jsonStruct["browseId"] = id;
    if (!Utils.isNullOrEmpty(params)) {
      jsonStruct["params"] = params;
    }
    
    const response = await getJsonPostResponse(
      "browse",
      JSON.stringify(jsonStruct),
      localization
    );
    
    if (!response) {
      return null;
    }
    
    // 处理重定向
    const responseObj = response as Record<string, Object>;
    const onResponseReceivedActions = responseObj["onResponseReceivedActions"] as Array<Object>;
    
    if (onResponseReceivedActions && onResponseReceivedActions.length > 0) {
      const firstAction = onResponseReceivedActions[0] as Record<string, Object>;
      const navigateAction = firstAction["navigateAction"] as Record<string, Object>;
      
      if (navigateAction) {
        const endpoint = navigateAction["endpoint"] as Record<string, Object>;
        if (endpoint) {
          const commandMetadata = endpoint["commandMetadata"] as Record<string, Object>;
          if (commandMetadata) {
            const webCommandMetadata = commandMetadata["webCommandMetadata"] as Record<string, Object>;
            if (webCommandMetadata) {
              const webPageType = webCommandMetadata["webPageType"] as string;
              
              const browseEndpoint = endpoint["browseEndpoint"] as Record<string, Object>;
              if (browseEndpoint) {
                const redirectedBrowseId = browseEndpoint["browseId"] as string;
                
                if ((webPageType === "WEB_PAGE_TYPE_BROWSE" || webPageType === "WEB_PAGE_TYPE_CHANNEL") && redirectedBrowseId) {
                  if (redirectedBrowseId.startsWith("UC")) {
                    id = redirectedBrowseId;
                    level++;
                    continue;
                  }
                }
              }
            }
          }
        }
      }
    }
    
    // 检查是否有错误
    const error = responseObj["error"] as Record<string, Object>;
    if (error) {
      logger.error('API错误:', JSON.stringify(error));
      return null;
    }
    
    ajaxJson = response;
    break;
  }
  
  return ajaxJson;
}

export async function fetchBrowseContinuation(
  localization: Localization,
  contentCountry: ContentCountry,
  continuationToken: string,
  visitorData?: string
): Promise<Object | null> {
  const jsonStruct: Record<string, Object> = await prepareDesktopJsonBuilder(
    localization,
    contentCountry,
    visitorData
  );
  jsonStruct["continuation"] = continuationToken;
  return getJsonPostResponse(
    "browse",
    JSON.stringify(jsonStruct),
    localization
  );
}

export async function fetchSearchSuggestions(
  localization: Localization,
  contentCountry: ContentCountry,
  query: string
): Promise<Object | null> {
  const language: string = localization.getLanguageCode();
  const region: string = contentCountry.getCountryCode();
  const url = `${YOUTUBE_SUGGEST_URL}&hl=${encodeURIComponent(language)}&gl=${encodeURIComponent(region)}&q=${encodeURIComponent(query)}`;
  const headers: Record<string, string[]> = {
    "Origin": ["https://www.youtube.com"],
    "Referer": ["https://www.youtube.com"]
  };
  const response: http.HttpResponse = await downloader.request('GET', url, headers, undefined, localization);
  const body = response.result as string;
  return JSON.parse(body);
}

/**
 * 拉取 YouTube RSS Feed（频道或播放列表）。
 * 封装内部 HttpDownloader，供 entry 层订阅模块使用。
 */
export async function fetchRssFeed(url: string): Promise<string> {
  const response: http.HttpResponse = await downloader.request('GET', url);
  return String(response.result ?? '');
}

// fetchPlayerResponse removed with direct-link cleanup.
