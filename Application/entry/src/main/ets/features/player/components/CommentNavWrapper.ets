import { CommentItem } from 'youtube_core';
import { CommentList } from './CommentList';
import { CommentReplyPage } from './CommentReplyPage';
import { ActionHub, ActionHubEvent } from '../../../common/ActionHub';

@Component
export struct CommentNavWrapper {
  @Prop @Watch('onVideoIdChanged') videoId: string;
  @Provide('commentPageInfo') commentPageInfo: NavPathStack = new NavPathStack();
  @Consume('actionHub') actionHub: ActionHub;
  private exitRepliesHandler: () => void = () => {
    setTimeout(() => {
      if (this.commentPageInfo.size() > 0) {
        this.commentPageInfo.pop();
      }
    }, 0);
  };

  @Builder
  CommentTabMap(name: string, param: Object) {
    if (name === 'CommentReplyPage') {
      CommentReplyPage()
    }
  }

  aboutToAppear(): void {
    this.actionHub.on(ActionHubEvent.EXIT_COMMENT_REPLIES, this.exitRepliesHandler);
  }

  aboutToDisappear(): void {
    this.actionHub.off(ActionHubEvent.EXIT_COMMENT_REPLIES, this.exitRepliesHandler);
  }

  private onVideoIdChanged(): void {
    setTimeout(() => {
      this.commentPageInfo = new NavPathStack();
      this.actionHub.emit(ActionHubEvent.IS_REPLIES_OPEN_CHANGE, false);
    }, 0);
  }

  build() {
    Navigation(this.commentPageInfo) {
      CommentList({ videoId: this.videoId })
    }
    .mode(NavigationMode.Stack)
    .hideTitleBar(true)
    .navDestination(this.CommentTabMap)
    .width('100%')
    .height('100%')
  }
}
