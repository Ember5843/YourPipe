// youtube_core 公共出口：显式命名导出（不再 export *）。
// 名单 = entry / mediaservice 的实际消费面；新增跨模块符号时请在此登记。

// ── extractor ──
export { YouTubeExtractor } from './src/main/ets/extractor/YouTubeExtractor';
export { VideoInfo, ChapterInfo, SubtitleTrack } from './src/main/ets/extractor/VideoInfo';
export { buildAutoTranslatedTrack, toYoutubeTlang } from './src/main/ets/extractor/SubtitleTranslate';
export { StreamInfo } from './src/main/ets/extractor/StreamInfo';
export {
  AccountTerminatedException,
  AgeRestrictedContentException,
  ContentNotAvailableException,
  ContentNotSupportedException,
  ExtractionException,
  GeographicRestrictionException,
  LiveStreamOfflineException,
  LoginRequiredException,
  NoPlayableStreamsException,
  PaidContentException,
  PrivateContentException,
  SignInConfirmNotBotException,
  StreamDeobfuscationException,
  YoutubeMusicPremiumContentException
} from './src/main/ets/extractor/YouTubeExceptions';
export { CommentItem, CommentResponse } from './src/main/ets/extractor/CommentItem';
export { parseHlsMasterManifest } from './src/main/ets/extractor/HlsManifestParser';
export { ItagItem } from './src/main/ets/extractor/itag/ItagItem';

// ── sabr（opt-in/debug 路径） ──
export { YoutubeSabrInfo, YoutubeSabrFormatMeta } from './src/main/ets/extractor/sabr/YoutubeSabrInfo';
export { YoutubeSabrSession, setSabrNetworkTrafficSink } from './src/main/ets/extractor/sabr/YoutubeSabrSession';
export { YoutubeSabrStreamState } from './src/main/ets/extractor/sabr/YoutubeSabrStreamState';
export { SabrMediaSegment, SabrSegmentRequest } from './src/main/ets/extractor/sabr/SabrMediaSegment';
export { SabrInfoReloader } from './src/main/ets/extractor/sabr/SabrInfoReloader';
export { SabrPoTokenProvider } from './src/main/ets/extractor/sabr/SabrPoTokenProvider';
export { SabrProtocolException } from './src/main/ets/extractor/sabr/SabrProtocolException';
export { SessionIdentityManager, SessionPoTokenHook } from './src/main/ets/extractor/identity/SessionIdentityManager';

// ── cipher ──
export { YoutubeJavaScriptPlayerManager } from './src/main/ets/extractor/cipher/YoutubeJavaScriptPlayerManager';

// ── common / model ──
export { pickHighestThumbnailUrl } from './src/main/ets/common/YoutubeParsingHelper';
export { WebClientVersionResolver } from './src/main/ets/common/WebClientVersionResolver';
export { YoutubePlayerClientConfig } from './src/main/ets/model/YoutubePlayerClientConfig';
export { Localization } from './src/main/ets/model/Localization';
export { ContentCountry } from './src/main/ets/model/ContentCountry';
export { ClientsConstants } from './src/main/ets/model/ClientsConstants';
export { SearchContentFilter } from './src/main/ets/model/SearchContentFilter';
export { VideoItem } from './src/main/ets/common/VideoModel';
export {
  SearchChannelItem,
  SearchInfoItem,
  SearchInfoType,
  SearchPageResult,
  SearchPlaylistItem,
  SearchStreamItem
} from './src/main/ets/common/SearchResultModel';
export { YTCoreLogger } from './src/main/ets/common/YTCoreLogger';

// ── network / auth ──
export { YouTubeHttpClient } from './src/main/ets/network/YouTubeHttpClient';
export { YOUTUBE_COOKIE_STORAGE_NAME } from './src/main/ets/network/CookieJar';
export { HttpDownloader } from './src/main/ets/network/HttpDownloader';
export { HttpProxyOptions, AppHttpProxySnapshot, AppProxyKind } from './src/main/ets/network/HttpProxyOptions';
export { socks5Bridge } from './src/main/ets/network/Socks5Bridge';
export { AuthAccountStatus, AuthStage } from './src/main/ets/auth/AuthModels';
export { AuthSessionManager, AuthBackupState, AUTH_STORAGE_NAME } from './src/main/ets/auth/AuthSessionManager';
export { CookieAuthCredential } from './src/main/ets/auth/CookieAuthCredential';
export { AuthExpiredError, isAuthRejectionResponse } from './src/main/ets/auth/AuthExpiredError';

// ── service ──
export {
  fetchBrowseContinuation,
  fetchBrowsePage,
  fetchRssFeed,
  fetchSearchContinuation,
  fetchSearchPage,
  fetchSearchSuggestions,
  fetchTvBrowseContinuation,
  fetchTvBrowsePage
} from './src/main/ets/service/YoutubeApi';
