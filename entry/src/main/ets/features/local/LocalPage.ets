import { WatchHistoryStore, WatchHistoryItem } from '../../common/WatchHistoryStore';
import { DownloadManager, DownloadTask } from '../../common/DownloadManager';
import { ActionHub } from '../../common/ActionHub';
import {
  AuthAccountStatus,
  AuthSessionManager,
  ClientsConstants,
  HttpDownloader,
  SearchPlaylistItem,
  VideoItem,
  WebClientVersionResolver
} from 'youtube_core';
import { UIConfig } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { DownloadPage } from './DownloadPage';
import { MediaThumb } from '../../common/components/MediaThumb';
import { SubTabBarItem } from '../../common/components/SubTabBar';
import { VideoItemContextMenu, VideoMenuExtraItem } from '../../common/components/VideoItemContextMenu';
import {
  MEDIA_CARD_RADIUS,
  MEDIA_CARD_SHADOW_OFFSET_Y,
  MEDIA_CARD_SHADOW_RADIUS,
  MEDIA_LIST_THUMB_GAP,
  MEDIA_LIST_THUMB_HEIGHT,
  MEDIA_LIST_THUMB_WIDTH,
  MEDIA_META_SIZE,
  MEDIA_THUMB_RADIUS,
  MEDIA_TITLE_LINE_HEIGHT,
  MEDIA_TITLE_SIZE,
  TITLE_BAR_HEIGHT
} from '../../common/components/MediaCardTokens';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { getWideListColumnCount } from '../../common/utils/ListLayoutUtils';
import { formatDurationHms } from '../../common/utils/FormatUtils';
import { AppLog } from '../../common/AppLog';
import { LocalScrollCoordinator } from './LocalScrollCoordinator';


const logger = AppLog.getInstance('LocalPage');

/** 格式化相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前 */
function formatRelativeTime(ts: number): ResourceStr {
  const diff = Date.now() - ts;
  const min = Math.floor(diff / 60000);
  if (min < 1) return $r('app.string.yt_time_just_now');
  if (min < 60) return $r('app.string.yt_time_minutes_ago', min);
  const h = Math.floor(min / 60);
  if (h < 24) return $r('app.string.yt_time_hours_ago', h);
  const d = Math.floor(h / 24);
  return $r('app.string.yt_date_days_ago', d);
}

const SYMBOL_FONT_SIZE: number = 20;
const HISTORY_MORE_BTN_SIZE: number = 28;
const HISTORY_META_REFRESH_TTL_MS: number = 60_000;
const historyMetaRefreshAt: Map<string, number> = new Map<string, number>();

interface NextTextRun {
  text?: string;
}

interface NextTextField {
  simpleText?: string;
  runs?: NextTextRun[];
}

interface NextViewCountRenderer {
  shortViewCount?: NextTextField;
  viewCount?: NextTextField;
}

interface NextViewCountWrap {
  videoViewCountRenderer?: NextViewCountRenderer;
}

interface NextPrimaryInfoRenderer {
  title?: NextTextField;
  viewCount?: NextViewCountWrap;
  relativeDateText?: NextTextField;
  dateText?: NextTextField;
}

interface NextBrowseEndpoint {
  browseId?: string;
}

interface NextNavEndpoint {
  browseEndpoint?: NextBrowseEndpoint;
}

interface NextOwnerRenderer {
  title?: NextTextField;
  navigationEndpoint?: NextNavEndpoint;
}

interface NextSecondaryOwner {
  videoOwnerRenderer?: NextOwnerRenderer;
}

interface NextSecondaryInfoRenderer {
  owner?: NextSecondaryOwner;
}

interface NextContentEntry {
  videoPrimaryInfoRenderer?: NextPrimaryInfoRenderer;
  videoSecondaryInfoRenderer?: NextSecondaryInfoRenderer;
}

interface NextInnerResults {
  contents?: NextContentEntry[];
}

interface NextResultsWrap {
  results?: NextInnerResults;
}

interface NextTwoColumnResults {
  results?: NextResultsWrap;
}

interface NextContentsWrap {
  twoColumnWatchNextResults?: NextTwoColumnResults;
}

interface NextResponseRoot {
  contents?: NextContentsWrap;
}

interface NextRequestClient {
  clientName: string;
  clientVersion: string;
  hl: string;
  gl: string;
}

interface NextRequestContext {
  client: NextRequestClient;
}

interface NextRequestPayload {
  videoId: string;
  context: NextRequestContext;
}

function readNextText(field?: NextTextField): string {
  if (!field) {
    return '';
  }
  if (field.simpleText && field.simpleText.length > 0) {
    return field.simpleText.trim();
  }
  if (field.runs && field.runs.length > 0) {
    return field.runs.map((r: NextTextRun): string => r.text || '').join('').trim();
  }
  return '';
}

/**
 * 长按/打开历史条目菜单时后台轻量刷新最新观看次数、发布时间与标题并立即回写历史记录。
 * 独立走无锁 /next 请求（不占用播放器提取互斥锁），带 60s 防抖并继承全局代理。
 */
async function refreshHistoryItemMetadata(videoId: string): Promise<void> {
  const id = (videoId || '').trim();
  if (!id || WatchHistoryStore.playlistIdOf(id).length > 0) {
    return;
  }
  const now = Date.now();
  const last = historyMetaRefreshAt.get(id) ?? 0;
  if (now - last < HISTORY_META_REFRESH_TTL_MS) {
    return;
  }
  historyMetaRefreshAt.set(id, now);
  try {
    const ui = AppStorage.get<UIConfig>('uiConfig');
    const hl = (ui && ui.searchLanguage && ui.searchLanguage !== 'default') ? ui.searchLanguage : 'zh-CN';
    const gl = (ui && ui.searchCountry && ui.searchCountry !== 'default') ? ui.searchCountry : 'US';
    const clientVersion = WebClientVersionResolver.getCachedOrHardcoded();
    const reqClient: NextRequestClient = {
      clientName: ClientsConstants.WEB_CLIENT_NAME,
      clientVersion: clientVersion,
      hl: hl,
      gl: gl
    };
    const reqContext: NextRequestContext = {
      client: reqClient
    };
    const reqPayload: NextRequestPayload = {
      videoId: id,
      context: reqContext
    };
    const body: string = JSON.stringify(reqPayload);
    const downloader = new HttpDownloader();
    const resp = await downloader.post(
      'https://www.youtube.com/youtubei/v1/next?prettyPrint=false',
      body,
      {
        'Content-Type': ['application/json'],
        'User-Agent': [ClientsConstants.WEB_USER_AGENT],
        'X-YouTube-Client-Name': [ClientsConstants.WEB_CLIENT_ID],
        'X-YouTube-Client-Version': [clientVersion]
      }
    );
    if (resp.responseCode !== 200 || typeof resp.result !== 'string') {
      return;
    }
    const root = JSON.parse(resp.result as string) as NextResponseRoot;
    const entries = root?.contents?.twoColumnWatchNextResults?.results?.results?.contents;
    if (!Array.isArray(entries)) {
      return;
    }
    let title = '';
    let viewCount = '';
    let published = '';
    let author = '';
    let channelId = '';
    for (let i = 0; i < entries.length; i++) {
      const entry = entries[i];
      if (entry.videoPrimaryInfoRenderer) {
        const p = entry.videoPrimaryInfoRenderer;
        title = readNextText(p.title);
        const vc = p.viewCount?.videoViewCountRenderer;
        viewCount = readNextText(vc?.shortViewCount) || readNextText(vc?.viewCount);
        published = readNextText(p.relativeDateText) || readNextText(p.dateText);
      }
      if (entry.videoSecondaryInfoRenderer?.owner?.videoOwnerRenderer) {
        const o = entry.videoSecondaryInfoRenderer.owner.videoOwnerRenderer;
        author = readNextText(o.title);
        channelId = o.navigationEndpoint?.browseEndpoint?.browseId || '';
      }
    }
    if (title || viewCount || published || author || channelId) {
      WatchHistoryStore.enrichMetadata(
        id,
        title,
        author,
        '',
        0,
        channelId,
        '',
        '',
        viewCount,
        published,
        ''
      );
      logger.debug(`Refreshed history meta videoId=${id} views=${viewCount} pub=${published}`);
    }
  } catch (e) {
    logger.warn(`refreshHistoryItemMetadata failed videoId=${id}: ${(e as Error).message || e}`);
  }
}

@Component
struct HistoryCard {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop item: WatchHistoryItem;
  @StorageProp('uiConfig') uiConfig: UIConfig = new UIConfig();
  @State isShowContextMenu: boolean = false;
  onOpen: (item: WatchHistoryItem) => void = (_item: WatchHistoryItem) => {};

  private toVideoItem(): VideoItem {
    const v = new VideoItem(
      0,
      this.item.videoId,
      this.item.title,
      this.item.author,
      this.item.viewCount || '',
      this.item.thumbnailUrl,
      false,
      '#1A1A1A',
      this.item.channelId || '',
      this.item.channelAvatarUrl || '',
      this.item.channelHandle || ''
    );
    v.publishedTimeText = this.item.publishedTimeText || '';
    v.durationText = this.item.durationSec > 0
      ? formatDurationHms(this.item.durationSec)
      : (this.item.durationText || '');
    return v;
  }

  private openContextMenu(): void {
    this.isShowContextMenu = true;
    if (!this.isPlaylistEntry()) {
      refreshHistoryItemMetadata(this.item.videoId);
    }
  }

  private deleteItem(): void {
    customAnimationUtil.animateListMutation(this.uiConfig, () => {
      WatchHistoryStore.remove(this.item.videoId);
    }, this.getUIContext());
    this.isShowContextMenu = false;
  }

  private isPlaylistEntry(): boolean {
    return WatchHistoryStore.playlistIdOf(this.item.videoId).length > 0;
  }

  private playlistTypeLabel(): string {
    if (!this.isPlaylistEntry()) {
      return '';
    }
    try {
      return getContext().resourceManager.getStringSync($r('app.string.yt_filter_playlists').id);
    } catch (_e) {
      return '';
    }
  }

  /** 删除记录是历史页的表面特有项，追加在共享菜单标准项之后（主题色强调）。 */
  private buildExtraMenuItems(): VideoMenuExtraItem[] {
    const items: VideoMenuExtraItem[] = [];
    const del: VideoMenuExtraItem = {
      symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.trash'))
        .fontSize(SYMBOL_FONT_SIZE)
        .fontColor([this.themePrimary]),
      content: $r('app.string.yt_action_delete_record'),
      contentColor: this.themePrimary,
      callback: () => {
        this.deleteItem();
      }
    };
    items.push(del);
    return items;
  }

  @Builder
  historyMenuBuilder() {
    // 菜单统一走 VideoItemContextMenu；播放列表来源条目没有单视频语义，
    // 整组关闭视频标准项与信息区，只留"删除记录"。
    VideoItemContextMenu({
      video: this.toVideoItem(),
      showInfo: !this.isPlaylistEntry(),
      showFavorite: !this.isPlaylistEntry(),
      showAudioOnly: !this.isPlaylistEntry(),
      showDownload: !this.isPlaylistEntry(),
      showShare: !this.isPlaylistEntry(),
      extraItems: this.buildExtraMenuItems()
    })
  }

  build() {
    Row() {
      // ── 缩略图区域 ──
      Stack() {
        MediaThumb({
          imageUrl: this.item.thumbnailUrl || '',
          placeholderColor: '#1A1A1A',
          widthVp: MEDIA_LIST_THUMB_WIDTH,
          heightVp: MEDIA_LIST_THUMB_HEIGHT,
          borderRadiusVp: MEDIA_THUMB_RADIUS,
          typeLabel: this.playlistTypeLabel()
        })

        Column() {
          Blank()

          if (this.item.durationSec > 0) {
            Row() {
              Text(formatDurationHms(this.item.durationSec))
                .fontSize(10)
                .fontColor(Color.White)
                .backgroundColor('rgba(0,0,0,0.75)')
                .padding({ left: 4, right: 4, top: 2, bottom: 2 })
                .borderRadius(4)
                .margin({ left: 4, bottom: this.item.progressSec > 0 ? 5 : 4 });
              Blank();
            }
            .width('100%')
          }

          if (this.item.durationSec > 0 && this.item.progressSec > 0) {
            Row() {
              Row()
                .height(3)
                .backgroundColor(this.themePrimary)
                .layoutWeight(Math.min(this.item.progressSec / this.item.durationSec, 1))
              Row()
                .height(3)
                .backgroundColor('rgba(255,255,255,0.3)')
                .layoutWeight(1 - Math.min(this.item.progressSec / this.item.durationSec, 1))
            }
            .width('100%')
          }
        }
        .width(MEDIA_LIST_THUMB_WIDTH)
        .height(MEDIA_LIST_THUMB_HEIGHT)
      }
      .width(MEDIA_LIST_THUMB_WIDTH)
      .height(MEDIA_LIST_THUMB_HEIGHT)
      .margin({ right: MEDIA_LIST_THUMB_GAP });

      // ── 文字信息：通宽标题 + 底部 [作者 / 观看时间 + 右下纯圆三点按钮] ──
      Column() {
        Text(this.item.title)
          .fontSize(MEDIA_TITLE_SIZE)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(MEDIA_TITLE_LINE_HEIGHT)
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .margin({ bottom: 4 });

        Blank()

        Row({ space: 8 }) {
          Column({ space: 2 }) {
            if (this.item.author && this.item.author.length > 0) {
              Text(this.item.author)
                .fontSize(MEDIA_META_SIZE)
                .fontColor($r('sys.color.font_secondary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%');
            }

            Text(formatRelativeTime(this.item.lastWatchedAt))
              .fontSize(MEDIA_META_SIZE)
              .fontColor($r('sys.color.font_tertiary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%');
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Button({ type: ButtonType.Circle, stateEffect: true }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor([$r('sys.color.icon_primary')])
          }
          .width(HISTORY_MORE_BTN_SIZE)
          .height(HISTORY_MORE_BTN_SIZE)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .shadow({
            radius: 4,
            color: '#18000000',
            offsetX: 0,
            offsetY: 1
          })
          .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
          .onClick(() => {
            this.openContextMenu();
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Bottom)
      }
      .layoutWeight(1)
      .height(MEDIA_LIST_THUMB_HEIGHT)
      .alignItems(HorizontalAlign.Start);
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Top)
    .borderRadius(MEDIA_CARD_RADIUS)
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .shadow({
      radius: MEDIA_CARD_SHADOW_RADIUS,
      color: $r('app.color.yourtube_shadow'),
      offsetX: 0,
      offsetY: MEDIA_CARD_SHADOW_OFFSET_Y
    })
    .bindContextMenu(this.isShowContextMenu, this.historyMenuBuilder, {
      preview: MenuPreviewMode.IMAGE,
      previewAnimationOptions: { scale: [1.0, 1.06] },
      placement: Placement.BottomRight,
      enableArrow: false,
      backgroundBlurStyle: BlurStyle.COMPONENT_ULTRA_THICK,
      hapticFeedbackMode: this.uiConfig.isVibrate ? HapticFeedbackMode.ENABLED : HapticFeedbackMode.DISABLED,
      aboutToDisappear: () => {
        this.isShowContextMenu = false;
      }
    })
    .onClick(() => {
      this.onOpen(this.item);
    })
    .gesture(
      LongPressGesture()
        .onAction(() => {
          this.openContextMenu();
        })
    );
  }
}

@Component
export struct LocalPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  onSwitchOuterTab: (index: number) => void = (_index: number) => {};
  @StorageLink('watchHistory') history: WatchHistoryItem[] = [];
  @StorageLink('deviceWidth') deviceWidth: number = 0;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('authStatus') authStatus: AuthAccountStatus = new AuthAccountStatus();
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  @Consume('safeAreaBottom') safeAreaBottom: number = 0;
  @State currentTabIndex: number = 0;
  @State isSyncingHistory: boolean = false;
  @State historySyncMessage: string = '';
  @Consume('actionHub') actionHub: ActionHub;
  private downloadManager: DownloadManager = DownloadManager.getInstance();
  private panOptionRight: PanGestureOptions = new PanGestureOptions({ direction: PanDirection.Right });

  private readonly tabTitles: ResourceStr[] = [
    $r('app.string.yt_local_history'),
    $r('app.string.yt_local_media')
  ];

  private isSignedIn(): boolean {
    return AuthSessionManager.getInstance()?.hasAuthForUserData() === true;
  }

  /** Refresh($$isRefreshing) 已把 isSyncingHistory 置 true；此处只干活并 finally 复位。 */
  private async syncCloudHistory(): Promise<void> {
    this.historySyncMessage = '';
    if (!this.isSignedIn()) {
      this.historySyncMessage = getContext().resourceManager.getStringSync($r('app.string.yt_history_sync_sign_in').id);
      this.isSyncingHistory = false;
      return;
    }
    try {
      const service = FeedServiceProvider.getInstance().getUserLibraryService();
      const page = await service.fetchWatchHistory(1);
      if (page.items.length > 0) {
        WatchHistoryStore.mergeRemoteHistory(service.toWatchHistoryItems(page.items));
        this.historySyncMessage = getContext().resourceManager.getStringSync(
          $r('app.string.yt_history_sync_success').id, page.items.length);
      } else {
        this.historySyncMessage = getContext().resourceManager.getStringSync($r('app.string.yt_history_sync_empty').id);
      }
    } catch (err) {
      logger.error('syncCloudHistory failed:', JSON.stringify(err));
      this.historySyncMessage = getContext().resourceManager.getStringSync($r('app.string.yt_history_sync_failed').id);
    } finally {
      this.isSyncingHistory = false;
    }
  }

  private clearAll(): void {
    WatchHistoryStore.clear();
  }

  /** 条式历史列表在宽屏（平板展开/2in1/电视）下的列数 */
  private getWideListColumns(): number {
    const widthPx = this.deviceWidth > 0 ? this.deviceWidth : this.getUIContext().vp2px(360);
    const contentWidth = Math.max(320, this.getUIContext().px2vp(widthPx) - 24);
    return getWideListColumnCount(contentWidth);
  }

  private openVideo(item: WatchHistoryItem, audioOnly: boolean = false): void {
    // 播放列表来源的历史：点击打开对应列表
    const playlistId = WatchHistoryStore.playlistIdOf(item.videoId);
    if (playlistId) {
      this.actionHub.openPlaylist(
        new SearchPlaylistItem(0, playlistId, item.title, '', '', item.thumbnailUrl, '', '#1A1A1A'));
      return;
    }
    const video = new VideoItem(
      0,
      item.videoId,
      item.title,
      item.author,
      '',
      item.thumbnailUrl,
      false,
      '#1A1A1A',
      item.channelId || '',
      item.channelAvatarUrl || '',
      item.channelHandle || ''
    );
    this.actionHub.openVideo(video, undefined, audioOnly);
  }

  build() {
    // 对标 UserPage：外层 Scroll 收口，上滑时"观看历史/下载视频"Tab 栏跟随内容
    // 上移（原为 Tabs padding top 避让，Tab 栏钉在标题栏下方不动）；顶部 spacer
    // 负责避让状态栏 + 标题栏。外层 Scroller 经 LocalScrollCoordinator 暴露给
    // Index 根标题栏 bindToScrollable，滚动渐变/材质效果与首页一致。
    Scroll(LocalScrollCoordinator.scroller) {
      Column() {
        Row().width('100%').height(this.safeAreaTop + TITLE_BAR_HEIGHT)
        Tabs({ barPosition: BarPosition.Start }) {
      // ── Tab 0: 观看记录 ──
      TabContent() {
        Refresh({ refreshing: $$this.isSyncingHistory }) {
          List({ space: 8 }) {
            ListItem() {
              if (this.history.length > 0) {
                Row() {
                  Text($r('app.string.yt_action_clear_all'))
                    .fontSize(13)
                    .fontColor($r('app.color.yourtube_text_hint'))
                    .onClick(() => {
                      AlertDialog.show({
                        title: $r('app.string.yt_dialog_clear_history'),
                        message: $r('app.string.yt_confirm_clear_history'),
                        primaryButton: {
                          value: $r('app.string.yt_action_clear'),
                          fontColor: this.themePrimary,
                          action: () => { this.clearAll(); }
                        },
                        secondaryButton: {
                          value: $r('app.string.yt_action_cancel'),
                          action: () => {}
                        }
                      });
                    });
                }
                .width('100%')
                .justifyContent(FlexAlign.End)
                .padding({ top: 16, bottom: 4, left: 4, right: 4 });
              }
            }

            ListItem() {
              Text(this.historySyncMessage.length > 0
                ? this.historySyncMessage
                : (this.isSignedIn() ? $r('app.string.yt_history_sync_pull_hint') : $r('app.string.yt_history_sync_sign_in_hint')))
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
                .padding({ left: 4, right: 4, bottom: 8 });
            }

            if (this.history.length === 0) {
              ListItem() {
                Column() {
                  SymbolGlyph($r('sys.symbol.worldclock'))
                    .fontSize(48)
                    .fontColor([$r('app.color.yourtube_text_hint')])
                    .margin({ bottom: 12 });
                  Text($r('app.string.yt_empty_no_history'))
                    .fontSize(14)
                    .fontColor($r('app.color.yourtube_text_secondary'));
                  Text(this.isSignedIn()
                    ? $r('app.string.yt_history_sync_signed_in_hint')
                    : $r('app.string.yt_empty_history_hint'))
                    .fontSize(12)
                    .fontColor($r('app.color.yourtube_text_hint'))
                    .margin({ top: 4 });
                }
                .width('100%')
                .alignItems(HorizontalAlign.Center)
                .justifyContent(FlexAlign.Center)
                .padding({ top: 60, bottom: 40 });
              }
            }

            if (this.getWideListColumns() > 1) {
              ListItem() {
                GridRow({
                  columns: this.getWideListColumns(),
                  gutter: { x: 8, y: 8 }
                }) {
                  ForEach(this.history, (item: WatchHistoryItem) => {
                    GridCol({ span: 1 }) {
                      HistoryCard({
                        item: item,
                        onOpen: (it: WatchHistoryItem) => { this.openVideo(it); }
                      })
                    }
                    .transition(customAnimationUtil.listItemCrudTransition(this.uiConfig))
                  }, (item: WatchHistoryItem) => item.videoId)
                }
                .width('100%')
              }
            } else {
              ForEach(this.history, (item: WatchHistoryItem) => {
                ListItem() {
                  HistoryCard({
                    item: item,
                    onOpen: (it: WatchHistoryItem) => { this.openVideo(it); }
                  })
                }
                .transition(customAnimationUtil.listItemCrudTransition(this.uiConfig))
              }, (item: WatchHistoryItem) => item.videoId)
            }
          }
          .width('100%')
          .height('100%')
          .padding({ left: 12, right: 12, bottom: this.safeAreaBottom + 88 })
          .edgeEffect(EdgeEffect.Spring)
          // 外层 Scroll 先消费上滑（Tab 栏跟随上移），到顶后列表自身再滚（对标 UserPage）
          .nestedScroll({ scrollForward: NestedScrollMode.PARENT_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
        }
        .width('100%')
        .height('100%')
        .pullToRefresh(true)
        .refreshOffset(64)
        .onRefreshing(() => {
          this.syncCloudHistory();
        })
      }
      .tabBar(this.TabBarBuilder(0))
      .gesture(
        PanGesture(this.panOptionRight)
          .onActionEnd(() => {
            if (this.currentTabIndex === 0) {
              this.onSwitchOuterTab(3);
            }
          })
      )

      // ── Tab 1: 下载 ──
      TabContent() {
        Column() {
          DownloadPage()
        }
        .width('100%')
        .height('100%')
        .padding({ left: 12, right: 12, bottom: this.safeAreaBottom + 88 })
      }
      .tabBar(this.TabBarBuilder(1))
    }
    .barMode(BarMode.Fixed)
    .barWidth('100%')
    .barHeight(48)
    .scrollable(true)
    .animationDuration(200)
    .onAnimationStart((index: number, targetIndex: number) => {
      this.currentTabIndex = targetIndex;
    })
    .width('100%')
      }
    }
    .scrollBar(BarState.Off)
    .clip(false)
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }

  @Builder
  TabBarBuilder(index: number) {
    SubTabBarItem({ label: this.tabTitles[index], selected: this.currentTabIndex === index, themePrimary: this.themePrimary })
  }
}
