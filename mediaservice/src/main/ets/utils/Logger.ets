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

import { hilog } from '@kit.PerformanceAnalysisKit';
import { EnhancedLogger } from './EnhancedLogger';

export class Logger {
  private domain: number;
  private prefix: string;
  private format: string = '%{public}s, %{public}s';

  constructor(prefix: string) {
    this.prefix = prefix;
    this.domain = 0xFF00;
  }

  debug(...args: string[]): void {
    hilog.debug(this.domain, this.prefix, this.format, args);
    EnhancedLogger.dispatchToSink('DEBUG', this.prefix, args.join(', '));
  }

  info(...args: string[]): void {
    hilog.info(this.domain, this.prefix, this.format, args);
    EnhancedLogger.dispatchToSink('INFO', this.prefix, args.join(', '));
  }

  longInfo(tag: string, message: string): void {
    const maxLength = 1000;
    if (message.length <= maxLength) {
      this.info(tag, message);
      return;
    }

    let offset = 0;
    let part = 1;
    const totalParts = Math.ceil(message.length / maxLength);
    
    while (offset < message.length) {
      const chunk = message.substring(offset, offset + maxLength);
      this.info(tag, `[Part ${part}/${totalParts}] ${chunk}`);
      offset += maxLength;
      part++;
    }
  }

  warn(...args: string[]): void {
    hilog.warn(this.domain, this.prefix, this.format, args);
    EnhancedLogger.dispatchToSink('WARN', this.prefix, args.join(', '));
  }

  error(...args: string[]): void {
    hilog.error(this.domain, this.prefix, this.format, args);
    EnhancedLogger.dispatchToSink('ERROR', this.prefix, args.join(', '));
  }
}

export default new Logger('[VideoPlayerSample]');