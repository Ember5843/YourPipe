import { CommentItem, CommentResponse } from 'youtube_core';
import { YouTubePlayService } from '../YouTubePlayService';
import { ActionHub, ActionHubEvent } from '../../../common/ActionHub';
import common from '@ohos.app.ability.common';
import { customAnimationUtil } from '../../../common/AnimationUtil';
import { UIConfig } from '../../../common/AppState';
import { HdsNavDestination, HdsNavDestinationTitleMode } from '@kit.UIDesignKit';
import { buildYourTubeTitleBar } from '../../../common/components/HdsTitleBar';

@Component
export struct CommentReplyPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @State parentComment: CommentItem | null = null;
  @State replies: CommentItem[] = [];
  @State isLoading: boolean = false;
  @State errorMessage: ResourceStr = '';
  @State nextPageToken: string | null = null;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  
  @Consume('commentPageInfo') pageInfo: NavPathStack;
  @Consume('actionHub') actionHub: ActionHub;
  private scrollerForScroll: Scroller = new Scroller();

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
    } catch (e) {
      this.errorMessage = $r('app.string.yt_error_load_replies');
    } finally {
      this.isLoading = false;
    }
  }

  build() {
    HdsNavDestination() {
      Column() {
        List({ scroller: this.scrollerForScroll }) {
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
            Circle().width(32).height(32).fill(item.authorThumbnailColor || '#CCCCCC')
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

      Text(item.commentText)
        .fontSize(14)
        .fontColor($r('app.color.yourtube_text_secondary'))
        .margin({ top: 8, left: 44 })
        .lineHeight(20)
        .textAlign(TextAlign.Start)

      Row() {
        SymbolGlyph($r('sys.symbol.hand_thumbsup')).fontSize(12).fontColor([$r('app.color.yourtube_text_quaternary')])
        Text(item.likeCount.toString()).fontSize(11).fontColor($r('app.color.yourtube_text_quaternary')).margin({ left: 4 })
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
