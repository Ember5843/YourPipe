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

import { VideoEntry } from 'mediaservice';

@Component
export struct QualitySelect {
  @Prop entries: VideoEntry[];
  @Prop currentIndex: number;
  onPick: (entry: VideoEntry) => void = () => {};

  build() {
    Select(
      this.entries.map((e: VideoEntry) =>
        ({ value: `${e.resolutionLabel} (${e.codecLabel})` } as SelectOption)
      )
    )
      .selected(this.currentIndex)
      .value(this.entries[this.currentIndex]?.resolutionLabel ?? 'Auto')
      .font({ size: 14 })
      .selectedOptionFont({ size: 14, weight: FontWeight.Medium })
      .optionFont({ size: 14 })
      .onSelect((index: number, _value: string) => {
        this.onPick(this.entries[index]);
      })
  }
}
