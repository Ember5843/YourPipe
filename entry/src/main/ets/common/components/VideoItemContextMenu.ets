import { Callback } from '@ohos.base';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { VideoItem } from 'youtube_core';
import { ActionHub } from '../ActionHub';
import { customAnimationUtil } from '../AnimationUtil';
import { UIConfig } from '../AppState';
import { MEDIA_CARD_RADIUS } from './MediaCardTokens';

const SYMBOL_FONT_SIZE: number = 20;
/** 菜单宽度 268vp：大实心图标指标区 + 标准操作列表。 */
const MENU_WIDTH_VP: number = 268;

/** 表面特有菜单项（删除记录 / 从队列移除等），追加在标准项之后。 */
export interface VideoMenuExtraItem {
  symbolStartIcon?: SymbolGlyphModifier;
  content: ResourceStr;
  contentColor?: ResourceColor;
  callback: Callback<void>;
}

interface ContextStatTile {
  key: string;
  icon: Resource;
  value: string;
  accent: boolean;
}

/**
 * 视频条目长按/更多上下文菜单的统一实现：
 * - 顶部信息区：标题/作者 + 无底框大实心图标小数字指标（播放量/时长/发布时间）；
 * - 标准菜单区：收藏/查看作者/纯音频/下载/分享 + 表面特有项（extraItems）。
 */
@Component
export struct VideoItemContextMenu {
  @Prop video: VideoItem;
  @Prop showFavorite: boolean = true;
  @Prop showAudioOnly: boolean = true;
  @Prop showDownload: boolean = true;
  @Prop showShare: boolean = true;
  /** 信息区开关（无视频语义的条目，如历史页的播放列表记录，可关闭）。 */
  @Prop showInfo: boolean = true;
  /** 保留可选关闭回调以兼容宿主调用。 */
  onClose?: () => void;
  /** bindContextMenu 的菜单内容树与宿主同树，@Consume 可正常解析。 */
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  extraItems: VideoMenuExtraItem[] = [];
  @StorageLink('favorites') favorites: VideoItem[] = [];
  @StorageProp('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';

  private getVideoId(): string {
    return (this.video.videoId || '').trim();
  }

  private isFavorited(): boolean {
    const videoId = this.getVideoId();
    if (!videoId) {
      return false;
    }
    return this.favorites.some((item: VideoItem) => item.videoId === videoId);
  }

  /** 播放数展示：缩写文本优先以保持紧凑，缺失时回退精确文本。 */
  private getCompactViewCount(): string {
    if (this.video.viewCount && this.video.viewCount.length > 0) {
      return this.video.viewCount;
    }
    return this.video.viewCountExact || '';
  }

  /** 发布时间（有则非空）。 */
  private getPublishTimeText(): string {
    return this.video.publishedTimeText || '';
  }

  private getStatTiles(): ContextStatTile[] {
    const tiles: ContextStatTile[] = [];
    const views = this.getCompactViewCount();
    if (views.length > 0) {
      tiles.push({ key: 'views', icon: $r('sys.symbol.play_circle_fill'), value: views, accent: true });
    }
    if (this.video.durationText && this.video.durationText.length > 0) {
      tiles.push({ key: 'duration', icon: $r('sys.symbol.clock_fill'), value: this.video.durationText, accent: false });
    }
    const pub = this.getPublishTimeText();
    if (pub.length > 0) {
      tiles.push({ key: 'date', icon: $r('sys.symbol.calendar_fill'), value: pub, accent: false });
    }
    return tiles;
  }

  /** 信息区是否有可显示内容。 */
  private hasContextMenuInfo(): boolean {
    return (!!this.video.title && this.video.title.length > 0)
      || (!!this.video.author && this.video.author.length > 0)
      || this.getStatTiles().length > 0
      || this.getVideoId().length > 0;
  }

  private hasTypeBadges(): boolean {
    return this.video.isLive || this.video.isPremium || this.video.requiresMembership;
  }

  private getMenuItems(): VideoMenuExtraItem[] {
    const items: VideoMenuExtraItem[] = [];
    if (this.showFavorite) {
      const favorited = this.isFavorited();
      items.push({
        symbolStartIcon: new SymbolGlyphModifier(favorited ? $r('sys.symbol.heart_fill') : $r('sys.symbol.heart'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([favorited ? this.themePrimary : $r('sys.color.icon_primary')]),
        content: favorited ? $r('app.string.yt_action_unfavorite') : $r('app.string.yt_action_favorite'),
        contentColor: favorited ? this.themePrimary : $r('sys.color.font_primary'),
        callback: () => {
          const videoId = this.getVideoId();
          if (videoId) {
            if (favorited) {
              this.actionHub.removeFavorite(videoId);
            } else {
              this.actionHub.addFavorite(this.video);
            }
          }
        }
      });
    }
    const channelId = (this.video.channelId || '').trim();
    if (channelId.length > 0) {
      items.push({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.person_crop_circle_fill'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([$r('sys.color.icon_primary')]),
        content: $r('app.string.yt_action_view_author'),
        callback: () => {
          this.actionHub.openChannelById(
            channelId,
            this.video.author || '',
            this.video.channelAvatarUrl || '',
            this.video.channelHandle || ''
          );
        }
      });
    }
    if (this.showAudioOnly) {
      items.push({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.earphone'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([$r('sys.color.icon_primary')]),
        content: $r('app.string.yt_action_audio_only_play'),
        callback: () => {
          this.actionHub.openVideo(this.video, undefined, true);
        }
      });
    }
    if (this.showDownload) {
      items.push({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.arrowshape_down_to_line_fill'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([$r('sys.color.icon_primary')]),
        content: $r('app.string.yt_action_download'),
        callback: () => {
          this.actionHub.downloadVideo(this.video);
        }
      });
    }
    if (this.showShare) {
      items.push({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.share'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([$r('sys.color.icon_primary')]),
        content: $r('app.string.yt_action_share'),
        callback: () => {
          this.actionHub.shareVideo(this.video);
        }
      });
    }
    for (const extra of this.extraItems) {
      items.push(extra);
    }
    return items;
  }

  /** 信息区小标记 chip（直播/付费/会员）。 */
  @Builder
  InfoBadge(label: Resource) {
    Text(label)
      .fontSize(10)
      .fontColor(this.themePrimary)
      .padding({ left: 6, right: 6, top: 1, bottom: 1 })
      .border({ width: 1, color: this.themePrimary, radius: 4 })
  }

  @Builder
  StatTileRow() {
    if (this.getStatTiles().length > 0) {
      Row({ space: 8 }) {
        ForEach(this.getStatTiles(), (tile: ContextStatTile) => {
          Column({ space: 5 }) {
            SymbolGlyph(tile.icon)
              .fontSize(26)
              .fontColor([tile.accent ? this.themePrimary : $r('sys.color.icon_primary')])
            Text(tile.value)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .fontFeature('"tnum" 1')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
          }
          .layoutWeight(1)
          .padding({ left: 2, right: 2, top: 4, bottom: 2 })
          .alignItems(HorizontalAlign.Center)
        }, (tile: ContextStatTile) => tile.key)
      }
      .width('100%')
      .margin({ top: 10 })
    }
  }

  build() {
    Scroll() {
      Column() {
        // 条目信息区（不可点击）：标题 + 作者 + 无底框大实心图标指标 + 角标。
        if (this.showInfo && this.hasContextMenuInfo()) {
          Column() {
            Text(this.video.title)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_primary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .lineHeight(20)
              .width('100%')

            if (this.video.author && this.video.author.length > 0) {
              Row({ space: 4 }) {
                Text(this.video.author)
                  .fontSize(12)
                  .fontColor($r('sys.color.font_secondary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .flexShrink(1)
                if (this.video.uploaderVerified) {
                  SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                    .fontSize(13)
                    .fontColor([$r('sys.color.icon_secondary')])
                }
              }
              .width('100%')
              .margin({ top: 4 })
            }

            this.StatTileRow()

            if (this.hasTypeBadges()) {
              Row({ space: 6 }) {
                if (this.video.isLive) {
                  this.InfoBadge($r('app.string.yt_label_live'))
                }
                if (this.video.isPremium) {
                  this.InfoBadge($r('app.string.yt_label_premium'))
                }
                if (this.video.requiresMembership) {
                  this.InfoBadge($r('app.string.yt_label_members_only'))
                }
              }
              .width('100%')
              .margin({ top: 8 })
            }

            if (this.getVideoId().length > 0) {
              Text(`ID: ${this.getVideoId()}`)
                .fontSize(10)
                .fontColor($r('sys.color.font_tertiary'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 6 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })

          Divider()
            .strokeWidth(0.5)
            .color($r('sys.color.comp_divider'))
        }

        Menu() {
          ForEach(this.getMenuItems(), (item: VideoMenuExtraItem, idx: number) => {
            MenuItem({
              symbolStartIcon: item.symbolStartIcon,
              content: item.content
            })
              .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
              .contentFont({ size: 15, weight: FontWeight.Medium })
              .contentFontColor(item.contentColor ?? $r('sys.color.font_primary'))
              .onClick(() => {
                item.callback();
              });
          }, (_item: VideoMenuExtraItem, idx: number) => `menu_${idx}`);
        }
        .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
        .width('100%')
        .height('auto')
      }
      .backgroundColor(Color.Transparent)
      .borderRadius(MEDIA_CARD_RADIUS)
      .clip(true)
      .width(MENU_WIDTH_VP)
    }
    .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    .edgeEffect(EdgeEffect.Spring)
  }
}
