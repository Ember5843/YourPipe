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

/** 日志级别类型 */
export type LogSinkLevel = 'DEBUG' | 'INFO' | 'WARN' | 'ERROR';

/** 外部注入的日志 sink 函数类型 */
export type LogSinkFn = (level: LogSinkLevel, tag: string, message: string) => void;

export class EnhancedLogger {
  private prefix: string = '';
  private tags: string[] = [];
  private domain: number = 0xFF00;
  private static instances: Map<string, EnhancedLogger> = new Map();

  /** 由 entry 侧注入的日志 sink，默认 no-op */
  private static sink: LogSinkFn = (_l, _t, _m) => {};

  constructor(prefix: string, tags: string[]) {
    this.prefix = prefix;
    this.tags = tags;
  }

  /**
   * 创建或获取增强日志实例
   * @param prefix 日志前缀
   * @param tags 标签数组，从左至右粒度依次减小
   * @returns 增强日志实例
   */
  static getInstance(prefix: string, ...tags: string[]): EnhancedLogger {
    const key = `${prefix}:${tags.join(':')}`;
    if (!EnhancedLogger.instances.has(key)) {
      EnhancedLogger.instances.set(key, new EnhancedLogger(prefix, tags));
    }
    return EnhancedLogger.instances.get(key) as EnhancedLogger;
  }

  /**
   * 注入日志 sink（在 EntryAbility.onCreate 中调用）
   */
  static setSink(fn: LogSinkFn): void {
    EnhancedLogger.sink = fn;
  }

  /**
   * 获取标签字符串
   * @returns 格式化的标签字符串
   */
  private getTagString(): string {
    if (this.tags.length === 0) {
      return this.prefix;
    }
    return `${this.prefix}[${this.tags.join('][')}]`;
  }

  private write(level: LogSinkLevel, message: string, args: Object[]): void {
    const tag = this.getTagString();
    const logArgs = [message, ...args].join(', ');
    switch (level) {
      case 'DEBUG':
        hilog.debug(this.domain, tag, '%{public}s', logArgs);
        break;
      case 'INFO':
        hilog.info(this.domain, tag, '%{public}s', logArgs);
        break;
      case 'WARN':
        hilog.warn(this.domain, tag, '%{public}s', logArgs);
        break;
      case 'ERROR':
        hilog.error(this.domain, tag, '%{public}s', logArgs);
        break;
    }
    EnhancedLogger.sink(level, tag, logArgs);
  }

  /**
   * 调试级别日志
   * @param message 日志消息
   * @param args 附加参数
   */
  debug(message: string, ...args: Object[]): void {
    this.write('DEBUG', message, args);
  }

  /**
   * 信息级别日志
   * @param message 日志消息
   * @param args 附加参数
   */
  info(message: string, ...args: Object[]): void {
    this.write('INFO', message, args);
  }

  /**
   * 警告级别日志
   * @param message 日志消息
   * @param args 附加参数
   */
  warn(message: string, ...args: Object[]): void {
    this.write('WARN', message, args);
  }

  /**
   * 错误级别日志
   * @param message 日志消息
   * @param args 附加参数
   */
  error(message: string, ...args: Object[]): void {
    this.write('ERROR', message, args);
  }
}
