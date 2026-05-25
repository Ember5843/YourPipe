import { CommentItem } from 'youtube_core';
import { CommentList } from './CommentList';
import { CommentReplyPage } from './CommentReplyPage';
import { ActionHub, ActionHubEvent } from '../../../common/ActionHub';

@Component
export struct CommentNavWrapper {
  @Prop videoId: string;
  @Provide('commentPageInfo') commentPageInfo: NavPathStack = new NavPathStack();
  @Consume('actionHub') actionHub: ActionHub;

  @Builder
  CommentTabMap(name: string, param: Object) {
    if (name === 'CommentReplyPage') {
      CommentReplyPage()
    }
  }

  aboutToAppear(): void {
    this.actionHub.on(ActionHubEvent.EXIT_COMMENT_REPLIES, () => {
      if (this.commentPageInfo.size() > 0) {
        this.commentPageInfo.pop();
      }
    });
  }

  aboutToDisappear(): void {
    this.actionHub.off(ActionHubEvent.EXIT_COMMENT_REPLIES);
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
