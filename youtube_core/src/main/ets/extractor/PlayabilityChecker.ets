import { YTCoreLogger } from '../common/YTCoreLogger';
import { getTextFromObject } from '../common/YoutubeParsingHelper';
import { PlayabilityStatus, TextRuns } from './PlayerResponseTypes';
import {
  AgeRestrictedContentException,
  PrivateContentException,
  PaidContentException,
  YoutubeMusicPremiumContentException,
  GeographicRestrictionException,
  LoginRequiredException,
  AccountTerminatedException,
  LiveStreamOfflineException,
  SignInConfirmNotBotException,
  ContentNotAvailableException
} from './YouTubeExceptions';

const logger = YTCoreLogger.getInstance('PlayabilityChecker');

/**
 * PlayabilityStatus → 类型化异常 的判定逻辑（NewPipe/PipePipe 语义）。
 * 从 YouTubeExtractor 拆出；全部为无状态静态方法。
 */
export class PlayabilityChecker {
  private static extractText(textRuns?: TextRuns): string {
    return getTextFromObject(textRuns as Record<string, Object>);
  }

  /**
   * Resolve human-readable playability reason from either direct `reason` string
   * (WEB metadata player) or errorScreen runs (watch HTML / stream clients).
   */
  static resolveReason(playabilityStatus: PlayabilityStatus | undefined): string {
    if (!playabilityStatus) {
      return '';
    }
    if (playabilityStatus.reason && playabilityStatus.reason.length > 0) {
      return playabilityStatus.reason;
    }
    return PlayabilityChecker.extractText(playabilityStatus.errorScreen?.playerErrorMessageRenderer?.reason);
  }

  /**
   * PipePipe getWebPlayerResponse: only LOGIN_REQUIRED / age-gate hard-fail here.
   * WEB $fields metadata often returns UNPLAYABLE while the stream client (mweb)
   * is still OK — do not abort the whole extract on metadata status alone.
   */
  static checkWebMetadata(playabilityStatus: PlayabilityStatus | undefined): void {
    if (!playabilityStatus) {
      return;
    }
    const status = playabilityStatus.status?.toUpperCase();
    if (!status || status === 'OK') {
      return;
    }
    if (status === 'LOGIN_REQUIRED') {
      const reason = PlayabilityChecker.resolveReason(playabilityStatus);
      const reasonLower = reason.toLowerCase();
      if (reasonLower.includes('age') || reasonLower.includes('inappropriate')) {
        throw new AgeRestrictedContentException('This age-restricted video cannot be watched anonymously');
      }
      if (playabilityStatus.desktopLegacyAgeGateReason !== undefined
        && playabilityStatus.desktopLegacyAgeGateReason !== null
        && playabilityStatus.desktopLegacyAgeGateReason !== false
        && playabilityStatus.desktopLegacyAgeGateReason !== 0
        && playabilityStatus.desktopLegacyAgeGateReason !== '0') {
        throw new AgeRestrictedContentException('This age-restricted video cannot be watched anonymously');
      }
      throw new SignInConfirmNotBotException(reason || 'Login required / anti-bot');
    }
    // Soft: metadata WEB may be blocked/unplayable while stream player has streamingData.
    const reason = PlayabilityChecker.resolveReason(playabilityStatus);
    logger.warn(`[META] WEB metadata playability ignored status=${status} reason=${reason || '(none)'}`);
  }

  /**
   * Check playability status (stream/watch player responses — hard-fail taxonomy).
   */
  static check(playabilityStatus: PlayabilityStatus | undefined): void {
    if (!playabilityStatus) {
      logger.warn('No playabilityStatus in playerResponse');
      return;
    }

    const status: string | undefined = playabilityStatus.status;

    if (!status || status.toUpperCase() === 'OK') {
      return;
    }

    logger.info(`Playability status: ${status}`);

    const reason = PlayabilityChecker.resolveReason(playabilityStatus);
    const reasonLower = reason.toLowerCase();

    if (status.toUpperCase() === 'LOGIN_REQUIRED') {
      if (reasonLower.includes('inappropriate for some users') || reasonLower.includes('age')) {
        throw new AgeRestrictedContentException('Age restricted content');
      }
      if (reasonLower.includes('private')) {
        throw new PrivateContentException('Private video');
      }
      if (reasonLower.includes('bot')) {
        throw new SignInConfirmNotBotException('Bot protection triggered');
      }
      // Age-restricted may also show with "Sign in to confirm your age"
      if (reasonLower.includes('confirm your age')) {
        throw new AgeRestrictedContentException('Age restricted content (confirm age)');
      }
      if (playabilityStatus.desktopLegacyAgeGateReason !== undefined
        && playabilityStatus.desktopLegacyAgeGateReason !== null
        && playabilityStatus.desktopLegacyAgeGateReason !== false
        && playabilityStatus.desktopLegacyAgeGateReason !== 0
        && playabilityStatus.desktopLegacyAgeGateReason !== '0') {
        throw new AgeRestrictedContentException('Age restricted content (desktop age gate)');
      }
      throw new LoginRequiredException('Login required');
    }

    if (status.toUpperCase() === 'UNPLAYABLE' || status.toUpperCase() === 'ERROR') {
      if (reasonLower.includes('music premium')) {
        throw new YoutubeMusicPremiumContentException('Music Premium content');
      }
      if (reasonLower.includes('payment') || reasonLower.includes('paid') ||
          reasonLower.includes('purchase') || reasonLower.includes('rent') ||
          reasonLower.includes('buy') || reasonLower.includes('members-only') ||
          reasonLower.includes('members')) {
        throw new PaidContentException('Paid content');
      }
      if (reasonLower.includes('country') || reasonLower.includes('geo') ||
          reasonLower.includes('region') || reasonLower.includes('available in your country')) {
        throw new GeographicRestrictionException('Geo restricted');
      }
      if (reasonLower.includes('closed') || reasonLower.includes('terminated')) {
        throw new AccountTerminatedException('Account terminated');
      }
      if (reasonLower.includes('unavailable')) {
        const subreason = PlayabilityChecker.extractText(
          playabilityStatus.errorScreen?.playerErrorMessageRenderer?.subreason);
        if (subreason && (subreason.toLowerCase().includes('country') ||
            subreason.toLowerCase().includes('region') ||
            subreason.toLowerCase().includes('available in your'))) {
          throw new GeographicRestrictionException('Geo restricted');
        }
        if (subreason) {
          throw new ContentNotAvailableException(subreason);
        }
        throw new ContentNotAvailableException(reason);
      }
      if (reasonLower.includes('this live event')) {
        throw new LiveStreamOfflineException('Live event not started');
      }
      if (reasonLower.includes('premieres in')) {
        throw new ContentNotAvailableException('Premiere not started');
      }
    }

    if (status.toUpperCase() === 'LIVE_STREAM_OFFLINE') {
      throw new LiveStreamOfflineException('Live offline');
    }

    if (status.toUpperCase() === 'UNAVAILABLE') {
      throw new ContentNotAvailableException('Content unavailable');
    }

    const errorMsg = reason ? `Unplayable: ${reason}` : `Unplayable: ${status}`;
    throw new ContentNotAvailableException(errorMsg);
  }
}
