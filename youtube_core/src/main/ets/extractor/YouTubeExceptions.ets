/**
 * YouTube 提取器异常类层次结构
 * 对应 NewPipe: org.schabi.newpipe.extractor.exceptions.*
 */

/**
 * 基础提取异常
 */
export class ExtractorException extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ExtractorException';
  }
}

/**
 * 内容不可用异常（基类）
 * 对应 NewPipe: ContentNotAvailableException
 */
export class ContentNotAvailableException extends ExtractorException {
  constructor(message: string) {
    super(message);
    this.name = 'ContentNotAvailableException';
  }
}

/**
 * 年龄限制内容异常
 * 对应 NewPipe: AgeRestrictedContentException
 */
export class AgeRestrictedContentException extends ContentNotAvailableException {
  constructor(message: string) {
    super(message);
    this.name = 'AgeRestrictedContentException';
  }
}

/**
 * 私有内容异常
 * 对应 NewPipe: PrivateContentException
 */
export class PrivateContentException extends ContentNotAvailableException {
  constructor(message: string) {
    super(message);
    this.name = 'PrivateContentException';
  }
}

/**
 * 付费内容异常
 * 对应 NewPipe: PaidContentException
 */
export class PaidContentException extends ContentNotAvailableException {
  constructor(message: string) {
    super(message);
    this.name = 'PaidContentException';
  }
}

/**
 * YouTube Premium 内容异常
 * 对应 NewPipe: YoutubeMusicPremiumContentException
 */
export class YoutubeMusicPremiumContentException extends ContentNotAvailableException {
  constructor(message: string) {
    super(message);
    this.name = 'YoutubeMusicPremiumContentException';
  }
}

/**
 * 地区限制异常
 * 对应 NewPipe: GeographicRestrictionException
 */
export class GeographicRestrictionException extends ContentNotAvailableException {
  constructor(message: string) {
    super(message);
    this.name = 'GeographicRestrictionException';
  }
}

/**
 * 需要登录异常
 * 对应 NewPipe: LoginRequiredException
 */
export class LoginRequiredException extends ContentNotAvailableException {
  constructor(message: string) {
    super(message);
    this.name = 'LoginRequiredException';
  }
}

/**
 * 账号终止异常
 * 对应 NewPipe: AccountTerminatedException
 */
export class AccountTerminatedException extends ContentNotAvailableException {
  constructor(message: string) {
    super(message);
    this.name = 'AccountTerminatedException';
  }
}

/**
 * 直播未开始异常
 */
export class LiveStreamOfflineException extends ContentNotAvailableException {
  constructor(message: string) {
    super(message);
    this.name = 'LiveStreamOfflineException';
  }
}

/**
 * 机器人检测异常
 * 对应 NewPipe: SignInConfirmNotBotException
 */
export class SignInConfirmNotBotException extends ContentNotAvailableException {
  constructor(message: string) {
    super(message);
    this.name = 'SignInConfirmNotBotException';
  }
}

/**
 * 内容不支持异常
 */
export class ContentNotSupportedException extends ExtractorException {
  constructor(message: string) {
    super(message);
    this.name = 'ContentNotSupportedException';
  }
}

/**
 * 所选客户端无任何可用流。可能是 player 元数据（STS/cipher）过期导致全部
 * URL 解密失败后被过滤，上层可刷新 player 元数据后重试一次。
 */
export class NoPlayableStreamsException extends ContentNotSupportedException {
  constructor(message: string) {
    super(message);
    this.name = 'NoPlayableStreamsException';
  }
}

/**
 * 提取失败异常（通用）
 */
export class ExtractionException extends ExtractorException {
  constructor(message: string) {
    super(message);
    this.name = 'ExtractionException';
  }
}

/**
 * 流 URL 解密（签名 / n 参数）失败——通常是 player 元数据过期，
 * 上层可刷新 player 元数据后重试一次。
 */
export class StreamDeobfuscationException extends ExtractionException {
  constructor(message: string) {
    super(message);
    this.name = 'StreamDeobfuscationException';
  }
}
