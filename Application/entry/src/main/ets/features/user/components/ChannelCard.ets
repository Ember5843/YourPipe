import { ActionHub } from '../../../common/ActionHub';
import { customAnimationUtil } from '../../../common/AnimationUtil';
import { customVibrator } from '../../../common/VibratorUtil';
import { SearchChannelItem } from 'youtube_core';
import { SubscriptionUser } from '../../../common/SubscriptionModel';
import { UIConfig } from '../../../common/AppState';
import { Callback } from '@ohos.base';
import { LengthMetrics, SymbolGlyphModifier } from '@kit.ArkUI';

interface ContextMenuItem {
  symbolStartIcon?: SymbolGlyphModifier;
  content: ResourceStr;
  contentColor?: ResourceColor;
  callback: Callback<void>;
}

const SYMBOL_FONT_SIZE: number = 16;

@Component
export struct ChannelCard {
  @Prop channel: SearchChannelItem;
  @Prop typeLabel: ResourceStr = $r('app.string.yt_label_user');
  @Prop showDescription: boolean = true;
  @Prop forceActionLabel: ResourceStr = '';
  @StorageLink('subscriptions') subscriptions: SubscriptionUser[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
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
          .fontColor([$r('sys.color.font_primary')]),
        content: $r('app.string.yt_action_unsubscribe'),
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
          .fontColor([$r('sys.color.font_primary')]),
        content: $r('app.string.yt_action_subscribe'),
        callback: () => {
          this.actionHub.addSubscription(this.channel);
        }
      });
    }
    items.push({
      symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.share'))
        .fontSize(SYMBOL_FONT_SIZE)
        .fontColor([$r('sys.color.font_primary')]),
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
      Menu() {
        ForEach(this.getContextMenus(), (item: ContextMenuItem) => {
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
      .backgroundColor($r('app.color.yourtube_bg_surface'))
      .borderRadius(12)
      .menuItemDivider({ strokeWidth: LengthMetrics.vp(0.5), color: $r('sys.color.comp_divider') })
      .width(180)
      .height('auto')
      //.transition(customAnimationUtil.isMenuTransition(this.uiConfig));
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
        Text(this.channel.name || 'Unknown')
          .fontSize(14)
          .fontColor($r('app.color.yourtube_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(18)
          .fontWeight(FontWeight.Medium)
          .margin({ bottom: 2 });

        Row() {
          if (this.channel.subscriberText && this.channel.subscriberText.length > 0) {
            Text(this.channel.subscriberText)
              .fontSize(11)
              .fontColor($r('app.color.yourtube_text_quaternary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }
          if (this.channel.videoCountText && this.channel.videoCountText.length > 0) {
            Text(this.channel.subscriberText && this.channel.subscriberText.length > 0
              ? ` · ${this.channel.videoCountText}`
              : this.channel.videoCountText)
              .fontSize(11)
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
        Button(this.getActionLabel())
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_inverse'))
          .backgroundColor(this.isSubscribed() ? $r('app.color.yourtube_button_disabled') : $r('app.color.yourtube_theme_primary'))
          .height(28)
          .padding({ left: 10, right: 10 })
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
    .borderRadius(12)
    .backgroundColor($r('app.color.yourtube_bg_surface'))
    .shadow({ radius: 4, color: $r('app.color.yourtube_shadow'), offsetX: 0, offsetY: 2 })
    .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
    .bindContextMenu(this.isShowContextMenu, this.contextMenuBuilder, {
      preview: MenuPreviewMode.IMAGE,
      previewAnimationOptions: { scale: [1.0, 1.1] },
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
      this.actionHub.openChannel(this.channel);
    })
    .gesture(LongPressGesture()
      .onAction(() => {
        this.isShowContextMenu = true;
      }));
  }
}
