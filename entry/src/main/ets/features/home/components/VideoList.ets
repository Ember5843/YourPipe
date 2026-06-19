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

import { CommonConstants, VideoData } from 'mediaservice';

@Component({ freezeWhenInactive: true })
export struct VideoList {
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @Link currentIndex: number;
  @Prop sources: VideoData[];
  onItemClick?: (index: number) => void = () => {
  };

  build() {
    Column() {
      Text($r('app.string.recommends'))
        .fontSize($r('app.float.font_size_20'))
        .fontColor(Color.Black)
        .alignSelf(ItemAlign.Start)
        .padding({ top: $r('app.float.padding_14'), bottom: $r('app.float.padding_14') })
        .fontWeight(FontWeight.Bold)
        .opacity($r('app.float.opacity_9'))
      Scroll() {
        List({ space: CommonConstants.LIST_SPACE }) {
          ForEach(this.sources, (item: VideoData, index: number) => {
            ListItem() {
              Flex({ direction: FlexDirection.Row }) {
                Image(item.head || $r('app.media.image_thumbnail_1'))
                  .height($r('app.float.list_img_height'))
                  .width($r('app.float.list_img_width'))
                  .objectFit(ImageFit.Cover)
                  .borderRadius($r('app.float.list_img_radius'))
                Column() {
                  Text() {
                    if (index === this.currentIndex) {
                      SymbolSpan($r('sys.symbol.play_round_rectangle_fill'))
                        .fontColor([$r('app.color.button_fill_color')])
                        .effectStrategy(SymbolEffectStrategy.HIERARCHICAL)
                    }
                    Span(item.description)
                  }
                  .fontSize($r('app.float.new_font_size'))
                  .fontWeight(FontWeight.Medium)
                  .maxLines(2)
                  .ellipsisMode(EllipsisMode.END)
                  .width(CommonConstants.WIDTH_FULL_PERCENT)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .opacity($r('app.float.opacity_9'))
                  .fontColor(index === this.currentIndex ? $r('app.color.button_fill_color') : Color.Black)

                  Text() {
                    ImageSpan($r('app.media.ic_item_play'))
                      .width($r('app.float.image_size_12'))
                      .height($r('app.float.image_size_12'))
                      .margin({ right: $r('app.float.margin_4') })
                    Span($r('app.string.play_count'))
                    ImageSpan($r('app.media.ic_item_favor_filled'))
                      .width($r('app.float.image_size_12'))
                      .height($r('app.float.image_size_12'))
                      .margin({ left: $r('app.float.padding_12'), right: $r('app.float.margin_4') })
                    Span($r('app.string.favor_count'))
                  }
                  .fontSize($r('app.float.font_size_10'))
                  .fontColor($r('sys.color.black'))
                  .opacity($r('app.float.opacity_4'))
                }
                .height($r('app.float.list_img_height'))
                .margin({ left: $r('app.float.padding_12') })
                .alignItems(HorizontalAlign.Start)
                .justifyContent(FlexAlign.SpaceBetween)
              }
              .width(CommonConstants.WIDTH_FULL_PERCENT)
              .onClick(() => {
                this.onItemClick?.(index);
              })
            }
          }, (item: VideoData, index: number) => index + JSON.stringify(item))
        }
        .height(CommonConstants.HEIGHT_FULL_PERCENT)
        .width(CommonConstants.WIDTH_FULL_PERCENT)
        .listDirection(Axis.Vertical)
        .margin({
          top: $r('app.float.padding_12'),
          bottom: this.navBarHeight + CommonConstants.SPACE_16
        })
        .scrollBar(BarState.Off)
      }
      .scrollBar(BarState.Off)
    }
    .padding({ left: $r('app.float.padding_16'), right: $r('app.float.padding_16') })
  }
}