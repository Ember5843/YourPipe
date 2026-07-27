import { http } from '@kit.NetworkKit';
import { bundleManager } from '@kit.AbilityKit';
import { HttpDownloader } from 'youtube_core';
import { AppLog } from './AppLog';

const logger = AppLog.getInstance('UpdateChecker');

const RELEASE_API_URL = 'https://api.github.com/repos/Ember5843/YourPipe/releases/latest';
const VERSION_ASSET_NAME = 'version.json';

export const APPGALLERY_TEST_URL = 'https://appgallery.huawei.com/apptest/AOd7gmH8iD5';
export const GITHUB_REPO_URL = 'https://github.com/Ember5843/YourPipe';

export type UpdateCheckStatus = 'upToDate' | 'updateAvailable' | 'failed';

export interface UpdateCheckResult {
  status: UpdateCheckStatus;
  localVersionName: string;
  localVersionCode: number;
  remoteVersionName: string;
  remoteVersionCode: number;
  releaseUrl: string;
  notes: string;
  error?: string;
}

interface GithubReleaseAsset {
  name?: string;
  browser_download_url?: string;
}

interface GithubRelease {
  tag_name?: string;
  name?: string;
  html_url?: string;
  body?: string;
  assets?: GithubReleaseAsset[];
}

interface RemoteVersionJson {
  versionName?: string;
  versionCode?: number;
}

interface LocalVersion {
  versionName: string;
  versionCode: number;
}

const MAX_NOTES_CHARS = 400;

export class UpdateChecker {
  static async check(): Promise<UpdateCheckResult> {
    const local = await UpdateChecker.readLocalVersion();
    const result: UpdateCheckResult = {
      status: 'failed',
      localVersionName: local.versionName,
      localVersionCode: local.versionCode,
      remoteVersionName: '',
      remoteVersionCode: 0,
      releaseUrl: GITHUB_REPO_URL,
      notes: ''
    };
    try {
      logger.info(`check start local=${local.versionName}(${local.versionCode})`);
      const releaseRaw = await UpdateChecker.requestText(RELEASE_API_URL);
      const release = JSON.parse(releaseRaw) as GithubRelease;
      result.releaseUrl = release.html_url || GITHUB_REPO_URL;
      result.notes = UpdateChecker.trimNotes(release.body || '');
      const remote = await UpdateChecker.resolveRemoteVersion(release);
      result.remoteVersionName = remote.versionName;
      result.remoteVersionCode = remote.versionCode;
      const hasUpdate = remote.versionCode > 0
        ? remote.versionCode > local.versionCode
        : UpdateChecker.compareVersionNames(remote.versionName, local.versionName) > 0;
      result.status = hasUpdate ? 'updateAvailable' : 'upToDate';
      logger.info(`check done status=${result.status} remote=${remote.versionName}(${remote.versionCode}) ` +
        `via=${remote.versionCode > 0 ? 'versionCode' : 'versionName'}`);
      return result;
    } catch (e) {
      result.error = (e as Error).message || String(e);
      logger.error(`check failed: ${result.error}`);
      return result;
    }
  }

  private static async readLocalVersion(): Promise<LocalVersion> {
    try {
      const info = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const local: LocalVersion = { versionName: info.versionName, versionCode: info.versionCode };
      return local;
    } catch (e) {
      logger.warn(`readLocalVersion failed, fallback constants: ${String(e)}`);
      const fallback: LocalVersion = { versionName: '0.5.7', versionCode: 1000016 };
      return fallback;
    }
  }

  private static async resolveRemoteVersion(release: GithubRelease): Promise<LocalVersion> {
    const assets = release.assets || [];
    for (const asset of assets) {
      if (asset.name === VERSION_ASSET_NAME && asset.browser_download_url) {
        try {
          const raw = await UpdateChecker.requestText(asset.browser_download_url);
          const parsed = JSON.parse(raw) as RemoteVersionJson;
          const code = parsed.versionCode ?? 0;
          if (code > 0) {
            const remote: LocalVersion = { versionName: parsed.versionName || '', versionCode: code };
            return remote;
          }
        } catch (e) {
          logger.warn(`version.json asset parse failed: ${String(e)}`);
        }
      }
    }
    // Fallback: versionName from tag only (older releases without the asset).
    const fallback: LocalVersion = {
      versionName: UpdateChecker.normalizeVersionName(release.tag_name || ''),
      versionCode: 0
    };
    return fallback;
  }

  static normalizeVersionName(tag: string): string {
    return tag.trim().replace(/^[vV]/, '');
  }

  /** Numeric dotted compare: 0.5.10 > 0.5.6. Returns >0 when a > b. */
  static compareVersionNames(a: string, b: string): number {
    const pa = UpdateChecker.normalizeVersionName(a).split('.');
    const pb = UpdateChecker.normalizeVersionName(b).split('.');
    const len = Math.max(pa.length, pb.length);
    for (let i = 0; i < len; i++) {
      const na = i < pa.length ? (parseInt(pa[i], 10) || 0) : 0;
      const nb = i < pb.length ? (parseInt(pb[i], 10) || 0) : 0;
      if (na !== nb) {
        return na - nb;
      }
    }
    return 0;
  }

  private static trimNotes(body: string): string {
    const trimmed = body.trim();
    if (trimmed.length <= MAX_NOTES_CHARS) {
      return trimmed;
    }
    return trimmed.substring(0, MAX_NOTES_CHARS) + '…';
  }

  private static requestText(url: string): Promise<string> {
    const request = http.createHttp();
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: {
        'User-Agent': 'YourPipe-UpdateChecker',
        'Accept': 'application/vnd.github+json'
      },
      connectTimeout: 10000,
      readTimeout: 15000
    };
    HttpDownloader.applyProxyToOptions(options, url);
    return request.request(url, options).then((response: http.HttpResponse) => {
      if (response.responseCode !== 200) {
        throw new Error(`HTTP ${response.responseCode} for ${url}`);
      }
      return typeof response.result === 'string' ? response.result : String(response.result);
    }).finally(() => {
      request.destroy();
    });
  }
}
