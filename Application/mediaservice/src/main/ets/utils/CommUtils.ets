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

import { CommonConstants } from '../common/CommonConstants';

export function secondToTime(seconds: number): string {
  let hourUnit: number = CommonConstants.HOUR_UNIT * CommonConstants.HOUR_UNIT;
  let hour: number = Math.floor(seconds / hourUnit);
  let minute: number = Math.floor((seconds - hour * hourUnit) / CommonConstants.HOUR_UNIT);
  let second: number = seconds - hour * hourUnit - minute * CommonConstants.HOUR_UNIT;
  let hourStr: string = hour < CommonConstants.TIME_CONST_TEN ? `0${hour.toString()}` : `${hour.toString()}`
  let minuteStr: string = minute < CommonConstants.TIME_CONST_TEN ? `0${minute.toString()}` : `${minute.toString()}`
  let secondStr: string = second < CommonConstants.TIME_CONST_TEN ? `0${second.toString()}` : `${second.toString()}`
  if (hour > 0) {
    return `${hourStr}:${minuteStr}:${secondStr}`;
  }
  if (minute > 0) {
    return `${minuteStr}:${secondStr}`;
  } else {
    return `00:${secondStr}`;
  }
}
