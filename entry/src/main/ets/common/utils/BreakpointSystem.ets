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

import { window } from '@kit.ArkUI';
import { Logger } from 'mediaservice';

const TAG: string = '[BreakpointSystem]';

export enum BreakpointTypeEnum {
  XS = 'xs',
  SM = 'sm',
  MD = 'md',
  LG = 'lg',
  XL = 'xl',
}

export class BreakpointSystem {
  private static instance: BreakpointSystem;
  private currentBreakpoint: BreakpointTypeEnum = BreakpointTypeEnum.MD;

  private constructor() {
  }

  public static getInstance(): BreakpointSystem {
    if (!BreakpointSystem.instance) {
      BreakpointSystem.instance = new BreakpointSystem();
    }
    return BreakpointSystem.instance;
  }

  public updateCurrentBreakpoint(breakpoint: BreakpointTypeEnum): void {
    if (this.currentBreakpoint !== breakpoint) {
      this.currentBreakpoint = breakpoint;
      AppStorage.setOrCreate('currentBreakpoint', this.currentBreakpoint);
    }
  }

  public onWindowSizeChange(window: window.Window): void {
    this.updateWidthBp(window);
  }

  public updateWidthBp(window: window.Window): void {
    try {
      const mainWindow: window.WindowProperties = window.getWindowProperties();
      const windowWidth: number = mainWindow.windowRect.width;
      const windowWidthVp: number = window.getUIContext().px2vp(windowWidth);
      let widthBp: BreakpointTypeEnum = BreakpointTypeEnum.MD;
      if (windowWidthVp < 320) {
        widthBp = BreakpointTypeEnum.XS;
      } else if (windowWidthVp >= 320 && windowWidthVp < 600) {
        widthBp = BreakpointTypeEnum.SM;
      } else if (windowWidthVp >= 600 && windowWidthVp < 840) {
        widthBp = BreakpointTypeEnum.MD;
      } else if (windowWidthVp >= 840 && windowWidthVp < 1440) {
        widthBp = BreakpointTypeEnum.LG;
      } else {
        widthBp = BreakpointTypeEnum.XL;
      }
      this.updateCurrentBreakpoint(widthBp);
    } catch (err) {
      Logger.error(TAG, `updateWidthBp failed, err.code:${err.code}, err.message:${err.message}`);
    }
  }
}