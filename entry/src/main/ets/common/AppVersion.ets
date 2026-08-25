import { bundleManager } from '@kit.AbilityKit';
import { AppLog } from './AppLog';

const logger = AppLog.getInstance('AppVersion');

export interface AppVersionInfo {
  versionName: string;
  versionCode: number;
}

/**
 * Last-resort values only when bundleManager is unavailable. The single
 * source of truth is AppScope/app.json5 versionName/versionCode, read at
 * runtime through bundleManager.
 */
const FALLBACK_VERSION: AppVersionInfo = { versionName: '0.5.9', versionCode: 1000022 };

let cached: AppVersionInfo | null = null;

/** App version from AppScope/app.json5 via bundleManager; cached after first read. */
export function getAppVersion(): AppVersionInfo {
  if (cached) {
    return cached;
  }
  try {
    const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
    const resolved: AppVersionInfo = { versionName: info.versionName, versionCode: info.versionCode };
    cached = resolved;
    logger.info(`app version resolved name=${resolved.versionName} code=${resolved.versionCode}`);
  } catch (e) {
    logger.warn(`getBundleInfoForSelfSync failed, using fallback: ${String(e)}`);
    cached = FALLBACK_VERSION;
  }
  return cached;
}
