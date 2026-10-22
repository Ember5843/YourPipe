import { common } from '@kit.AbilityKit';
import { UIContext } from '@kit.ArkUI';
import { PreferencesStore } from './PreferencesStore';
import { UpdateCheckResult } from './UpdateChecker';
import { openExternalUrl } from './utils/ExternalLinkUtil';

const PROMPTED_KEY: string = 'cfg_last_prompted_update_code';

function promptKey(result: UpdateCheckResult): string {
  return result.remoteVersionCode > 0
    ? `${result.remoteVersionCode}`
    : result.remoteVersionName;
}

/** 同一个版本只主动提示一次；升级/恢复默认后重新允许提示。 */
export function shouldPromptStartupUpdate(result: UpdateCheckResult): boolean {
  if (result.status !== 'updateAvailable' || result.source !== 'startup') {
    return false;
  }
  const key = promptKey(result);
  if (key.length === 0) {
    return false;
  }
  return PreferencesStore.getString(PROMPTED_KEY, '') !== key;
}

export function markStartupUpdatePrompted(result: UpdateCheckResult): void {
  const key = promptKey(result);
  if (key.length > 0) {
    PreferencesStore.setString(PROMPTED_KEY, key);
  }
}

export function resetStartupUpdatePrompted(): void {
  PreferencesStore.setString(PROMPTED_KEY, '');
}

/** 发现新版本对话框（启动/手动共用）。 */
export function showUpdateAvailableDialog(uiContext: UIContext, result: UpdateCheckResult): void {
  const host = uiContext.getHostContext() as common.UIAbilityContext;
  const rm = host.resourceManager;
  const versionLine = `v${result.remoteVersionName}`
    + (result.remoteVersionCode > 0 ? ` (${result.remoteVersionCode})` : '');
  const lines: string[] = [
    `${rm.getStringSync($r('app.string.yt_update_current_version').id)} `
      + `v${result.localVersionName} (${result.localVersionCode})`,
    `${rm.getStringSync($r('app.string.yt_update_new_version').id)} ${versionLine}`
  ];
  if (result.publishedAt.length > 0) {
    lines.push(`${rm.getStringSync($r('app.string.yt_update_release_time').id)} ${result.publishedAt}`);
  }
  if (result.notes.length > 0) {
    lines.push('');
    lines.push(result.notes);
  }

  AlertDialog.show({
    title: rm.getStringSync($r('app.string.yt_update_available').id),
    message: lines.join('\n'),
    alignment: DialogAlignment.Center,
    primaryButton: {
      value: $r('app.string.yt_update_open_github'),
      action: () => {
        openExternalUrl(uiContext, result.releaseUrl, 'release',
          $r('app.string.yt_about_link_unavailable'),
          $r('app.string.yt_about_link_failed'));
      }
    },
    secondaryButton: {
      value: $r('app.string.yt_update_later'),
      action: () => {}
    }
  });
}

/** 无更新 / 失败 / 被开关阻止时的单按钮提示。 */
export function showUpdateMessageDialog(uiContext: UIContext, title: ResourceStr, message: ResourceStr): void {
  AlertDialog.show({
    title: title,
    message: message,
    alignment: DialogAlignment.Center,
    primaryButton: {
      value: $r('app.string.yt_update_ok'),
      action: () => {}
    }
  });
}
