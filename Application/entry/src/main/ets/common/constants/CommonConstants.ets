/*
 *   Copyright (c) 2024 Huawei Device Co., Ltd.
 *   Licensed under the Apache License, Version 2.0 (the "License");
 *   you may not use this file except in compliance with the License.
 *   You may obtain a copy of the License at
 *
 *       http://www.apache.org/licenses/LICENSE-2.0
 *
 *   Unless required by applicable law or agreed to in writing, software
 *   distributed under the License is distributed on an "AS IS" BASIS,
 *   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *   See the License for the specific language governing permissions and
 *   limitations under the License.
 */

const uiContext: UIContext | undefined = AppStorage.get('uiContext');

export class CommonConstants {
  /**
   * Full percent.
   */
  static readonly FULL_PERCENT: string = '100%';
  /**
   * Font weight 500.
   */
  static readonly FONT_WEIGHT_500: number = 500;
  /**
   * Text opacity.
   */
  static readonly TEXT_OPACITY: number[] = [1, 0.4, 0.6, 0.05];
  /**
   * Window util list.
   */
  static readonly WINDOW_UTIL_LIST: string[] = ['windowUtil', 'secondWindowUtil'];
  /**
   * Default window width.
   */
  static readonly DEFAULT_WINDOW_WIDTH: number = 331;
  /**
   * Lg sidebar width.
   */
  static readonly LG_SIDEBAR_WIDTH: number = 96;
  /**
   * Two.
   */
  static readonly TWO: number = 2;
  /**
   * Three.
   */
  static readonly THREE: number = 3;
  /**
   * Four.
   */
  static readonly FOUR: number = 4;
  /**
   * Five.
   */
  static readonly FIVE: number = 5;
  /**
   * Width unit.
   */
  static readonly WIDTH_UNIT: string = 'vp';
  /**
   * Constant for screen dpi.
   */
  static readonly SCREEN_DPI_CONSTANT: number = 160;
  /**
   * Device types.
   */
  static readonly DEVICE_TYPES: string[] = ['2in1', 'tablet'];
  /**
   * Tab bar height for sm and md.
   */
  static readonly TAB_BAR_HEIGHT: number = 56;
  /**
   * Bottom rect height.
   */
  static readonly BOTTOM_RECT_HEIGHT: number = 24;
  /**
   * Bind sheet page type list.
   */
  static readonly BIND_SHEET_PAGE_TYPES: string[] = ['ShopBag', 'PayCard', 'ProductDetail', 'detailPayCard'];
  /**
   * Idle state of avPlayer.
   */
  static readonly AV_PLAYER_IDLE_STATE: string = 'idle';
  /**
   * Initialized state of avPlayer.
   */
  static readonly AV_PLAYER_INITIALIZED_STATE: string = 'initialized';
  /**
   * Prepared state of avPlayer.
   */
  static readonly AV_PLAYER_PREPARED_STATE: string = 'prepared';
  /**
   * Playing state of avPlayer.
   */
  static readonly AV_PLAYER_PLAYING_STATE: string = 'playing';
  /**
   * Pause state of avPlayer.
   */
  static readonly AV_PLAYER_PAUSED_STATE: string = 'paused';
  /**
   * Completed state of avPlayer.
   */
  static readonly AV_PLAYER_COMPLETED_STATE: string = 'completed';
  /**
   * Stopped state of avPlayer.
   */
  static readonly AV_PLAYER_STOPPED_STATE: string = 'stopped';
  /**
   * Release state of avPlayer.
   */
  static readonly AV_PLAYER_RELEASE_STATE: string = 'released';
  /**
   * Error state of avPlayer.
   */
  static readonly AV_PLAYER_ERROR_STATE: string = 'error';
  /**
   * Live video name.
   */
  static readonly LIVE_VIDEO_NAME: string = 'live.mp4';
  /**
   * Pip window util.
   */
  static readonly PIP_WINDOW_UTIL: string = 'pipWindowUtil';
  /**
   * Av player util.
   */
  static readonly AV_PLAYER_UTIL: string = 'avPlayerUtil';
  /**
   * home exit toast.
   */
  static readonly EXIT_TOAST: string = uiContext!.getHostContext()!.resourceManager.getStringSync($r('app.string.HOME_EXIT_TOAST').id);
}