import { AppLog } from '../../../common/AppLog';
import { CommentItem, CommentResponse } from 'youtube_core';
import { YouTubePlayService } from '../YouTubePlayService';
import { ActionHub, ActionHubEvent } from '../../../common/ActionHub';
import common from '@ohos.app.ability.common';
import { customAnimationUtil } from '../../../common/AnimationUtil';
import { UIConfig } from '../../../common/AppState';
import { TabErrorPanel } from '../../../common/components/TabErrorPanel';
import { CommentTranslateButton, CommentTranslatedText, CommentTranslateStateStore } from './CommentTranslateSection';
import { TranslationService } from '../../../common/TranslationService';

const logger = AppLog.getInstance('CommentList');

@Component
export struct CommentList {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop @Watch('onVideoIdChanged') videoId: string;
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @State comments: CommentItem[] = [];
  @State isLoading: boolean = false;
  @State nextPageToken: string | null = null;
  @State errorMessage: ResourceStr = '';
  @State commentCount: number = 0;
  
  // 用于导航到回复页面
  @Consume('commentPageInfo') pageInfo: NavPathStack;
  @Consume('actionHub') actionHub: ActionHub;
  private activeRequestKey: string = '';

  aboutToAppear() {
    this.loadComments(true);
  }

  private onVideoIdChanged(): void {
    this.comments = [];
    this.nextPageToken = null;
    this.errorMessage = '';
    this.commentCount = 0;
    this.isLoading = false;
    this.loadComments(true);
  }

  async loadComments(reset: boolean): Promise<void> {
    if (this.isLoading) return;
    if (!this.videoId) return;
    
    // 如果不是重置且没有 token，说明已加载完所有
    if (!reset && !this.nextPageToken) return;

    this.isLoading = true;
    const loadingVideoId = this.videoId;
    const requestKey = `${loadingVideoId}_${Date.now()}`;
    this.activeRequestKey = requestKey;
    logger.info(`loadComments(reset=${reset}), current count: ${this.comments.length}, token: ${this.nextPageToken ? 'present' : 'none'}`);

    if (reset) {
      this.comments = [];
      this.nextPageToken = null;
      this.commentCount = 0;
    }

    try {
      const context = getContext(this) as common.UIAbilityContext;
      const service = YouTubePlayService.getInstance(context);
      const response: CommentResponse = await service.fetchComments(loadingVideoId, this.nextPageToken);
      if (this.videoId !== loadingVideoId || this.activeRequestKey !== requestKey) {
        return;
      }
      
      if (reset) {
        this.comments = response.items;
        this.commentCount = response.commentCount || 0;
      } else {
        // 过滤掉重复项 (以防万一)
        const newItems = response.items.filter(newItem => !this.comments.some(existing => existing.id === newItem.id));
        if (newItems.length > 0) {
          this.comments = this.comments.concat(newItems);
        } else if (response.nextPageToken && response.nextPageToken !== this.nextPageToken) {
          // 如果拿到了新 token 但没拿到新项，尝试用新 token 继续加载一次
          this.nextPageToken = response.nextPageToken;
          this.isLoading = false; // 允许下一轮调用
          logger.warn('No new items but got new token, retrying...');
          return this.loadComments(false);
        }
      }
      this.nextPageToken = response.nextPageToken;
      this.errorMessage = '';
      logger.info(`Loaded ${response.items.length} items, nextToken: ${this.nextPageToken ? 'present' : 'none'}`);
    } catch (e) {
      if (this.videoId !== loadingVideoId || this.activeRequestKey !== requestKey) {
        return;
      }
      this.errorMessage = $r('app.string.yt_error_load_comments');
      logger.error('loadComments failed:', JSON.stringify(e));
    } finally {
      if (this.videoId === loadingVideoId && this.activeRequestKey === requestKey) {
        this.isLoading = false;
      }
    }
  }

  build() {
    this.commentsTabBuild();
  }

  @Builder
  commentsTabBuild() {
    Column() {
      if (this.commentCount > 0) {
        Row() {
          Text($r('app.string.yt_comments_count_format', this.commentCount))
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.yourtube_text_primary'))
        }
        .width('100%')
        .padding({ left: 16, top: 16, bottom: 8 })
      }

      Stack() {
        if (this.comments.length > 0) {
          List() {
            ForEach(this.comments, (item: CommentItem, index: number) => {
              ListItem() {
                this.CommentItemBuilder(item)
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
          .width('100%')
          .height('100%')
          .edgeEffect(EdgeEffect.Spring)
          .onReachEnd(() => {
            if (!this.isLoading && this.nextPageToken) {
              this.loadComments(false);
            }
          })
        } else if (this.isLoading) {
          Column() {
            LoadingProgress().width(40).height(40)
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else if (this.errorMessage) {
          TabErrorPanel({
            errorMessage: this.errorMessage,
            showRetry: true,
            onRetry: () => this.loadComments(true)
          })
        } else {
          Column() {
            Text($r('app.string.yt_empty_no_comments')).fontColor($r('app.color.yourtube_text_quaternary'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        }
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .onAppear(() => {
      // 检查堆栈大小并通知父组件
      this.actionHub.emit(ActionHubEvent.IS_REPLIES_OPEN_CHANGE, this.pageInfo.size() > 0);
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
  CommentItemBuilder(item: CommentItem) {
    Column() {
      Row() {
        // 头像
        Stack() {
          if (item.authorAvatarUrl) {
            Image(item.authorAvatarUrl)
              .width(36)
              .height(36)
              .borderRadius(18)
          } else {
            Circle()
              .width(36)
              .height(36)
              .fill(item.authorThumbnailColor || $r('app.color.yourtube_icon_hint'))
            Text(item.authorName.charAt(0).toUpperCase())
              .fontSize(16)
              .fontColor(Color.White)
              .fontWeight(FontWeight.Bold)
          }
        }
        .margin({ right: 12 })
        .align(Alignment.Center)

        Column() {
          Row() {
            Text(item.authorName)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.yourtube_text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            
            if (item.isPinned) {
              Row() {
                SymbolGlyph($r('sys.symbol.pin')).fontSize(12).fontColor([Color.Gray])
                Text($r('app.string.yt_label_pinned')).fontSize(10).fontColor(Color.Gray).margin({ left: 2 })
              }
              .margin({ left: 8 })
            }
          }
          
          Text(item.publishedTimeText)
            .fontSize(11)
            .fontColor($r('app.color.yourtube_text_quaternary'))
            .margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 评论内容
      Text(item.commentText)
        .fontSize(14)
        .fontColor($r('app.color.yourtube_text_secondary'))
        .margin({ top: 8, left: 48 })
        .lineHeight(20)
        .textAlign(TextAlign.Start)

      if (TranslationService.shouldOfferTranslation(item.commentText)) {
        CommentTranslatedText({ state: CommentTranslateStateStore.get(item.id, item.commentText) })
          .margin({ left: 48 })
      }

      // 交互栏
      Row() {
        Row() {
          SymbolGlyph($r('sys.symbol.hand_thumbsup')).fontSize(14).fontColor([$r('app.color.yourtube_text_quaternary')])
          Text(item.likeCount > 0 ? item.likeCount.toString() : $r('app.string.yt_label_like')).fontSize(12).fontColor($r('app.color.yourtube_text_quaternary')).margin({ left: 4 })
        }
        .margin({ right: 24 })

        if (item.isHeartedByAuthor) {
          SymbolGlyph($r('sys.symbol.heart_fill')).fontSize(14).fontColor([Color.Red])
            .margin({ right: 24 })
        }

        if (TranslationService.shouldOfferTranslation(item.commentText)) {
          CommentTranslateButton({
            state: CommentTranslateStateStore.get(item.id, item.commentText),
            commentId: item.id
          })
            .margin({ right: 24 })
        }

        if (item.replyCount > 0) {
          Text($r('app.string.yt_replies_count_format', item.replyCount))
            .fontSize(12)
            .fontColor(this.themePrimary)
            .fontWeight(FontWeight.Medium)
            .onClick(() => {
              this.pageInfo.pushPathByName('CommentReplyPage', item);
              this.actionHub.emit(ActionHubEvent.IS_REPLIES_OPEN_CHANGE, true);
            })
        }
      }
      .width('100%')
      .margin({ top: 12, left: 48 })
      .padding({ bottom: 12 })
      .justifyContent(FlexAlign.Start)
      
      Divider().color($r('app.color.yourtube_divider')).margin({ top: 4, left: 48 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 4 })
    .alignItems(HorizontalAlign.Start)
  }
}
