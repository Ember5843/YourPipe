import { VideoItem } from 'youtube_core';
import { ActionHub } from '../../../common/ActionHub';
import { StoredLocalQueue } from '../../../common/PlaylistModel';
import { UIConfig } from '../../../common/AppState';
import { customAnimationUtil } from '../../../common/AnimationUtil';

/**
 * 半模态弹窗内容：把当前视频保存到本地播放列表。
 * 列出已有本地列表（含勾选态），点击切换加入/移出；底部可新建列表。
 * 通过 bindSheet 挂载，关闭由外层 isShow 双向绑定控制。
 */
@Component
export struct SavePlaylistSheet {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  /** 当前要保存的视频 */
  @Prop video: VideoItem;
  /** 双向绑定的显隐状态，由外层 bindSheet 持有 */
  @Link isShow: boolean;
  @StorageLink('localQueues') localQueues: StoredLocalQueue[] = [];
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @Consume('actionHub') actionHub: ActionHub = new ActionHub();

  @State private isCreating: boolean = false;
  @State private newName: string = '';

  private containsVideo(queue: StoredLocalQueue): boolean {
    return queue.videos.some((v) => v.videoId === this.video.videoId);
  }

  private toggle(queue: StoredLocalQueue): void {
    if (this.containsVideo(queue)) {
      this.actionHub.removeVideoFromLocalQueue(queue.id, this.video.videoId);
    } else {
      this.actionHub.addVideoToLocalQueue(queue.id, this.video);
    }
  }

  private confirmCreate(): void {
    const name = this.newName.trim();
    if (name.length === 0) {
      return;
    }
    this.actionHub.createLocalQueueWithVideo(name, this.video);
    this.newName = '';
    this.isCreating = false;
  }

  @Builder
  QueueRow(queue: StoredLocalQueue) {
    Row() {
      SymbolGlyph(this.containsVideo(queue)
        ? $r('sys.symbol.checkmark_circle_fill')
        : $r('sys.symbol.circle'))
        .fontSize(22)
        .fontColor([this.containsVideo(queue)
          ? this.themePrimary
          : $r('app.color.yourtube_text_hint')])
        .margin({ right: 12 })

      Column() {
        Text(queue.name)
          .fontSize(15)
          .fontColor($r('app.color.yourtube_text_primary'))
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text($r('app.string.yt_video_count_format', queue.videos.length))
          .fontSize(12)
          .fontColor($r('app.color.yourtube_text_quaternary'))
          .margin({ top: 2 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12, left: 4, right: 4 })
    .alignItems(VerticalAlign.Center)
    .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
    .onClick(() => { this.toggle(queue); })
  }

  @Builder
  CreateRow() {
    if (this.isCreating) {
      Row() {
        TextInput({ placeholder: $r('app.string.yt_playlist_name_placeholder'), text: this.newName })
          .layoutWeight(1)
          .height(40)
          .borderRadius(10)
          .fontSize(14)
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .onChange((val: string) => { this.newName = val; })
          .onSubmit(() => { this.confirmCreate(); })

        Button($r('app.string.yt_action_create'))
          .fontSize(14)
          .fontColor($r('app.color.yourtube_text_inverse'))
          .backgroundColor(this.newName.trim().length > 0
            ? this.themePrimary
            : $r('app.color.yourtube_button_disabled'))
          .height(40)
          .margin({ left: 10 })
          .padding({ left: 16, right: 16 })
          .onClick(() => { this.confirmCreate(); })
      }
      .width('100%')
      .padding({ top: 12, bottom: 12, left: 4, right: 4 })
      .alignItems(VerticalAlign.Center)
    } else {
      Row() {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(22)
          .fontColor([this.themePrimary])
          .margin({ right: 12 })
        Text($r('app.string.yt_action_new_playlist'))
          .fontSize(15)
          .fontColor(this.themePrimary)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 12, bottom: 12, left: 4, right: 4 })
      .alignItems(VerticalAlign.Center)
      .clickEffect(customAnimationUtil.isClickEffect(this.uiConfig))
      .onClick(() => { this.isCreating = true; })
    }
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.yt_action_save_to_playlist'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.yourtube_text_primary'))
          .layoutWeight(1)

        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(16)
            .fontColor([$r('app.color.yourtube_text_quaternary')])
        }
        .width(32)
        .height(32)
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .onClick(() => { this.isShow = false; })
      }
      .width('100%')
      .padding({ left: 20, right: 16, top: 18, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      Divider().strokeWidth(0.5).color($r('app.color.yourtube_divider'))

      List() {
        ForEach(this.localQueues, (queue: StoredLocalQueue) => {
          ListItem() { this.QueueRow(queue) }
        }, (queue: StoredLocalQueue) => queue.id + queue.videos.length)

        ListItem() { this.CreateRow() }
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16 })
      .edgeEffect(EdgeEffect.Spring)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.yourtube_bg_page'))
  }
}
