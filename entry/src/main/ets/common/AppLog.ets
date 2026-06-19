import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppLogStore } from './AppLogStore';

const DOMAIN = 0xFF00;
const TAG = 'YourPipe-App';

export class AppLog {
  private tag: string;
  private static instances = new Map<string, AppLog>();
  private static defaultInstance = new AppLog('YourPipe-App');

  private constructor(tag: string) {
    this.tag = tag;
  }

  static getInstance(tag: string): AppLog {
    if (!AppLog.instances.has(tag)) {
      AppLog.instances.set(tag, new AppLog(tag));
    }
    return AppLog.instances.get(tag)!;
  }

  // Instance methods
  debug(message: string, ...args: Object[]): void {
    const logArgs = [message, ...args].join(' ');
    hilog.debug(DOMAIN, this.tag, '%{public}s', logArgs);
    AppLogStore.push('DEBUG', this.tag, logArgs);
  }

  info(message: string, ...args: Object[]): void {
    const logArgs = [message, ...args].join(' ');
    hilog.info(DOMAIN, this.tag, '%{public}s', logArgs);
    AppLogStore.push('INFO', this.tag, logArgs);
  }

  log(message: string, ...args: Object[]): void {
    const logArgs = [message, ...args].join(' ');
    hilog.info(DOMAIN, this.tag, '%{public}s', logArgs);
    AppLogStore.push('INFO', this.tag, logArgs);
  }

  warn(message: string, ...args: Object[]): void {
    const logArgs = [message, ...args].join(' ');
    hilog.warn(DOMAIN, this.tag, '%{public}s', logArgs);
    AppLogStore.push('WARN', this.tag, logArgs);
  }

  error(message: string, ...args: Object[]): void {
    const logArgs = [message, ...args].join(' ');
    hilog.error(DOMAIN, this.tag, '%{public}s', logArgs);
    AppLogStore.push('ERROR', this.tag, logArgs);
  }

  // Static fallback methods (will use default tag)
  static debug(message: string, ...args: Object[]): void {
    AppLog.defaultInstance.debug(message, ...args);
  }

  static info(message: string, ...args: Object[]): void {
    AppLog.defaultInstance.info(message, ...args);
  }

  static log(message: string, ...args: Object[]): void {
    AppLog.defaultInstance.log(message, ...args);
  }

  static warn(message: string, ...args: Object[]): void {
    AppLog.defaultInstance.warn(message, ...args);
  }

  static error(message: string, ...args: Object[]): void {
    AppLog.defaultInstance.error(message, ...args);
  }
}
