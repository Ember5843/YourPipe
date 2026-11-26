import { ActionHub } from '../../../common/ActionHub';
import { customAnimationUtil } from '../../../common/AnimationUtil';
import { ThemeColorUtil } from '../../../common/ThemeColorUtil';
import { SearchChannelItem } from 'youtube_core';
import { SubscriptionUser } from '../../../common/SubscriptionModel';
import { UIConfig } from '../../../common/AppState';
import { Callback } from '@ohos.base';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';
import {
  MEDIA_CARD_RADIUS,
  MEDIA_CARD_SHADOW_OFFSET_Y,
  MEDIA_CARD_SHADOW_RADIUS,
  MEDIA_META_SIZE,
  MEDIA_TITLE_LINE_HEIGHT,
  MEDIA_TITLE_SIZE
} from '../../../common/components/MediaCardTokens';

interface ContextMenuItem {
  symbolStartIcon?: SymbolGlyphModifier;
  content: ResourceStr;
  contentColor?: ResourceColor;
  callback: Callback<void>;
}

const SYMBOL_FONT_SIZE: number = 20;
const MENU_WIDTH_VP: number = 268;

@Component
export struct ChannelCard {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop channel: SearchChannelItem;
  @Prop typeLabel: ResourceStr = $r('app.string.yt_label_user');
  @Prop showDescription: boolean = true;
  @Prop forceActionLabel: ResourceStr = '';
  @StorageLink('subscriptions') subscriptions: SubscriptionUser[] = [];
  @StorageProp('uiConfig') uiConfig: UIConfig = new UIConfig();
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();
  @State isShowContextMenu: boolean = false;

  private getChannelId(): string {
    return (this.channel.channelId || '').trim();
  }

  private isSubscribed(): boolean {
    const channelId = this.getChannelId();
    if (!channelId) {
      return false;
    }
    return this.subscriptions.some((item: SubscriptionUser) => item.channelId === channelId);
  }

  private getActionLabel(): ResourceStr {
    if (typeof this.forceActionLabel === 'string' && this.forceActionLabel.length > 0) {
      return this.forceActionLabel;
    }
    return this.isSubscribed() ? $r('app.string.yt_action_unsubscribe') : $r('app.string.yt_action_subscribe');
  }

  private handleAction(): void {
    const channelId = this.getChannelId();
    if (!channelId) {
      return;
    }
    if (this.isSubscribed()) {
      this.actionHub.removeSubscription(channelId);
      return;
    }
    this.actionHub.addSubscription(this.channel);
  }

  private getContextMenus(): ContextMenuItem[] {
    const items: ContextMenuItem[] = [];
    if (this.isSubscribed()) {
      items.push({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.minus_circle'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([this.themePrimary]),
        content: $r('app.string.yt_action_unsubscribe'),
        contentColor: this.themePrimary,
        callback: () => {
          const channelId = this.getChannelId();
          if (channelId) {
            this.actionHub.removeSubscription(channelId);
          }
        }
      });
    } else {
      items.push({
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.plus_circle'))
          .fontSize(SYMBOL_FONT_SIZE)
          .fontColor([$r('sys.color.icon_primary')]),
        content: $r('app.string.yt_action_subscribe'),
        callback: () => {
          this.actionHub.addSubscription(this.channel);
        }
      });
    }
    items.push({
      symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.share'))
        .fontSize(SYMBOL_FONT_SIZE)
        .fontColor([$r('sys.color.icon_primary')]),
      content: $r('app.string.yt_action_share'),
      callback: () => {
        this.actionHub.shareChannel(this.channel);
      }
    });
    return items;
  }

  @Builder
  contextMenuBuilder() {
    Scroll() {
      Column() {
        // 信息区（与视频卡菜单同范式）：名称 / 大实心图标指标（订阅数、视频数） / 简介
        Column() {
          Text(this.channel.name || $r('app.string.yt_label_unknown'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(20)
            .width('100%')

          if ((this.channel.subscriberText && this.channel.subscriberText.length > 0)
            || (this.channel.videoCountText && this.channel.videoCountText.length > 0)) {
            Row({ space: 12 }) {
              if (this.channel.subscriberText && this.channel.subscriberText.length > 0) {
                Column({ space: 4 }) {
                  SymbolGlyph($r('sys.symbol.person_2_fill'))
                    .fontSize(26)
                    .fontColor([this.themePrimary])
                  Text(this.channel.subscriberText)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_primary'))
                    .fontFeature('"tnum" 1')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)
              }
              if (this.channel.videoCountText && this.channel.videoCountText.length > 0) {
                Column({ space: 4 }) {
                  SymbolGlyph($r('sys.symbol.play_circle_fill'))
                    .fontSize(26)
                    .fontColor([$r('sys.color.icon_primary')])
                  Text(this.channel.videoCountText)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .fontColor($r('sys.color.font_primary'))
                    .fontFeature('"tnum" 1')
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)
              }
            }
            .width('100%')
            .margin({ top: 10 })
          }

          if (this.channel.description && this.channel.description.length > 0) {
            Text(this.channel.description)
              .fontSize(12)
              .fontColor($r('sys.color.font_tertiary'))
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .margin({ top: 8 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14, top: 12, bottom: 12 })

        Divider()
          .strokeWidth(0.5)
          .color($r('sys.color.comp_divider'))

        Menu() {
          ForEach(this.getContextMenus(), (item: ContextMenuItem, idx: number) => {
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
          }, (_item: ContextMenuItem, idx: number) => `ch_menu_${idx}`);
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
    .edgeEffect(EdgeEffect.Spring);
  }

  build() {
    Row() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        if (this.channel.avatarUrl && this.channel.avatarUrl.length > 0) {
          Image(this.channel.avatarUrl)
            .width(56)
            .height(56)
            .objectFit(ImageFit.Cover)
            .borderRadius(28)
            .clip(true)
            .backgroundColor(this.channel.thumbnailColor || $r('app.color.yourtube_icon_hint'));
        } else {
          Circle()
            .width(56)
            .height(56)
            .fill(this.channel.thumbnailColor || $r('app.color.yourtube_icon_hint'));
        }

        if (typeof this.typeLabel === 'string' && this.typeLabel.length > 0) {
          Text(this.typeLabel)
            .fontSize(8)
            .fontColor($r('app.color.yourtube_text_inverse'))
            .backgroundColor($r('app.color.yourtube_bg_tag'))
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
            .borderRadius(8);
        }
      }
      .width(56)
      .height(56)
      .margin({ right: 12, top: 2 });

      Column() {
        Text(this.channel.name || $r('app.string.yt_label_unknown'))
          .fontSize(MEDIA_TITLE_SIZE)
          .fontColor($r('app.color.yourtube_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(MEDIA_TITLE_LINE_HEIGHT)
          .fontWeight(FontWeight.Medium)
          .margin({ bottom: 2 });

        Row() {
          if (this.channel.subscriberText && this.channel.subscriberText.length > 0) {
            Text(this.channel.subscriberText)
              .fontSize(MEDIA_META_SIZE)
              .fontColor($r('app.color.yourtube_text_quaternary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }
          if (this.channel.videoCountText && this.channel.videoCountText.length > 0) {
            Text(this.channel.subscriberText && this.channel.subscriberText.length > 0
              ? ` · ${this.channel.videoCountText}`
              : this.channel.videoCountText)
              .fontSize(MEDIA_META_SIZE)
              .fontColor($r('app.color.yourtube_text_hint'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);

        if (this.showDescription && this.channel.description && this.channel.description.length > 0) {
          Text(this.channel.description)
            .fontSize(10)
            .fontColor($r('app.color.yourtube_text_tertiary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(14)
            .margin({ top: 4 });
        }
      }
      .layoutWeight(1)
      .constraintSize({ minHeight: 56 })
      .alignItems(HorizontalAlign.Start);

      Column() {
        Button({ type: ButtonType.Capsule, stateEffect: true }) {
          Row({ space: 4 }) {
            SymbolGlyph(this.isSubscribed() ? $r('sys.symbol.checkmark') : $r('sys.symbol.plus'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor([this.isSubscribed() ? $r('sys.color.icon_secondary') : this.themePrimary])
            Text(this.getActionLabel())
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.isSubscribed() ? $r('sys.color.font_secondary') : this.themePrimary)
          }
          .padding({ left: 10, right: 12 })
          .alignItems(VerticalAlign.Center)
        }
        .backgroundColor(this.isSubscribed()
          ? $r('sys.color.comp_background_tertiary')
          : ThemeColorUtil.selectedBackground(this.themePrimary))
        .height(30)
        .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
        .onClick(() => {
          this.handleAction();
        });
      }
      .height(56)
      .justifyContent(FlexAlign.Center)
      .margin({ left: 8 });
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
    .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
    .bindContextMenu(this.isShowContextMenu, this.contextMenuBuilder, {
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
      const channelId = this.getChannelId();
      if (channelId) {
        this.actionHub.openChannelById(channelId, this.channel.name || '', this.channel.avatarUrl || '', this.channel.handle || '');
      } else {
        this.actionHub.openChannel(this.channel);
      }
    })
    .gesture(LongPressGesture()
      .onAction(() => {
        this.isShowContextMenu = true;
      }));
  }
}
