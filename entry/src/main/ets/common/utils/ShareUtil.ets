import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor as utd } from '@kit.ArkData';
import common from '@ohos.app.ability.common';
import { AppLog } from '../AppLog';

const logger = AppLog.getInstance('ShareUtil');

/**
 * 纯文本系统分享（标题 + URL 两行）。统一收口原先散落在
 * Index / UserPage / PlaylistDetailPage / VideoDetails 的五份复制实现。
 *
 * @param options 透传 ShareControllerOptions（anchor 用于标题栏按钮定位，
 *   或 selectionMode: SINGLE）；缺省 SINGLE 选择模式
 * @param onError 额外的失败回调（如结束播放器 overlay）；失败始终会记日志
 */
export function sharePlainText(
  uiContext: UIContext,
  title: string,
  url: string,
  options?: systemShare.ShareControllerOptions,
  onError?: (err: Object) => void
): void {
  try {
    const content = url ? `${title}\n${url}` : title;
    const data: systemShare.SharedData = new systemShare.SharedData({
      utd: utd.UniformDataType.PLAIN_TEXT,
      content
    });
    const controller: systemShare.ShareController = new systemShare.ShareController(data);
    const context: common.UIAbilityContext = uiContext.getHostContext() as common.UIAbilityContext;
    controller.show(context, options ?? { selectionMode: systemShare.SelectionMode.SINGLE })
      .catch((err: Object) => {
        logger.error('share panel failed:', JSON.stringify(err));
        if (onError) {
          onError(err);
        }
      });
  } catch (err) {
    logger.error('share failed:', JSON.stringify(err));
    if (onError) {
      onError(err as Object);
    }
  }
}
