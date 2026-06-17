/**
 * 错误信息数据类
 * 用于统一管理各类错误的展示信息和行为
 */

export interface ErrorInfoOptions {
  isRetryable?: boolean;
  openInBrowserUrl?: string;
  actionHint?: string | Resource;
  exception?: Error;
}

export class ErrorInfo {
  /** 错误码（用于日志和分析） */
  errorCode: string;

  /** 用户可见的错误消息 */
  message: string | Resource;

  /** 是否可以通过重试解决 */
  isRetryable: boolean;

  /** 浏览器打开的 URL（可选，用于年龄限制等场景） */
  openInBrowserUrl?: string;

  /** 额外的操作提示（如"通过设置登录即可观看"） */
  actionHint?: string | Resource;

  /** 原始异常对象（可选，用于调试和报告） */
  exception?: Error;

  constructor(
    errorCode: string,
    message: string | Resource,
    options?: ErrorInfoOptions
  ) {
    this.errorCode = errorCode;
    this.message = message;
    this.isRetryable = options?.isRetryable ?? true;
    this.openInBrowserUrl = options?.openInBrowserUrl;
    this.actionHint = options?.actionHint;
    this.exception = options?.exception;
  }

  /**
   * 获取错误图标（根据错误类型）
   */
  getIcon(): Resource {
    if (this.errorCode.includes('AGE_RESTRICTED')) {
      return $r('sys.symbol.info_circle');
    }
    if (this.errorCode.includes('GEO_RESTRICTED')) {
      return $r('sys.symbol.map');
    }
    if (this.errorCode.includes('PAID') || this.errorCode.includes('PREMIUM')) {
      return $r('sys.symbol.lock_fill');
    }
    if (this.errorCode.includes('PRIVATE')) {
      return $r('sys.symbol.eye_slash');
    }
    if (this.errorCode.includes('LOGIN')) {
      return $r('sys.symbol.person');
    }
    if (this.errorCode.includes('NETWORK') || this.errorCode.includes('TIMEOUT')) {
      return $r('sys.symbol.wifi_slash');
    }
    return $r('sys.symbol.exclamationmark_triangle_fill');
  }
}
