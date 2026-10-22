import { common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { AppLog } from '../AppLog';

const logger = AppLog.getInstance('ExternalLink');

/**
 * 在系统浏览器打开外部链接。
 * - 空链接（条目尚未确定官网）只提示，不发起请求。
 * - openLink 是异步的，失败在 catch 里提示，不向调用方抛错。
 * 日志只记录条目名 what，不打印完整 URL（可能带跟踪参数）。
 */
export function openExternalUrl(
  uiContext: UIContext,
  url: string,
  what: string,
  unavailableText: ResourceStr,
  failedText: ResourceStr
): void {
  if (url.length === 0) {
    logger.warn(`external link unavailable what=${what}`);
    uiContext.getPromptAction().showToast({ message: unavailableText, duration: 2000 });
    return;
  }
  try {
    logger.info(`external link open what=${what}`);
    const context = uiContext.getHostContext() as common.UIAbilityContext;
    context.openLink(url, { appLinkingOnly: false }).catch((error: Object) => {
      logger.error(`external link failed what=${what}`, error);
      uiContext.getPromptAction().showToast({ message: failedText, duration: 2000 });
    });
  } catch (error) {
    logger.error(`external link failed what=${what}`, error as Object);
    uiContext.getPromptAction().showToast({ message: failedText, duration: 2000 });
  }
}
