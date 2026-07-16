import { WatchHistoryStore, WatchHistoryItem } from '../../common/WatchHistoryStore';
import { DownloadManager, DownloadTask } from '../../common/DownloadManager';
import { ActionHub } from '../../common/ActionHub';
import { AuthAccountStatus, AuthSessionManager, VideoItem } from 'youtube_core';
import { customVibrator } from '../../common/VibratorUtil';
import { UIConfig } from '../../common/AppState';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { DownloadPage } from './DownloadPage';
import { MediaThumb } from '../../common/components/MediaThumb';
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
  MEDIA_TITLE_SIZE
} from '../../common/components/MediaCardTokens';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { AppLog } from '../../common/AppLog';

const logger = AppLog.getInstance('LocalPage');

/** 将秒数格式化为 mm:ss 或 hh:mm:ss */
function formatDuration(sec: number): string {
  if (sec <= 0) return '';
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = Math.floor(sec % 60);
  const mm = m.toString().padStart(2, '0');
  const ss = s.toString().padStart(2, '0');
  return h > 0 ? `${h}:${mm}:${ss}` : `${m}:${ss}`;
}

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

const SYMBOL_FONT_SIZE: number = 16;

@Component
struct HistoryCard {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @Prop item: WatchHistoryItem;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @State isShowContextMenu: boolean = false;
  onOpen: (item: WatchHistoryItem) => void = (_item: WatchHistoryItem) => {};

  @Consume('actionHub') actionHub: ActionHub = new ActionHub();

  private toVideoItem(): VideoItem {
    return new VideoItem(
      0,
      this.item.videoId,
      this.item.title,
      this.item.author,
      '',
      this.item.thumbnailUrl,
      false,
      '#1A1A1A',
      this.item.channelId || '',
      this.item.channelAvatarUrl || '',
      this.item.channelHandle || ''
    );
  }

  private deleteItem(): void {
    WatchHistoryStore.remove(this.item.videoId);
    this.isShowContextMenu = false;
  }

  private openAudioOnly(): void {
    this.isShowContextMenu = false;
    this.actionHub.openVideo(this.toVideoItem(), undefined, true);
  }

  @Builder
  historyMenuBuilder() {
    Scroll() {
      Menu() {
        MenuItem({
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.earphone'))
            .fontSize(SYMBOL_FONT_SIZE)
            .fontColor([$r('sys.color.font_primary')]),
          content: $r('app.string.yt_action_audio_only_play')
        })
          .contentFontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.openAudioOnly();
          });
        MenuItem({
          symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.trash'))
            .fontSize(SYMBOL_FONT_SIZE)
            .fontColor([$r('sys.color.font_primary')]),
          content: $r('app.string.yt_action_delete_record')
        })
          .contentFontColor(this.themePrimary)
          .onClick(() => {
            this.deleteItem();
          });
      }
      .backgroundColor($r('app.color.yourtube_bg_surface'))
      .borderRadius(MEDIA_CARD_RADIUS)
      .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
      .width(180)
      .height('auto')
    }
    .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    .edgeEffect(EdgeEffect.Spring)
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
          borderRadiusVp: MEDIA_THUMB_RADIUS
        })

        Column() {
          Blank()

          if (this.item.durationSec > 0) {
            Row() {
              Text(formatDuration(this.item.durationSec))
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

      // ── 文字信息：标题 / 作者 / 时间 分行 ──
      Column() {
        Text(this.item.title)
          .fontSize(MEDIA_TITLE_SIZE)
          .fontColor($r('app.color.yourtube_text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(MEDIA_TITLE_LINE_HEIGHT)
          .fontWeight(FontWeight.Medium)
          .width('100%')
          .margin({ bottom: 2 });

        if (this.item.author && this.item.author.length > 0) {
          Text(this.item.author)
            .fontSize(MEDIA_META_SIZE)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .margin({ bottom: 2 });
        }

        Text(formatRelativeTime(this.item.lastWatchedAt))
          .fontSize(MEDIA_META_SIZE)
          .fontColor($r('app.color.yourtube_text_hint'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
      }
      .layoutWeight(1)
      .constraintSize({ minHeight: MEDIA_LIST_THUMB_HEIGHT })
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start);
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
      previewAnimationOptions: { scale: [1.0, 1.05] },
      placement: Placement.BottomRight,
      aboutToAppear: () => {
        if (this.uiConfig.isVibrate) {
          customVibrator.vibratorTriggerOfHapticClockTimer();
        }
      },
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
          this.isShowContextMenu = true;
        })
    );
  }
}

@Component
export struct LocalPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  onSwitchOuterTab: (index: number) => void = (_index: number) => {};
  @StorageLink('watchHistory') history: WatchHistoryItem[] = [];
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

  private readonly tabTitles: ResourceStr[] = [$r('app.string.yt_local_history'), $r('app.string.yt_download_title')];

  private isSignedIn(): boolean {
    return AuthSessionManager.getInstance()?.isAuthEnabledForUserData() === true;
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

  private openVideo(item: WatchHistoryItem, audioOnly: boolean = false): void {
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
    Tabs({ barPosition: BarPosition.Start }) {
      // ── Tab 0: 观看记录 ──
      TabContent() {
        Refresh({ refreshing: $$this.isSyncingHistory }) {
          List({ space: 8 }) {
            ListItem() {
              Row() {
                Text($r('app.string.yt_local_history'))
                  .fontSize(18)
                  .fontColor($r('app.color.yourtube_text_primary'))
                  .fontWeight(FontWeight.Bold)
                  .layoutWeight(1);

                if (this.history.length > 0) {
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
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ top: 16, bottom: 4, left: 4, right: 4 });
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

            ForEach(this.history, (item: WatchHistoryItem) => {
              ListItem() {
                HistoryCard({
                  item: item,
                  onOpen: (it: WatchHistoryItem) => { this.openVideo(it); }
                })
              }
            }, (item: WatchHistoryItem) => item.videoId)
          }
          .width('100%')
          .height('100%')
          .padding({ left: 12, right: 12, bottom: this.safeAreaBottom + 88 })
          .edgeEffect(EdgeEffect.Spring)
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
              this.onSwitchOuterTab(2);
            }
          })
      )

      // ── Tab 1: 下载 ──
      TabContent() {
        Column() {
          Row() {
            Text($r('app.string.yt_download_title'))
              .fontSize(18)
              .fontColor($r('app.color.yourtube_text_primary'))
              .fontWeight(FontWeight.Bold)
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: 16, bottom: 12, left: 4, right: 4 })

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
    .height('100%')
    .padding({ top: this.safeAreaTop + 56 })
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }

  @Builder
  TabBarBuilder(index: number) {
    Column() {
      Text(this.tabTitles[index])
        .fontSize(16)
        .fontColor(this.currentTabIndex === index
          ? this.themePrimary
          : $r('app.color.yourtube_text_secondary'))
        .fontWeight(this.currentTabIndex === index ? FontWeight.Medium : FontWeight.Normal)
        .margin({ top: 12, bottom: 6 })
      Divider()
        .width(36)
        .strokeWidth(2)
        .color(this.themePrimary)
        .opacity(this.currentTabIndex === index ? 1 : 0)
    }
  }
}
