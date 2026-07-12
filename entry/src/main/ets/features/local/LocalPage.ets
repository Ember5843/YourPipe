import { WatchHistoryStore, WatchHistoryItem } from '../../common/WatchHistoryStore';
import { DownloadManager, DownloadTask } from '../../common/DownloadManager';
import { ActionHub } from '../../common/ActionHub';
import { VideoItem } from 'youtube_core';
import { customVibrator } from '../../common/VibratorUtil';
import { UIConfig } from '../../common/AppState';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { DownloadPage } from './DownloadPage';

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
  if (min < 60) return `${min} 分钟前`;
  const h = Math.floor(min / 60);
  if (h < 24) return `${h} 小时前`;
  const d = Math.floor(h / 24);
  return `${d} 天前`;
}

const SYMBOL_FONT_SIZE: number = 16;

@Component
struct HistoryCard {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @Prop item: WatchHistoryItem;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @State isShowContextMenu: boolean = false;
  onOpen: (item: WatchHistoryItem) => void = (_item: WatchHistoryItem) => {};

  private deleteItem(): void {
    WatchHistoryStore.remove(this.item.videoId);
    this.isShowContextMenu = false;
  }

  @Builder
  deleteMenuBuilder() {
    Scroll() {
      Menu() {
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
      .borderRadius(12)
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
        if (this.item.thumbnailUrl && this.item.thumbnailUrl.length > 0) {
          Image(this.item.thumbnailUrl)
            .width(160)
            .height(90)
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
            .backgroundColor('#1A1A1A');
        } else {
          Rect()
            .width(160)
            .height(90)
            .fill('#1A1A1A')
            .radius(6);
        }

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
        .width(160)
        .height(90)
      }
      .width(160)
      .height(90)
      .margin({ right: 12 });

      // ── 文字信息 ──
      Column() {
        Text(this.item.title)
          .fontSize(14)
          .fontColor($r('app.color.yourtube_text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(18)
          .fontWeight(FontWeight.Medium)
          .margin({ bottom: 4 });

        if (this.item.author && this.item.author.length > 0) {
          Text(this.item.author)
            .fontSize(11)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ bottom: 4 });
        }

        Text(formatRelativeTime(this.item.lastWatchedAt))
          .fontSize(11)
          .fontColor($r('app.color.yourtube_text_hint'));
      }
      .layoutWeight(1)
      .height(90)
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start);
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Top)
    .borderRadius(12)
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .shadow({ radius: 4, color: $r('app.color.yourtube_shadow'), offsetX: 0, offsetY: 2 })
    .bindContextMenu(this.isShowContextMenu, this.deleteMenuBuilder, {
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
  @Consume('safeAreaTop') safeAreaTop: number = 0;
  @Consume('safeAreaBottom') safeAreaBottom: number = 0;
  @State currentTabIndex: number = 0;
  @Consume('actionHub') actionHub: ActionHub;
  private downloadManager: DownloadManager = DownloadManager.getInstance();
  private panOptionRight: PanGestureOptions = new PanGestureOptions({ direction: PanDirection.Right });

  private readonly tabTitles: string[] = ['观看记录', '下载'];

  private clearAll(): void {
    WatchHistoryStore.clear();
  }

  private openVideo(item: WatchHistoryItem): void {
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
    this.actionHub.openVideo(video);
  }

  build() {
    Tabs({ barPosition: BarPosition.Start }) {
      // ── Tab 0: 观看记录 ──
      TabContent() {
        List({ space: 8 }) {
          // 标题行
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
            .padding({ top: 16, bottom: 12, left: 4, right: 4 });
          }

          // 空状态
          if (this.history.length === 0) {
            ListItem() {
              Column() {
                SymbolGlyph($r('sys.symbol.clock'))
                  .fontSize(48)
                  .fontColor([$r('app.color.yourtube_text_hint')])
                  .margin({ bottom: 12 });
                Text($r('app.string.yt_empty_no_history'))
                  .fontSize(14)
                  .fontColor($r('app.color.yourtube_text_secondary'));
                Text($r('app.string.yt_empty_history_hint'))
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

          // 历史列表
          ForEach(this.history, (item: WatchHistoryItem) => {
            ListItem() {
              HistoryCard({
                item: item,
                onOpen: (it: WatchHistoryItem) => { this.openVideo(it); }
              })
            }
          }, (item: WatchHistoryItem) => item.videoId + item.lastWatchedAt)
        }
        .width('100%')
        .height('100%')
        .padding({ left: 12, right: 12, bottom: this.safeAreaBottom + 72 })
        .edgeEffect(EdgeEffect.Spring)
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
        .padding({ left: 12, right: 12, bottom: this.safeAreaBottom + 72 })
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
