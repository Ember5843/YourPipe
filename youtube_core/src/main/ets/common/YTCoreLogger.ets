import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0xFF00;

export type YTCoreLogSinkFn = (level: 'DEBUG' | 'INFO' | 'WARN' | 'ERROR', tag: string, message: string) => void;

export class YTCoreLogger {
  private tag: string;
  private static sink: YTCoreLogSinkFn | null = null;
  private static instances = new Map<string, YTCoreLogger>();
  private static defaultInstance = new YTCoreLogger('YourPipe-Core');

  private constructor(tag: string) {
    this.tag = tag;
  }

  static getInstance(tag: string): YTCoreLogger {
    if (!YTCoreLogger.instances.has(tag)) {
      YTCoreLogger.instances.set(tag, new YTCoreLogger(tag));
    }
    return YTCoreLogger.instances.get(tag)!;
  }

  static setSink(fn: YTCoreLogSinkFn): void {
    YTCoreLogger.sink = fn;
  }

  // Instance methods
  debug(message: string, ...args: Object[]): void {
    const logArgs = [message, ...args].join(' ');
    hilog.debug(DOMAIN, `YTC-${this.tag}`, '%{public}s', logArgs);
    if (YTCoreLogger.sink) {
      YTCoreLogger.sink('DEBUG', this.tag, logArgs);
    }
  }

  info(message: string, ...args: Object[]): void {
    const logArgs = [message, ...args].join(' ');
    hilog.info(DOMAIN, `YTC-${this.tag}`, '%{public}s', logArgs);
    if (YTCoreLogger.sink) {
      YTCoreLogger.sink('INFO', this.tag, logArgs);
    }
  }

  log(message: string, ...args: Object[]): void {
    const logArgs = [message, ...args].join(' ');
    hilog.info(DOMAIN, `YTC-${this.tag}`, '%{public}s', logArgs);
    if (YTCoreLogger.sink) {
      YTCoreLogger.sink('INFO', this.tag, logArgs);
    }
  }

  warn(message: string, ...args: Object[]): void {
    const logArgs = [message, ...args].join(' ');
    hilog.warn(DOMAIN, `YTC-${this.tag}`, '%{public}s', logArgs);
    if (YTCoreLogger.sink) {
      YTCoreLogger.sink('WARN', this.tag, logArgs);
    }
  }

  error(message: string, ...args: Object[]): void {
    const logArgs = [message, ...args].join(' ');
    hilog.error(DOMAIN, `YTC-${this.tag}`, '%{public}s', logArgs);
    if (YTCoreLogger.sink) {
      YTCoreLogger.sink('ERROR', this.tag, logArgs);
    }
  }

  // Static fallback methods (will use default tag)
  static debug(message: string, ...args: Object[]): void {
    YTCoreLogger.defaultInstance.debug(message, ...args);
  }

  static info(message: string, ...args: Object[]): void {
    YTCoreLogger.defaultInstance.info(message, ...args);
  }

  static log(message: string, ...args: Object[]): void {
    YTCoreLogger.defaultInstance.log(message, ...args);
  }

  static warn(message: string, ...args: Object[]): void {
    YTCoreLogger.defaultInstance.warn(message, ...args);
  }

  static error(message: string, ...args: Object[]): void {
    YTCoreLogger.defaultInstance.error(message, ...args);
  }
}
