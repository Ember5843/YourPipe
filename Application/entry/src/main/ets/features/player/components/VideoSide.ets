/*
 * Copyright (c) 2024 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { CommonConstants as Const, Logger, VideoData } from 'mediaservice';

const TAG: string = '[VideoSide]';

@Component
export struct RightSide {
  @Prop item: VideoData;
  @State isFollow: boolean = true;
  @State isLike: boolean = false;

  /**
   * The callback function for the click event of the like button.
   * @param isAdd
   */
  private changeLikeCount(isAdd: boolean): void {
    let likeCountNum: number = Number(this.item.likeCount);
    if (isAdd) {
      likeCountNum++;
    } else {
      likeCountNum--;
    }
    this.item.likeCount = '' + likeCountNum;
    this.getUIContext().animateTo({ duration: Const.DURATION, curve: Curve.EaseInOut }, () => {
      this.isLike = !this.isLike;
    })
  }

  build() {
    Column() {
      Column() {
        Image(this.item.head)
          .width($r('app.float.avatar_size'))
          .height($r('app.float.avatar_size'))
          .borderRadius($r('app.float.avatar_borderRadius'))
          .border({
            width: 1,
            color: Color.White
          })
        Image(this.isFollow ? $r('app.media.img') : $r('app.media.follow1'))
          .width($r('app.float.concern_size'))
          .height($r('app.float.concern_size'))
          .borderRadius($r('app.float.concern_border_radius'))
          .margin({ top: $r('app.float.concern_margin_bottom') })
          .onClick(() => {
            this.getUIContext().animateTo({ duration: Const.DURATION, curve: Curve.EaseInOut }, () => {
              this.isFollow = !this.isFollow;
            });
          })

      }
      .width($r('app.float.avatar_size'))
      .alignItems(HorizontalAlign.Center)
      .margin({ bottom: $r('app.float.avatar_padding_bottom') })

      Column() {
        Image($r('app.media.ic_video_favor_filled'))
          .height($r('app.float.fabulous_height'))
          .width($r('app.float.fabulous_width'))
          .fillColor(this.isLike ? Color.Red : Color.White)
          .onClick(() => {
            this.changeLikeCount(!this.isLike);
          })
          .margin({ bottom: $r('app.float.fabulous_margin_bottom') })
        Text(this.item.likeCount)
          .fontSize($r('app.float.fabulous_font_size'))
          .fontColor(Color.White)
      }
      .width($r('app.float.avatar_size'))
      .alignItems(HorizontalAlign.Center)
      .margin({ bottom: $r('app.float.avatar_padding_bottom') })

      Column() {
        Image($r('app.media.ic_video_comments_filled'))
          .height($r('app.float.fabulous_height'))
          .width($r('app.float.fabulous_width'))
          .fillColor(Color.White)
          .margin({ bottom: $r('app.float.fabulous_margin_bottom') })
          .onClick(() => {
            try {
              this.getUIContext()
                .getPromptAction()
                .showToast({ message: $r('app.string.comment'), duration: Const.TOAST_DURATION });
            } catch (err) {
              Logger.error(TAG, `video comments click failed, err.code:${err.code}, err.message:${err.message}`);
            }
          })
        Text(this.item.commentCount)
          .fontSize($r('app.float.fabulous_font_size'))
          .fontColor(Color.White)
      }
      .width($r('app.float.avatar_size'))
      .alignItems(HorizontalAlign.Center)
      .margin({ bottom: $r('app.float.avatar_padding_bottom') })

      Column() {
        Image($r('app.media.ic_video_share_filled'))
          .fillColor(Color.White)
          .height($r('app.float.fabulous_height'))
          .width($r('app.float.fabulous_height'))
          .margin({ bottom: $r('app.float.fabulous_margin_bottom') })
        Text(this.item.shareCount)
          .fontSize($r('app.float.fabulous_font_size'))
          .fontColor(Color.White)
      }
      .width($r('app.float.avatar_size'))
      .alignItems(HorizontalAlign.Center)
      .onClick(() => {
        try {
          this.getUIContext()
            .getPromptAction()
            .showToast({ message: $r('app.string.share'), duration: Const.TOAST_DURATION });
        } catch (err) {
          Logger.error(TAG, `video share click failed, err.code:${err.code}, err.message:${err.message}`);
        }
      })
    }
    .margin({ bottom: $r('app.float.video_side_margin_bottom'), right: $r('app.float.right_space') })
    .width($r('app.float.side_width'))
    .justifyContent(FlexAlign.End)
  }
}

@Component
export struct VideoDes {
  @Prop isFloatWindow: boolean = false;
  @Prop item: VideoData;
  onNextClick?: () => void;

  build() {
    Column() {
      Row() {
        Text(this.item.name)
          .fontSize($r('app.float.name_font_size'))
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.des_font_color'))
        Text(this.item.time)
          .margin({ left: $r('app.float.margin_4') })
          .fontSize($r('app.float.font_size_12'))
          .fontColor($r('app.color.des_time_font_color'))
      }
      .alignItems(VerticalAlign.Center)
      .margin({ bottom: $r('app.float.margin_small') })
      .visibility(this.isFloatWindow ? Visibility.None : Visibility.Visible)

      Row() {
        Text(this.item.description)
          .fontSize(this.isFloatWindow ? $r('app.float.name_font_size') : $r('app.float.new_font_size'))
          .fontColor(Color.White)
          .width(Const.TEXT_WIDTH)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Image($r('app.media.ic_video_menu_next'))
          .width($r('app.float.size_24'))
          .aspectRatio(1)
          .visibility(this.isFloatWindow ? Visibility.Visible : Visibility.Hidden)
          .onClick(() => {
            this.onNextClick?.();
          })
      }
      .alignItems(VerticalAlign.Center)
      .width(Const.WIDTH_FULL_PERCENT)
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .alignItems(HorizontalAlign.Start)
    .width(Const.FULL_SIZE)
  }
}

@Component
export struct VideoBottom {
  @Prop isFullScreen: boolean;
  onFullScreenClick: (isLandScape?: boolean) => void = () => {
  };

  build() {
    Row() {
      Row() {
        TextInput({ placeholder: $r('app.string.send_barrage') })
          .placeholderColor(Color.Gray)
          .placeholderFont({ size: $r('app.float.input_font_size') })
          .fontColor($r('app.color.input_font_color'))
          .fontSize($r('app.float.input_font_size'))
          .layoutWeight(1)
        Image($r('app.media.ic_eye'))
          .width($r('app.float.size_24'))
          .height($r('app.float.size_24'))
          .margin({ right: $r('app.float.margin_small') })
      }
      .alignItems(VerticalAlign.Center)
      .backgroundColor($r('app.color.input_background_color'))
      .height(Const.HEIGHT_FULL_PERCENT)
      .layoutWeight(1)
      .borderRadius(67)
      .margin({ right: $r('app.float.margin_4') })

      FullScreenControl({ isFullScreen: this.isFullScreen, onFullScreenClick: this.onFullScreenClick })
    }
    .padding({ left: $r('app.float.padding_16'), right: $r('app.float.padding_16') })
    .alignItems(VerticalAlign.Center)
    .height($r('app.float.bottom_height'))
    .width(Const.WIDTH_FULL_PERCENT)
  }
}

@Component
export struct FullScreenControl {
  @Prop isFullScreen: boolean;
  onFullScreenClick ?: Function;

  build() {
    Row() {
      Image(this.isFullScreen ? $r('app.media.ic_video_menu_detail') :
      $r('app.media.ic_video_menu_landscape_fullscreen'))
        .fillColor($r('sys.color.white'))
        .width($r('app.float.size_24'))
        .height($r('app.float.size_24'))
        .onClick(() => {
          this.onFullScreenClick?.(true);
        })
    }
  }
}