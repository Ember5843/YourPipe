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

/**
 * Label/value row for the stream-info sheet. A real @Component (not a local
 * @Builder) so live values (connection speed, buffer, dropped frames)
 * re-render when the stats polling updates them — @Builder by-value params
 * only render once.
 */
@Component
export struct StreamInfoRow {
  label: ResourceStr = '';
  @Prop value: string = '';

  build() {
    Row() {
      Text(this.label)
        .fontSize(13)
        .fontColor($r('app.color.yourtube_text_secondary'))
        .width(80)
      Text(this.value)
        .fontSize(13)
        .fontColor($r('app.color.yourtube_text_primary'))
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 3, bottom: 3 })
  }
}
