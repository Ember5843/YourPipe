import { Callback } from '@ohos.base';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import { VideoItem } from 'youtube_core';
import { ActionHub } from '../ActionHub';
import { customAnimationUtil } from '../AnimationUtil';
import { UIConfig } from '../AppState';
import { MEDIA_CARD_RADIUS } from './MediaCardTokens';

const SYMBOL_FONT_SIZE: number = 16;
/** 菜单宽度统一 220vp（VideoMediaCard 确立的标准；原 180vp 的自定义菜单均已废弃）。 */
const MENU_WIDTH_VP: number = 220;

/** 表面特有菜单项（删除记录 / 从队列移除等），追加在标准项之后。 */
export interface VideoMenuExtraItem {
  symbolStartIcon?: SymbolGlyphModifier;
  content: ResourceStr;
  contentColor?: ResourceColor;
  callback: Callback<void>;
}

/**
 * 视频条目长按上下文菜单的统一实现：信息区 + 标准项（收藏切换 / 查看作者 /
 * 纯音频播放 / 下载 / 分享）+ 表面特有项（extraItems）。
 * 统一的是容器与范式（220vp、信息区、divider、preview 动画由宿主的
 * bindContextMenu 选项给）；项集合按表面语义用 show* 开关裁剪——例如
 * 播放队列关 showAudioOnly（点击即队列内切换，纯音频会丢队列上下文），
 * 历史页的播放列表条目整组关闭视频项。
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
  /** bindContextMenu 的菜单内容树与宿主同树，@Consume 可正常解析。 */
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  extraItems: VideoMenuExtraItem[] = [];
  @StorageLink('favorites') favorites: VideoItem[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
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

  /** 播放数展示：精确文本（accessibilityLabel / RSS）优先，其次缩写文本。 */
  private getDisplayViewCount(): string {
    if (this.video.viewCountExact && this.video.viewCountExact.length > 0) {
      return this.video.viewCountExact;
    }
    return this.video.viewCount || '';
  }

  /** 发布时间（有则非空）。仅在长按菜单信息区展示。 */
  private getPublishTimeText(): string {
    return this.video.publishedTimeText || '';
  }

  /** 信息区是否有可显示内容。 */
  private hasContextMenuInfo(): boolean {
    return (!!this.video.title && this.video.title.length > 0)
      || (!!this.video.author && this.video.author.length > 0)
      || this.getDisplayViewCount().length > 0
      || this.getPublishTimeText().length > 0
      || (!!this.video.durationText && this.video.durationText.length > 0)
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
          .fontColor([$r('sys.color.font_primary')]),
        content: favorited ? $r('app.string.yt_action_unfavorite') : $r('app.string.yt_action_favorite'),
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
          .fontColor([$r('sys.color.font_primary')]),
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
          .fontColor([$r('sys.color.font_primary')]),
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
          .fontColor([$r('sys.color.font_primary')]),
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
          .fontColor([$r('sys.color.font_primary')]),
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

  build() {
    Scroll() {
      Column() {
        // 条目信息区（不可点击）：标题/作者(+认证)/播放数(精确优先)/发布时间/时长/视频ID/标记。
        if (this.showInfo && this.hasContextMenuInfo()) {
          Column() {
            Text(this.video.title)
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.yourtube_text_primary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')

            if (this.video.author && this.video.author.length > 0) {
              Row({ space: 4 }) {
                Text(this.video.author)
                  .fontSize(12)
                  .fontColor($r('app.color.yourtube_text_quaternary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .flexShrink(1)
                if (this.video.uploaderVerified) {
                  SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                    .fontSize(12)
                    .fontColor([$r('app.color.yourtube_text_quaternary')])
                }
              }
              .width('100%')
              .margin({ top: 4 })
            }

            if (this.getDisplayViewCount().length > 0) {
              Text(this.getDisplayViewCount())
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 2 })
            }
            if (this.getPublishTimeText().length > 0) {
              Text(this.getPublishTimeText())
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 2 })
            }
            if (this.video.durationText && this.video.durationText.length > 0) {
              Text(this.video.durationText)
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
                .maxLines(1)
                .width('100%')
                .margin({ top: 2 })
            }
            if (this.getVideoId().length > 0) {
              Text(`ID: ${this.getVideoId()}`)
                .fontSize(11)
                .fontColor($r('app.color.yourtube_text_hint'))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 2 })
            }

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
              .margin({ top: 6 })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })

          Divider()
            .strokeWidth(0.5)
            .color($r('sys.color.comp_divider'))
        }

        Menu() {
          ForEach(this.getMenuItems(), (item: VideoMenuExtraItem) => {
            MenuItem({
              symbolStartIcon: item.symbolStartIcon,
              content: item.content
            })
              .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
              .contentFontColor(item.contentColor ?? $r('sys.color.font_primary'))
              .onClick(() => {
                item.callback();
              });
          });
        }
        .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
        .width('100%')
        .height('auto')
      }
      .backgroundColor($r('app.color.yourtube_bg_surface'))
      .borderRadius(MEDIA_CARD_RADIUS)
      .clip(true)
      .width(MENU_WIDTH_VP)
    }
    .nestedScroll({ scrollForward: NestedScrollMode.SELF_FIRST, scrollBackward: NestedScrollMode.SELF_FIRST })
    .edgeEffect(EdgeEffect.Spring)
  }
}
