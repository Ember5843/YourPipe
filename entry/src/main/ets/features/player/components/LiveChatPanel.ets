import { common } from '@kit.AbilityKit';
import { LiveChatMessage, LiveChatPage } from 'youtube_core';
import { AppLog } from '../../../common/AppLog';
import { YouTubePlayService } from '../YouTubePlayService';

const logger = AppLog.getInstance('LiveChatPanel');

enum LiveChatStatus {
  IDLE = 'idle',
  CONNECTING = 'connecting',
  CONNECTED = 'connected',
  UNAVAILABLE = 'unavailable',
  ENDED = 'ended',
  ERROR = 'error'
}

const MAX_MESSAGES: number = 200;
const RETRY_DELAY_MS: number = 5000;
const MAX_AVATAR_URL_LENGTH: number = 2048;

/**
 * 播放页「聊天」Tab：YouTube 直播实时评论（只读）。
 *
 * 轮询节奏由服务端返回的 continuation timeoutMs 决定（1–15s 夹紧），
 * 失败按 5s 退避重连；Tab 不可见 / 离开页面 / 换视频都会停止轮询。
 * 只读：不发送、不点赞，避免账号风控。
 */
@Component
export struct LiveChatPanel {
  @Prop @Watch('onLifecycleChanged') videoId: string = '';
  @Prop @Watch('onLifecycleChanged') active: boolean = false;
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @State private status: string = LiveChatStatus.IDLE;
  @State private messages: LiveChatMessage[] = [];
  @State private autoScroll: boolean = true;

  private scroller: Scroller = new Scroller();
  private timerId: number = -1;
  private generation: number = 0;
  private continuation: string = '';
  private seenIds: Set<string> = new Set<string>();

  aboutToAppear(): void {
    this.syncLifecycle();
  }

  aboutToDisappear(): void {
    this.stop();
  }

  private onLifecycleChanged(): void {
    this.syncLifecycle();
  }

  private syncLifecycle(): void {
    if (this.active && this.videoId.length > 0) {
      this.start();
    } else {
      this.stop();
    }
  }

  private start(): void {
    this.stop();
    this.generation += 1;
    const generation = this.generation;
    this.messages = [];
    this.seenIds = new Set<string>();
    this.continuation = '';
    this.autoScroll = true;
    this.status = LiveChatStatus.CONNECTING;
    logger.info(`start video=${this.videoId} generation=${generation}`);
    this.fetchInitial(generation);
  }

  private stop(): void {
    this.generation += 1;
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    if (this.status !== LiveChatStatus.IDLE) {
      logger.info(`stop video=${this.videoId} status=${this.status} messages=${this.messages.length}`);
    }
    this.status = LiveChatStatus.IDLE;
  }

  private service(): YouTubePlayService | null {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    if (!context) {
      return null;
    }
    return YouTubePlayService.getInstance(context);
  }

  private async fetchInitial(generation: number): Promise<void> {
    const service = this.service();
    if (!service) {
      this.status = LiveChatStatus.ERROR;
      return;
    }
    try {
      const page: LiveChatPage = await service.fetchLiveChatInitial(this.videoId);
      if (generation !== this.generation) {
        return;
      }
      if (!page.available) {
        this.status = LiveChatStatus.UNAVAILABLE;
        logger.info(`unavailable video=${this.videoId}`);
        return;
      }
      logger.info(`initial ok video=${this.videoId} ended=${page.ended} `
        + `messages=${page.messages.length} timeout=${page.timeoutMs}`);
      this.applyPage(page);
      this.status = page.ended ? LiveChatStatus.ENDED : LiveChatStatus.CONNECTED;
      if (!page.ended) {
        this.schedule(generation, page.timeoutMs);
      }
    } catch (e) {
      if (generation !== this.generation) {
        return;
      }
      logger.warn(`initial failed video=${this.videoId}: ${(e as Error).message || e}`);
      this.status = LiveChatStatus.ERROR;
      this.schedule(generation, RETRY_DELAY_MS);
    }
  }

  private schedule(generation: number, delayMs: number): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
    }
    this.timerId = setTimeout(() => {
      this.poll(generation);
    }, Math.max(1000, delayMs));
  }

  private async poll(generation: number): Promise<void> {
    if (generation !== this.generation || this.continuation.length === 0) {
      return;
    }
    const service = this.service();
    if (!service) {
      return;
    }
    try {
      const page: LiveChatPage = await service.fetchLiveChatPage(this.continuation, -1);
      if (generation !== this.generation) {
        return;
      }
      this.applyPage(page);
      if (page.ended || page.continuation.length === 0) {
        this.status = LiveChatStatus.ENDED;
        logger.info(`ended video=${this.videoId} messages=${this.messages.length}`);
        return;
      }
      this.status = LiveChatStatus.CONNECTED;
      this.schedule(generation, page.timeoutMs);
    } catch (e) {
      if (generation !== this.generation) {
        return;
      }
      logger.warn(`poll failed video=${this.videoId}: ${(e as Error).message || e}`);
      this.status = LiveChatStatus.ERROR;
      this.schedule(generation, RETRY_DELAY_MS);
    }
  }

  private applyPage(page: LiveChatPage): void {
    if (page.continuation.length > 0) {
      this.continuation = page.continuation;
    }
    if (page.messages.length === 0) {
      return;
    }
    const next: LiveChatMessage[] = this.messages.slice();
    page.messages.forEach((message: LiveChatMessage) => {
      if (!message.id || this.seenIds.has(message.id)) {
        return;
      }
      this.seenIds.add(message.id);
      next.push(message);
    });
    if (next.length > MAX_MESSAGES) {
      this.messages = next.slice(next.length - MAX_MESSAGES);
    } else {
      this.messages = next;
    }
    if (this.autoScroll) {
      setTimeout(() => {
        this.scroller.scrollEdge(Edge.Bottom);
      }, 0);
    }
  }

  private statusText(): ResourceStr {
    switch (this.status) {
      case LiveChatStatus.CONNECTING: return $r('app.string.yt_live_chat_connecting');
      case LiveChatStatus.CONNECTED: return $r('app.string.yt_live_chat_connected');
      case LiveChatStatus.UNAVAILABLE: return $r('app.string.yt_live_chat_unavailable');
      case LiveChatStatus.ENDED: return $r('app.string.yt_live_chat_ended');
      case LiveChatStatus.ERROR: return $r('app.string.yt_live_chat_error');
      default: return '';
    }
  }

  private formatTime(timestampMs: number): string {
    const date = new Date(timestampMs);
    const hh = date.getHours().toString().padStart(2, '0');
    const mm = date.getMinutes().toString().padStart(2, '0');
    return `${hh}:${mm}`;
  }

  private avatarUrl(message: LiveChatMessage): string {
    const url = message.authorPhotoUrl || '';
    return url.length > 0 && url.length < MAX_AVATAR_URL_LENGTH ? url : '';
  }

  @Builder
  RoleTag(label: ResourceStr, color: ResourceColor) {
    Text(label)
      .fontSize(9)
      .fontColor(color)
      .border({ width: 1, color })
      .borderRadius(4)
      .padding({ left: 4, right: 4, top: 1, bottom: 1 })
      .margin({ left: 4 })
  }

  @Builder
  MessageRow(message: LiveChatMessage) {
    Row() {
      if (this.avatarUrl(message).length > 0) {
        Image(this.avatarUrl(message))
          .width(26)
          .height(26)
          .borderRadius(13)
          .margin({ right: 8, top: 2 })
          .alt($r('app.media.foreground'))
      } else {
        Stack() {
          Text((message.authorName || '?').substring(0, 1).toUpperCase())
            .fontSize(11)
            .fontColor($r('app.color.yourtube_text_inverse'))
        }
        .width(26)
        .height(26)
        .borderRadius(13)
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .margin({ right: 8, top: 2 })
      }

      Column() {
        Flex({ alignItems: ItemAlign.Center, wrap: FlexWrap.Wrap }) {
          Text(message.authorName)
            .fontSize(12)
            .fontColor(message.isOwner
              ? this.themePrimary
              : $r('app.color.yourtube_text_secondary'))
            .fontWeight(FontWeight.Medium)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (message.isOwner) {
            this.RoleTag($r('app.string.yt_live_chat_owner'), this.themePrimary)
          } else if (message.isModerator) {
            this.RoleTag($r('app.string.yt_live_chat_moderator'), $r('app.color.yourtube_text_secondary'))
          } else if (message.isMember) {
            this.RoleTag($r('app.string.yt_live_chat_member'), $r('app.color.yourtube_text_secondary'))
          }
          if (message.isPaid && message.amountText.length > 0) {
            this.RoleTag(message.amountText, this.themePrimary)
          }
          Text(this.formatTime(message.timestampMs))
            .fontSize(10)
            .fontColor($r('app.color.yourtube_text_hint'))
            .margin({ left: 6 })
        }
        .width('100%')

        Text(message.text)
          .fontSize(13)
          .fontColor($r('app.color.yourtube_text_primary'))
          .lineHeight(18)
          .width('100%')
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({
      left: 10,
      right: 10,
      top: 6,
      bottom: 6
    })
    .borderRadius(8)
    .backgroundColor(message.isPaid
      ? $r('app.color.yourtube_bg_surface_muted')
      : Color.Transparent)
  }

  build() {
    Column() {
      Row() {
        if (this.status === LiveChatStatus.CONNECTING || this.status === LiveChatStatus.ERROR) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color(this.themePrimary)
            .margin({ right: 6 })
        } else {
          Row()
            .width(6)
            .height(6)
            .borderRadius(3)
            .backgroundColor(this.status === LiveChatStatus.CONNECTED
              ? this.themePrimary
              : $r('app.color.yourtube_text_hint'))
            .margin({ right: 6 })
        }
        Text(this.statusText())
          .fontSize(11)
          .fontColor($r('app.color.yourtube_text_hint'))
          .layoutWeight(1)
        Text($r('app.string.yt_live_chat_readonly'))
          .fontSize(10)
          .fontColor($r('app.color.yourtube_text_hint'))
        if (this.status === LiveChatStatus.ERROR) {
          Text($r('app.string.yt_action_retry'))
            .fontSize(11)
            .fontColor(this.themePrimary)
            .margin({ left: 8 })
            .onClick(() => { this.start(); })
        }
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 6, bottom: 4 })

      if (this.messages.length === 0) {
        Column() {
          Text(this.status === LiveChatStatus.UNAVAILABLE
            ? $r('app.string.yt_live_chat_unavailable')
            : $r('app.string.yt_live_chat_empty'))
            .fontSize(13)
            .fontColor($r('app.color.yourtube_text_hint'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 2, scroller: this.scroller }) {
          ForEach(this.messages, (message: LiveChatMessage) => {
            ListItem() {
              this.MessageRow(message)
            }
          }, (message: LiveChatMessage) => message.id)
        }
        .width('100%')
        .layoutWeight(1)
        .edgeEffect(EdgeEffect.Spring)
        .cachedCount(20)
        .onScrollIndex((_start: number, end: number) => {
          this.autoScroll = end >= this.messages.length - 2;
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
