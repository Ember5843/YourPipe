import { CommentItem, CommentResponse } from 'youtube_core';
import { YouTubePlayService } from '../YouTubePlayService';
import { ActionHub, ActionHubEvent } from '../../../common/ActionHub';
import common from '@ohos.app.ability.common';
import { customAnimationUtil } from '../../../common/AnimationUtil';
import { UIConfig } from '../../../common/AppState';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { buildYourTubeTitleBar } from '../../../common/components/HdsTitleBar';
import { AppLog } from '../../../common/AppLog';
import { CommentTranslateButton, CommentTranslatedText, CommentTranslateStateStore } from './CommentTranslateSection';
import { TranslationService } from '../../../common/TranslationService';
import { PlayerSession } from '../../../common/PlayerSession';
import { RichTextSegment, SegmentKind, buildRichTextSegments } from '../../../common/utils/RichTextSegment';

const logger = AppLog.getInstance('CommentReplyPage');
const TITLE_BAR_SAFE_HEIGHT: number = 56;

@Component
export struct CommentReplyPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @State parentComment: CommentItem | null = null;
  @State replies: CommentItem[] = [];
  @State isLoading: boolean = false;
  @State errorMessage: ResourceStr = '';
  @State nextPageToken: string | null = null;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  
  @Consume('commentPageInfo') pageInfo: NavPathStack;
  @Consume('actionHub') actionHub: ActionHub;
  private scrollerForScroll: Scroller = new Scroller();

  /** 回复内时间戳点击 → 复用与简介/评论一致的精确 seek 通道。 */
  private seekToCommentTimestamp(seconds: number): void {
    try {
      const session = PlayerSession.getInstance();
      const controller = session.controller;
      const duration = controller.vm.durationTime;
      const targetSeconds = duration > 0 ? Math.min(seconds, duration) : seconds;
      logger.info(`reply timestamp seek videoId=${session.currentVideo?.videoId || ''} targetSec=${targetSeconds}`);
      controller.syncSeekExact(targetSeconds * 1000);
    } catch (e) {
      logger.warn(`reply timestamp seek failed: ${e}`);
    }
  }

  aboutToAppear() {
    // 获取传递的参数
    const paramsArray = this.pageInfo.getParamByName('CommentReplyPage') as Array<CommentItem>;
    if (paramsArray && paramsArray.length > 0) {
      const params = paramsArray[0];
      this.parentComment = params;
      this.loadReplies(true, params.replyContinuation);
    }
  }

  async loadReplies(reset: boolean, continuation: string | null): Promise<void> {
    if (!continuation || this.isLoading) return;
    
    this.isLoading = true;
    if (reset) {
      this.replies = [];
    }

    try {
      logger.info(`loadReplies start reset=${reset} currentCount=${this.replies.length}`);
      const context = getContext(this) as common.UIAbilityContext;
      const service = YouTubePlayService.getInstance(context);
      const response: CommentResponse = await service.fetchCommentReplies(continuation);
      
      if (reset) {
        this.replies = response.items;
      } else {
        const newItems = response.items.filter(newItem => !this.replies.some(existing => existing.id === newItem.id));
        this.replies = this.replies.concat(newItems);
      }
      this.nextPageToken = response.nextPageToken;
      this.errorMessage = '';
      logger.info(`loadReplies complete reset=${reset} loaded=${response.items.length} hasNext=${!!this.nextPageToken}`);
    } catch (e) {
      this.errorMessage = $r('app.string.yt_error_load_replies');
      logger.error(`loadReplies failed reset=${reset}`, e as Object);
    } finally {
      this.isLoading = false;
    }
  }

  build() {
    HdsNavDestination() {
      Column() {
        List({ scroller: this.scrollerForScroll }) {
          ListItem() {
            Row()
              .width('100%')
              .height(TITLE_BAR_SAFE_HEIGHT)
          }
          // 父评论
          if (this.parentComment) {
            ListItem() {
              this.CommentItemBuilder(this.parentComment, true)
            }
          }

          ListItem() {
             Divider().color($r('app.color.yourtube_divider')).strokeWidth(8).opacity(0.1)
          }

          // 回复列表
          ForEach(this.replies, (item: CommentItem, index: number) => {
            ListItem() {
              this.CommentItemBuilder(item, false)
            }
            .transition(customAnimationUtil.isScaleTran(index, this.uiConfig))
          }, (item: CommentItem) => item.id)

          if (this.nextPageToken) {
            ListItem() {
              Row() {
                this.LoadingBuilder()
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding(16)
            }
          }
        }
        .clip(false)
        .layoutWeight(1)
        .width('100%')
        .onReachEnd(() => {
          if (!this.isLoading && this.nextPageToken) {
            this.loadReplies(false, this.nextPageToken);
          }
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.yourtube_bg_page'))
    }
    .bindToScrollable([this.scrollerForScroll])
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar(buildYourTubeTitleBar({
      title: $r('app.string.yt_label_reply'),
      onBack: () => {
        this.pageInfo.pop();
      }
    }))
    .onDisAppear(() => {
       // 退出二级评论时，通知父组件检查状态
       this.actionHub.emit(ActionHubEvent.IS_REPLIES_OPEN_CHANGE, this.pageInfo.size() > 0);
    })
    .onBackPressed(() => {
      this.pageInfo.pop();
      return true;
    })
  }

  @Builder
  LoadingBuilder() {
    LoadingProgress()
      .color(this.themePrimary)
      .width(24)
      .height(24)
  }

  @Builder
  CommentItemBuilder(item: CommentItem, isParent: boolean) {
    Column() {
      Row() {
        Stack() {
          if (item.authorAvatarUrl) {
            Image(item.authorAvatarUrl)
              .width(32)
              .height(32)
              .borderRadius(16)
          } else {
            Circle().width(32).height(32).fill(item.authorThumbnailColor || $r('app.color.yourtube_icon_hint'))
            Text(item.authorName.charAt(0).toUpperCase()).fontSize(14).fontColor(Color.White)
          }
        }
        .margin({ right: 12 })

        Column() {
          Text(item.authorName).fontSize(13).fontWeight(FontWeight.Medium).fontColor($r('app.color.yourtube_text_primary'))
          Text(item.publishedTimeText).fontSize(10).fontColor($r('app.color.yourtube_text_quaternary')).margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      // 回复内容：其中的时间戳（如 1:23）可点，跳到该位置
      Text() {
        ForEach(buildRichTextSegments(item.commentText), (segment: RichTextSegment) => {
          if (segment.kind === SegmentKind.TIMESTAMP) {
            Span(segment.text)
              .fontColor(this.themePrimary)
              .onClick(() => { this.seekToCommentTimestamp(segment.seconds); })
          } else {
            Span(segment.text)
              .fontColor($r('app.color.yourtube_text_secondary'))
          }
        })
      }
      .fontSize(14)
      .margin({ top: 8, left: 44 })
      .lineHeight(20)
      .textAlign(TextAlign.Start)

      if (TranslationService.shouldOfferTranslation(item.commentText)) {
        CommentTranslatedText({ state: CommentTranslateStateStore.get(item.id, item.commentText) })
          .margin({ left: 44 })
      }

      Row() {
        SymbolGlyph($r('sys.symbol.hand_thumbsup')).fontSize(12).fontColor([$r('app.color.yourtube_text_quaternary')])
        Text(item.likeCount.toString()).fontSize(11).fontColor($r('app.color.yourtube_text_quaternary')).margin({ left: 4 })

        if (TranslationService.shouldOfferTranslation(item.commentText)) {
          CommentTranslateButton({
            state: CommentTranslateStateStore.get(item.id, item.commentText),
            commentId: item.id
          })
            .margin({ left: 24 })
        }
      }
      .margin({ top: 8, left: 44, bottom: 8 })
      .justifyContent(FlexAlign.Start)
      
      if (!isParent) {
        Divider().color($r('app.color.yourtube_divider')).margin({ left: 44 })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 8 })
    .alignItems(HorizontalAlign.Start)
  }
}
