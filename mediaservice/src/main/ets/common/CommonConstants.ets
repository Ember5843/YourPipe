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

export enum AVPlayerState {
  /**
   * Idle state of avPlayer.
   */
  IDLE = 'idle',

  /**
   * Initialized state of avPlayer.
   */
  INITIALIZED = 'initialized',

  /**
   * Prepared state of avPlayer.
   */
  PREPARED = 'prepared',

  /**
   * Playing state of avPlayer.
   */
  PLAYING = 'playing',

  /**
   * Pause state of avPlayer.
   */
  PAUSED = 'paused',

  /**
   * Completed state of avPlayer.
   */
  COMPLETED = 'completed',

  /**
   * Stopped state of avPlayer.
   */
  STOPPED = 'stopped',

  /**
   * Release state of avPlayer.
   */
  RELEASED = 'released',

  /**
   * Error state of avPlayer.
   */
  ERROR = 'error'
}


export class CommonConstants {
  /**
   * Full size.
   */
  static readonly FULL_SIZE: string = '100%';
  /**
   * List item width.
   */
  static readonly LIST_ITEM_WIDTH: string = '25%';
  /**
   * List width.
   */
  static readonly LIST_WIDTH: string = '60%';
  /**
   * Column width.
   */
  static readonly COLUMN_WIDTH: string = '60%';
  /**
   * Video information width.
   */
  static readonly VIDEO_INFO_WIDTH: string = '80%';
  /**
   * Text width.
   */
  static readonly TEXT_WIDTH: string = '70%';
  /**
   * Column height.
   */
  static readonly COLUMN_HEIGHT: string = '70%';
  /**
   * Row width.
   */
  static readonly ROW_WIDTH: string = '66%';
  /**
   * Duration
   */
  static readonly DURATION: number = 200;
  /**
   * animate Duration
   */
  static readonly ANIMATE_DURATION: number = 200;
  /**
   * animate Delay
   */
  static readonly ANIMATE_DELAY: number = 100;
  /**
   * toast Duration
   */
  static readonly TOAST_DURATION: number = 500;
  /**
   * Track Thickness size min
   */
  static readonly TRACK_SIZE_MIN: number = 4;
  /**
   * Track Thickness borderRadius
   */
  static readonly TRACK_BORDER_RADIUS: number = 2;
  /**
   * Track Thickness size max
   */
  static readonly TRACK_SIZE_MAX: number = 6;
  /**
   * Timer interval number
   */
  static readonly TIMER_INTERVAL: number = 100;
  /**
   * Video play icon width
   */
  static readonly IMAGE_PLAY_WIDTH: string = '56vp';
  /**
   * Video play icon height
   */
  static readonly IMAGE_PLAY_HEIGHT: string = '56vp';
  /**
   * The surface width
   */
  static readonly SURFACE_WIDTH: number = 1224;
  /**
   * The surface height
   */
  static readonly SURFACE_HEIGHT: number = 689;
  /**
   * Text front size
   */
  static readonly TEXT_FRONT_SIZE: string = '20vp';
  /**
   * Text margin size
   */
  static readonly TEXT_MARGIN_LEFT: string = '2vp';
  /**
   * Text left width
   */
  static readonly TEXT_LEFT_WIDTH: string = '45%';
  /**
   * Text mid width
   */
  static readonly TEXT_MID_WIDTH: string = '10%';
  /**
   * Time text all width
   */
  static readonly TEXT_TIME_ALL_WIDTH: string = '100%';
  /**
   * Blank text height
   */
  static readonly TEXT_BLANK_HEIGHT: string = '25%';
  /**
   * Slider step
   */
  static readonly SLIDER_STEP: number = 0.1;
  /**
   * Slider min
   */
  static readonly SLIDER_MIN: number = 0;
  /**
   * Slider width
   */
  static readonly SLIDER_WIDTH: string = '100%';
  /**
   * Slider index
   */
  static readonly SLIDER_INDEX: number = 3;
  /**
   * Slider opacity
   */
  static readonly SLIDER_OPACITY: number = 0.5;
  /**
   * Flex padding
   */
  static readonly FLEX_PADDING: string = '2vp';
  /**
   * Flex offset x
   */
  static readonly FLEX_OFFSET_X: number = 0;
  /**
   * Flex offset y
   */
  static readonly FLEX_OFFSET_Y: number = 350;
  /**
   * Flex width
   */
  static readonly FLEX_WIDTH: string = '100%';
  /**
   * Flex height
   */
  static readonly FLEX_HEIGHT: string = '20%';
  /**
   * Flex index
   */
  static readonly FLEX_INDEX: number = 2;
  /**
   * video right menu index
   */
  static readonly Z_INDEX_RIGHT_SIDE: number = 3;
  /**
   * video Play button index
   */
  static readonly Z_INDEX_VIDEO_PLAY: number = 2;
  /**
   * video max index
   */
  static readonly Z_INDEX_MAX: number = 5;
  /**
   * video base index
   */
  static readonly Z_INDEX_BASE: number = 1;
  /**
   * Width percent full
   */
  static readonly WIDTH_FULL_PERCENT: string = '100%';
  /**
   * Height percent full
   */
  static readonly HEIGHT_FULL_PERCENT: string = '100%';
  /**
   * Height percent full
   */
  static readonly CACHED_COUNT: number = 3;
  /**
   * Seek hour unit
   */
  static readonly HOUR_UNIT: number = 60;
  /**
   * Second to Millisecond
   */
  static readonly SECOND_TO_MS: number = 1000;
  /**
   * Time const number
   */
  static readonly TIME_CONST_TEN: number = 10;
  /**
   * CurIndex default number
   */
  static readonly CURINDEX_DEFAULT_NUM: number = -1;
  /**
   * Divider height number
   */
  static readonly DIVIDER_HEIGHT: number = 14;
  /**
   * Divider width number
   */
  static readonly DIVIDER_WIDTH: number = 2;
  /**
   * Divider opacity
   */
  static readonly DIVIDER_OPACITY: number = 0.5;
  /**
   * Divider margin
   */
  static readonly DIVIDER_MARGIN: number = 8;
  /**
   * Divider x
   */
  static readonly DIVIDER_X: number = 0;
  /**
   * Divider y
   */
  static readonly DIVIDER_Y: number = 0;
  /**
   * Divider z
   */
  static readonly DIVIDER_Z: number = 1;
  /**
   * Divider center x
   */
  static readonly DIVIDER_CENTER_X: string = '50%';
  /**
   * Divider center y
   */
  static readonly DIVIDER_CENTER_Y: string = '50%';
  /**
   * Divider angle
   */
  static readonly DIVIDER_ANGLE: number = 30;
  /**
   * Blank 600
   */
  static readonly BLANK_LEN_600: number = 600;
  /**
   * Blank 50
   */
  static readonly BLANK_LEN_50: number = 50;
  /**
   * Duration time
   */
  static readonly DURATION_TIME: number = 300;
  /**
   *  detail video height
   */
  static readonly DETAIL_VIDEO_HEIGHT: number = 148;
  /**
   *  detail video list space
   */
  static readonly LIST_SPACE: string = '12vp';
  /**
   *  detail video list space
   */
  static readonly SPACE_16: number = 16;
  /**
   *  video aspect
   */
  static readonly ASPECT: number = 16 / 9;
  /**
   *  full screen width
   */
  static readonly FULL_SCREEN_WIDTH: number = 820;
}