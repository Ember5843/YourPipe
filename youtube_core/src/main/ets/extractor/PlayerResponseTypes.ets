/**
 * YouTube Player Response 类型定义
 * 对应 Python: ytInitialPlayerResponse JSON 结构
 */

/**
 * 视频详情
 * 对应: player_response["videoDetails"]
 */
export interface VideoDetails {
  videoId?: string;
  title?: string;
  lengthSeconds?: string;
  keywords?: string[];
  channelId?: string;
  isOwnerViewing?: boolean;
  isCrawlable?: boolean;
  thumbnail?: ThumbnailData;
  allowRatings?: boolean;
  viewCount?: string;
  author?: string;
  isPrivate?: boolean;
  isUnpluggedCorpus?: boolean;
  isLiveContent?: boolean;
  /** PipePipe setStreamType: primary LIVE_STREAM signal (present on visionos
   * GAPIS responses that carry no microformat block). */
  isLive?: boolean;
  /** PipePipe setStreamType: POST_LIVE_STREAM signal (DVR replay of an ended live). */
  isPostLiveDvr?: boolean;
  shortDescription?: string;
}

/**
 * 缩略图数据
 * 对应: videoDetails["thumbnail"]
 */
export interface ThumbnailData {
  thumbnails?: ThumbnailItem[];
}

export interface ThumbnailItem {
  url?: string;
  width?: number;
  height?: number;
}

/**
 * Microformat 渲染器
 * 对应: player_response["microformat"]["playerMicroformatRenderer"]
 */
export interface PlayerMicroformatRenderer {
  thumbnail?: ThumbnailData;
  embed?: EmbedData;
  title?: TextRuns;
  description?: TextRuns;
  lengthSeconds?: string;
  ownerProfileUrl?: string;
  externalChannelId?: string;
  isFamilySafe?: boolean;
  availableCountries?: string[];
  isUnlisted?: boolean;
  hasYpcMetadata?: boolean;
  viewCount?: string;
  category?: string;
  publishDate?: string;
  ownerChannelName?: string;
  uploadDate?: string;
  isShortsEligible?: boolean;
  tags?: string[];
  liveBroadcastDetails?: LiveBroadcastDetails;
}

export interface EmbedData {
  iframeUrl?: string;
  flashUrl?: string;
  width?: number;
  height?: number;
  flashSecureUrl?: string;
}

interface GeneratedTypeLiteralInterface_1 {
  text?: string;
}

export interface TextRuns {
  simpleText?: string;
  runs?: Array<GeneratedTypeLiteralInterface_1>;
}

export interface LiveBroadcastDetails {
  isLiveNow?: boolean;
  startTimestamp?: string;
  endTimestamp?: string;
}

/**
 * 故事板
 * 对应: player_response["storyboards"]["playerStoryboardSpecRenderer"]
 */
export interface PlayerStoryboardSpecRenderer {
  spec?: string;
  url?: string;
}

/**
 * 章节
 * 对应: player_response["chapters"]
 */
export interface Chapter {
  title?: TextRuns;
  timeRangeStartMillis?: number;
  thumbnail?: ThumbnailData;
}

/**
 * 字幕轨道
 * 对应: player_response["captions"]["playerCaptionsTracklistRenderer"]
 */
export interface PlayerCaptionsTracklistRenderer {
  captionTracks?: CaptionTrack[];
  audioTracks?: AudioTrack[];
  translationLanguages?: TranslationLanguage[];
  defaultAudioTrackIndex?: number;
}

export interface CaptionTrack {
  baseUrl?: string;
  name?: TextRuns;
  vssId?: string;
  languageCode?: string;
  kind?: string;
  isTranslatable?: boolean;
}

export interface AudioTrack {
  captionTrackIndices?: number[];
  defaultCaptionTrackIndex?: number;
  visibility?: string;
  hasDefaultTrack?: boolean;
}

export interface TranslationLanguage {
  languageCode?: string;
  languageName?: TextRuns;
}

/**
 * 流媒体数据
 * 对应: player_response["streamingData"]
 */
export interface StreamingData {
  expiresInSeconds?: string;
  formats?: Format[];
  adaptiveFormats?: Format[];
  dashManifestUrl?: string;
  hlsManifestUrl?: string;
  /** SABR session URL (PipePipe serverAbrStreamingUrl). */
  serverAbrStreamingUrl?: string;
}

export interface Format {
  itag?: number;
  url?: string;
  mimeType?: string;
  bitrate?: number;
  width?: number;
  height?: number;
  lastModified?: string;
  contentLength?: string;
  quality?: string;
  fps?: number;
  qualityLabel?: string;
  projectionType?: string;
  averageBitrate?: number;
  audioQuality?: string;
  approxDurationMs?: string;
  audioSampleRate?: string;
  audioChannels?: number;
  signatureCipher?: string;
  cipher?: string;
  initRange?: Range;
  indexRange?: Range;
  isOtf?: boolean;
  type?: string;
  audioTrack?: AudioTrackInfo;
  /** SABR / adaptiveFormat opaque tags (e.g. audio track type). */
  xtags?: string;
}

export interface AudioTrackInfo {
  id?: string;
  displayName?: string;
  audioIsDefault?: boolean;
}

export interface Range {
  start?: string;
  end?: string;
}

/**
 * MIME 类型解析结果
 */
export interface MimeTypeParseResult {
  container: string | undefined;
  codecs: string | undefined;
}

/**
 * 播放跟踪器
 * 对应: player_response["playbackTracking"]
 */
export interface PlaybackTracking {
  videostatsPlaybackUrl?: TrackingUrl;
  videostatsDelayplayUrl?: TrackingUrl;
  videostatsWatchtimeUrl?: TrackingUrl;
  videostatsScheduledFlushWalltimeSeconds?: number[];
  videostatsDefaultFlushIntervalSeconds?: number;
}

export interface TrackingUrl {
  baseUrl?: string;
}

/**
 * 视频质量推广
 * 对应: player_response["videoQualityPromoSupportedRenderers"]
 */
export interface VideoQualityPromoSupportedRenderers {
  videoQualityPromoRenderer?: VideoQualityPromoRenderer;
}

export interface VideoQualityPromoRenderer {
  triggerCriteria?: TriggerCriteria;
  text?: TextRuns;
  endpoint?: Endpoint;
  trackingParams?: string;
  snackbar?: Snackbar;
}

export interface TriggerCriteria {
  videoQualityPromoTriggerType?: string;
}

export interface Endpoint {
  clickTrackingParams?: string;
  commandMetadata?: CommandMetadata;
  urlEndpoint?: URLEndpoint;
}

export interface CommandMetadata {
  webCommandMetadata?: WebCommandMetadata;
}

export interface WebCommandMetadata {
  url?: string;
  webPageType?: string;
  rootVe?: number;
}

export interface URLEndpoint {
  url?: string;
  target?: string;
}

export interface Snackbar {
  text?: TextRuns;
  actionButton?: ActionButton;
}

export interface ActionButton {
  buttonRenderer?: ButtonRenderer;
}

export interface ButtonRenderer {
  style?: string;
  size?: string;
  isDisabled?: boolean;
  text?: TextRuns;
  trackingParams?: string;
  command?: Command;
}

export interface Command {
  clickTrackingParams?: string;
  commandMetadata?: CommandMetadata;
  urlEndpoint?: URLEndpoint;
}

/**
 * 播放器配置
 * 对应: player_response["playerConfig"]
 */
export interface PlayerConfig {
  audioConfig?: AudioConfig;
  streamSelectionConfig?: StreamSelectionConfig;
  mediaCommonConfig?: MediaCommonConfig;
  webPlayerConfig?: WebPlayerConfig;
}

export interface AudioConfig {
  loudnessDb?: number;
  perceptualLoudnessDb?: number;
  enablePerFormatLoudness?: boolean;
}

export interface StreamSelectionConfig {
  maxBitrate?: string;
}

export interface MediaCommonConfig {
  dynamicReadaheadConfig?: DynamicReadaheadConfig;
  mediaUstreamerRequestConfig?: MediaUstreamerRequestConfig;
}

export interface MediaUstreamerRequestConfig {
  videoPlaybackUstreamerConfig?: string;
}

export interface DynamicReadaheadConfig {
  maxReadAheadMediaTimeMs?: number;
  minReadAheadMediaTimeMs?: number;
  readAheadGrowthRateMs?: number;
}

export interface WebPlayerConfig {
  useCobaltTvosDash?: boolean;
  webPlayerActionsPorting?: WebPlayerActionsPorting;
}

export interface WebPlayerActionsPorting {
  getSharePanelCommand?: GetSharePanelCommand;
  subscribeCommand?: SubscribeCommand;
}

export interface GetSharePanelCommand {
  clickTrackingParams?: string;
  commandMetadata?: CommandMetadata;
  webPlayerShareEntityServiceEndpoint?: WebPlayerShareEntityServiceEndpoint;
}

export interface WebPlayerShareEntityServiceEndpoint {
  serializedShareEntity?: string;
}

export interface SubscribeCommand {
  clickTrackingParams?: string;
  commandMetadata?: CommandMetadata;
  subscribeEndpoint?: SubscribeEndpoint;
}

export interface SubscribeEndpoint {
  channelIds?: string[];
  params?: string;
}

/**
 * 字幕容器
 */
export interface CaptionsContainer {
  playerCaptionsTracklistRenderer?: PlayerCaptionsTracklistRenderer;
}

/**
 * 故事板容器
 */
export interface StoryboardsContainer {
  playerStoryboardSpecRenderer?: PlayerStoryboardSpecRenderer;
}

/**
 * Microformat 容器
 */
export interface MicroformatContainer {
  playerMicroformatRenderer?: PlayerMicroformatRenderer;
}

/**
 * 卡片容器
 */
export interface CardsContainer {
  cardCollectionRenderer?: CardCollectionRenderer;
}

/**
 * 完整的 Player Response
 * 对应: ytInitialPlayerResponse
 */
export interface PlayerResponse {
  responseContext?: ResponseContext;
  trackingParams?: string;
  playabilityStatus?: PlayabilityStatus;
  streamingData?: StreamingData;
  playbackTracking?: PlaybackTracking;
  captions?: CaptionsContainer;
  videoDetails?: VideoDetails;
  playerConfig?: PlayerConfig;
  storyboards?: StoryboardsContainer;
  microformat?: MicroformatContainer;
  cards?: CardsContainer;
  videoQualityPromoSupportedRenderers?: VideoQualityPromoSupportedRenderers;
  chapters?: Chapter[];
  frameworkUpdates?: FrameworkUpdates;
}

export interface ResponseContext {
  visitorData?: string;
  serviceTrackingParams?: ServiceTrackingParam[];
  maxAgeSeconds?: number;
  webResponseContextExtensionData?: WebResponseContextExtensionData;
}

export interface ServiceTrackingParam {
  service?: string;
  params?: Param[];
}

export interface Param {
  key?: string;
  value?: string;
}

export interface WebResponseContextExtensionData {
  hasDecorated?: boolean;
}

export interface PlayabilityStatus {
  status?: string;
  /** Direct reason string (WEB metadata /player often returns this instead of errorScreen runs). */
  reason?: string;
  /** Age-gate flag on desktop WEB player responses (PipePipe getWebPlayerResponse). */
  desktopLegacyAgeGateReason?: number | string | boolean;
  playableInEmbed?: boolean;
  miniplayer?: Miniplayer;
  /** Presence marks live-streamability (PipePipe setStreamType LIVE_STREAM branch). */
  liveStreamability?: Record<string, Object>;
  contextParams?: string;
  errorScreen?: ErrorScreen;
}

export interface Miniplayer {
  miniplayerRenderer?: MiniplayerRenderer;
}

export interface MiniplayerRenderer {
  playbackMode?: string;
}

export interface ErrorScreen {
  playerErrorMessageRenderer?: PlayerErrorMessageRenderer;
}

export interface PlayerErrorMessageRenderer {
  reason?: TextRuns;
  subreason?: TextRuns;
  thumbnail?: ThumbnailData;
  icon?: Icon;
}

export interface Icon {
  iconType?: string;
}

export interface CardCollectionRenderer {
  cards?: Card[];
  headerText?: TextRuns;
  icon?: Icon;
  closeButton?: ButtonRenderer;
  trackingParams?: string;
}

export interface Card {
  cardRenderer?: CardRenderer;
}

export interface CardRenderer {
  teaser?: Teaser;
  content?: Content;
  trackingParams?: string;
}

export interface Teaser {
  simpleCardTeaserRenderer?: SimpleCardTeaserRenderer;
}

export interface SimpleCardTeaserRenderer {
  message?: TextRuns;
  trackingParams?: string;
  prominent?: boolean;
}

export interface Content {
  simpleCardContentRenderer?: SimpleCardContentRenderer;
}

export interface SimpleCardContentRenderer {
  title?: TextRuns;
  trackingParams?: string;
}

export interface FrameworkUpdates {
  entityBatchUpdate?: EntityBatchUpdate;
}

export interface EntityBatchUpdate {
  mutations?: Mutation[];
  timestamp?: Timestamp;
}

export interface Mutation {
  entityKey?: string;
  type?: string;
  payload?: Payload;
}

export interface Payload {
  offlineabilityEntity?: OfflineabilityEntity;
}

export interface OfflineabilityEntity {
  key?: string;
  addToOfflineButtonState?: string;
}

export interface Timestamp {
  seconds?: string;
  nanos?: number;
}

// ─── nextResponse 타입 (PipePipe nextResponse 대응) ───────────────────────────

export interface NextResponseThumbnailItem {
  url?: string;
  width?: number;
  height?: number;
}

export interface NextResponseTextRun {
  text?: string;
}

export interface NextResponseText {
  simpleText?: string;
  runs?: Array<NextResponseTextRun>;
}

export interface ThumbnailDataWrapper {
  thumbnails?: NextResponseThumbnailItem[];
}

export interface MetadataBadgeRenderer {
  label?: string;
}

export interface BadgeItem {
  metadataBadgeRenderer?: MetadataBadgeRenderer;
}

export interface WatchEndpoint {
  videoId?: string;
  startTimeSeconds?: number;
}

export interface InnertubeCommand {
  watchEndpoint?: WatchEndpoint;
}

export interface OnTap {
  innertubeCommand?: InnertubeCommand;
  watchEndpoint?: WatchEndpoint;
}

export interface CommandContext {
  onTap?: OnTap;
}

export interface RendererContext {
  commandContext?: CommandContext;
}

export interface TitleContent {
  content?: string;
}

export interface TextContent {
  content?: string;
}

export interface MetadataPart {
  text?: TextContent;
}

export interface MetadataRow {
  metadataParts?: MetadataPart[];
}

export interface ContentMetadataViewModel {
  metadataRows?: MetadataRow[];
}

export interface LockupMetadataInner {
  contentMetadataViewModel?: ContentMetadataViewModel;
}

export interface LockupMetadataViewModel {
  title?: TitleContent;
  metadata?: LockupMetadataInner;
}

export interface LockupMetadata {
  lockupMetadataViewModel?: LockupMetadataViewModel;
}

export interface ImageSources {
  sources?: NextResponseThumbnailItem[];
}

export interface ThumbnailViewModel {
  image?: ImageSources;
}

export interface LockupThumbnail {
  thumbnailViewModel?: ThumbnailViewModel;
}

export interface BrowseEndpoint {
  browseId?: string;
}

export interface NavigationEndpoint {
  browseEndpoint?: BrowseEndpoint;
  showDialogCommand?: object;
}

export interface VideoOwnerRendererWrapper {
  videoOwnerRenderer?: VideoOwnerRenderer;
}

export interface MetadataRowRenderer {
  title?: NextResponseText;
  contents?: NextResponseText[];
}

export interface MetadataRowItem {
  metadataRowRenderer?: MetadataRowRenderer;
}

export interface MetadataRowContainerRenderer {
  rows?: MetadataRowItem[];
}

export interface MetadataRowContainer {
  metadataRowContainerRenderer?: MetadataRowContainerRenderer;
}

export interface VideoViewCountRenderer {
  viewCount?: NextResponseText;
  shortViewCount?: NextResponseText;
}

export interface ViewCount {
  videoViewCountRenderer?: VideoViewCountRenderer;
}

export interface ButtonViewModel {
  accessibilityText?: string;
}

export interface DefaultButtonViewModel {
  buttonViewModel?: ButtonViewModel;
}

export interface ToggleButtonViewModelInner {
  defaultButtonViewModel?: DefaultButtonViewModel;
}

export interface ToggleButtonViewModelOuter {
  toggleButtonViewModel?: ToggleButtonViewModelInner;
}

export interface LikeButtonViewModelInner {
  toggleButtonViewModel?: ToggleButtonViewModelOuter;
}

export interface LikeButtonViewModelOuter {
  likeButtonViewModel?: LikeButtonViewModelInner;
}

export interface SegmentedLikeDislikeButtonViewModel {
  likeButtonViewModel?: LikeButtonViewModelOuter;
}

export interface TopLevelButton {
  segmentedLikeDislikeButtonViewModel?: SegmentedLikeDislikeButtonViewModel;
}

export interface MenuRenderer {
  topLevelButtons?: TopLevelButton[];
}

export interface VideoActions {
  menuRenderer?: MenuRenderer;
}

export interface ResultsContents {
  videoPrimaryInfoRenderer?: VideoPrimaryInfoRenderer;
  videoSecondaryInfoRenderer?: VideoSecondaryInfoRenderer;
}

export interface ResultsInnerInner {
  contents?: ResultsContents[];
}

export interface ResultsInner {
  results?: ResultsInnerInner;
}

export interface SecondaryResultsInner {
  results?: SecondaryResultItem[];
}

export interface SecondaryResults {
  secondaryResults?: SecondaryResultsInner;
}

export interface TwoColumnWatchNextResults {
  results?: ResultsInner;
  secondaryResults?: SecondaryResults;
}

export interface Contents {
  twoColumnWatchNextResults?: TwoColumnWatchNextResults;
}

export interface MacroMarkersListItemRenderer {
  title?: NextResponseText;
  onTap?: OnTap;
}

export interface MacroMarkersListContent {
  macroMarkersListItemRenderer?: MacroMarkersListItemRenderer;
}

export interface MacroMarkersListRenderer {
  contents?: MacroMarkersListContent[];
}

export interface EngagementPanelContent {
  macroMarkersListRenderer?: MacroMarkersListRenderer;
}

export interface EngagementPanelSectionListRenderer {
  panelIdentifier?: string;
  content?: EngagementPanelContent;
}

export interface EngagementPanel {
  engagementPanelSectionListRenderer?: EngagementPanelSectionListRenderer;
}

/** compactVideoRenderer (추천 동영상 항목) */
export interface CompactVideoRenderer {
  videoId?: string;
  title?: NextResponseText;
  longBylineText?: NextResponseText;
  shortBylineText?: NextResponseText;
  thumbnail?: ThumbnailDataWrapper;
  lengthText?: NextResponseText;
  viewCountText?: NextResponseText;
  shortViewCountText?: NextResponseText;
  publishedTimeText?: NextResponseText;
  badges?: Array<BadgeItem>;
  channelId?: string;
  ownerText?: NextResponseText;
}

/** lockupViewModel (신형 추천 항목) */
export interface LockupViewModel {
  contentType?: string;
  contentId?: string;
  rendererContext?: RendererContext;
  metadata?: LockupMetadata;
  thumbnail?: LockupThumbnail;
}

export interface SecondaryResultItem {
  compactVideoRenderer?: CompactVideoRenderer;
  lockupViewModel?: LockupViewModel;
}

/** videoOwnerRenderer (업로더 정보) */
export interface VideoOwnerRenderer {
  thumbnail?: ThumbnailDataWrapper;
  title?: NextResponseText;
  subscriberCountText?: NextResponseText;
  navigationEndpoint?: NavigationEndpoint;
  badges?: Array<object>;
}

/** videoSecondaryInfoRenderer */
export interface VideoSecondaryInfoRenderer {
  owner?: VideoOwnerRendererWrapper;
  description?: NextResponseText;
  metadataRowContainer?: MetadataRowContainer;
}

/** videoPrimaryInfoRenderer */
export interface VideoPrimaryInfoRenderer {
  title?: NextResponseText;
  viewCount?: ViewCount;
  videoActions?: VideoActions;
  dateText?: NextResponseText;
}

/** nextResponse 최상위 구조 */
export interface NextResponse {
  contents?: Contents;
  engagementPanels?: EngagementPanel[];
}
