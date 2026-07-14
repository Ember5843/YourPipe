import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { OptionItem } from '../../common/components/OptionItem';
import { BackupItemPickerDialog } from '../../common/components/BackupItemPickerDialog';
import { UIConfig } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';
import {
  AuthAccountStatus,
  AuthSessionManager,
  AuthStage,
  CookieAuthCredential,
  YoutubePlayerClientConfig
} from 'youtube_core';
import { DataBackupManager, BackupError } from '../../common/DataBackupManager';
import { BackupItemKey, AppBackupData, ALL_BACKUP_ITEM_KEYS } from '../../common/model/BackupModels';
import { AuthStateHelper } from '../../common/AuthStateHelper';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { AppLog } from '../../common/AppLog';

const logger = AppLog.getInstance('OptionsDataAccountPage');

interface CookieVerifyResult {
  ok: boolean;
  detail: string;
}

interface OptionsDataAccountPageParams {
  /** Open Google WebView login (after notice dialog). */
  onLoginClick: () => void;
  updateUiConfig: (updater: (cfg: UIConfig) => void) => void;
  onHomeFeedStyleChanged: () => void;
  onAuthChanged: () => void;
}

@Component
export struct OptionsDataAccountPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('authStatus') authStatus: AuthAccountStatus = new AuthAccountStatus();

  @Prop params: OptionsDataAccountPageParams = {
    onLoginClick: () => {},
    updateUiConfig: () => {},
    onHomeFeedStyleChanged: () => {},
    onAuthChanged: () => {}
  };

  @State isBusy: boolean = false;
  @State private showCookieImport: boolean = false;
  @State private cookieInput: string = '';
  @State private cookieImportMessage: string = '';
  @State private isVerifyingCookie: boolean = false;
  private backupPickerController: CustomDialogController | null = null;
  private restorePickerController: CustomDialogController | null = null;
  private pendingRestoreBackup: AppBackupData | null = null;

  private hasCredential(): boolean {
    return this.authStatus.hasCredential
      || this.authStatus.hasCookieCredential
      || this.authStatus.hasRefreshToken
      || this.authStatus.stage === AuthStage.SIGNED_IN;
  }

  private isAuthActive(): boolean {
    return this.hasCredential() && this.authStatus.authEnabled !== false;
  }

  private getAccountTitle(): ResourceStr {
    if (!this.hasCredential()) {
      return $r('app.string.yt_option_google_login');
    }
    return $r('app.string.yt_option_auth_session');
  }

  private getAccountSubtitle(): string {
    if (!this.hasCredential()) {
      return '登录以获取个性化推荐';
    }
    if (this.isAuthActive()) {
      if (this.authStatus.authMode === 'cookie') {
        return '已登录 (Cookie) · 登录态浏览中';
      }
      return '已登录 · 登录态浏览中';
    }
    return '已保存登录 · 无痕浏览中';
  }

  private startLogin(): void {
    const uiContext = this.getUIContext();
    uiContext.showAlertDialog({
      title: '登录须知',
      message: '登录后可尝试加载个性化首页推荐，并用于解锁会员内容或绕过机器人拦截。可用开关临时关闭登录态（无痕浏览），不会清除已保存的登录。登录状态下分辨率最高限制为 1080P。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      offset: { dx: 0, dy: -20 },
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: '取消',
          action: () => {}
        },
        {
          value: '继续登录',
          fontColor: this.themePrimary,
          action: () => {
            this.params.onLoginClick();
          }
        }
      ],
      onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
        if (dismissDialogAction.reason === DismissReason.PRESS_BACK
          || dismissDialogAction.reason === DismissReason.TOUCH_OUTSIDE) {
          dismissDialogAction.dismiss();
        }
      }
    });
  }

  /**
   * Accept:
   * - Header form: `SID=...; SAPISID=...`
   * - EditThisCookie / Cookie-Editor JSON array: [{name,value,domain,...}, ...]
   */
  private parseCookieInput(raw: string): string {
    const trimmed = raw.trim();
    if (trimmed.length === 0) {
      return '';
    }
    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      const fromJson = this.parseCookieJson(trimmed);
      if (fromJson.length > 0) {
        return fromJson;
      }
    }
    return this.parseCookieHeaderForm(trimmed);
  }

  private parseCookieJson(raw: string): string {
    try {
      const parsed = JSON.parse(raw) as Object;
      const items: Object[] = parsed instanceof Array ? (parsed as Object[]) : [parsed];
      const pairs: string[] = [];
      const seen: Record<string, boolean> = {};
      for (let i = 0; i < items.length; i++) {
        const item = items[i] as Record<string, Object>;
        if (!item) {
          continue;
        }
        const name = `${item['name'] ?? ''}`.trim();
        const value = `${item['value'] ?? ''}`.trim();
        if (name.length === 0 || value.length === 0) {
          continue;
        }
        const domain = `${item['domain'] ?? ''}`.toLowerCase();
        // Prefer YouTube / Google cookies; skip empty-domain noise.
        if (domain.length > 0
          && domain.indexOf('youtube.com') < 0
          && domain.indexOf('google.com') < 0
          && domain.indexOf('google.') < 0) {
          continue;
        }
        if (seen[name]) {
          continue;
        }
        seen[name] = true;
        pairs.push(`${name}=${value}`);
      }
      return pairs.join('; ');
    } catch (_e) {
      return '';
    }
  }

  private parseCookieHeaderForm(raw: string): string {
    const pairs: string[] = [];
    const chunks = raw.replace(/\r/g, '\n').split(/[\n;]/);
    for (let i = 0; i < chunks.length; i++) {
      const part = chunks[i].trim();
      if (part.length === 0 || part.startsWith('#')) {
        continue;
      }
      const eq = part.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const name = part.substring(0, eq).trim();
      const value = part.substring(eq + 1).trim();
      if (name.length === 0 || value.length === 0) {
        continue;
      }
      if (name.indexOf('\t') >= 0) {
        continue;
      }
      pairs.push(`${name}=${value}`);
    }
    return pairs.join('; ');
  }

  private async verifyCookieOnline(): Promise<CookieVerifyResult> {
    try {
      const library = FeedServiceProvider.getInstance().getUserLibraryService();
      const page = await library.fetchWatchHistory(1);
      const success: CookieVerifyResult = {
        ok: true,
        detail: page.items.length > 0
          ? `在线校验通过（历史 ${page.items.length} 条）`
          : '在线校验通过（账号历史为空，但鉴权成功）'
      };
      return success;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      logger.warn(`cookie online verify failed: ${msg}`);
      if (msg.indexOf('Sign-in required') >= 0) {
        const failedSession: CookieVerifyResult = {
          ok: false,
          detail: '会话未生效，请重新导入'
        };
        return failedSession;
      }
      const failed: CookieVerifyResult = {
        ok: false,
        detail: `在线校验失败：${msg}`
      };
      return failed;
    }
  }

  private async importCookie(): Promise<void> {
    if (this.isVerifyingCookie) {
      return;
    }
    const raw = (this.cookieInput || '').trim();
    this.cookieImportMessage = '';
    if (raw.length === 0) {
      this.cookieImportMessage = '请粘贴 Cookie 字符串';
      return;
    }

    const cookies = this.parseCookieInput(raw);
    if (cookies.length === 0) {
      this.cookieImportMessage = '无法解析 Cookie（支持 header 或 EditThisCookie JSON）';
      return;
    }
    if (!CookieAuthCredential.hasSid(cookies) && CookieAuthCredential.parseSapiSid(cookies).length === 0) {
      this.cookieImportMessage = '本地校验失败：未找到 SID / SAPISID';
      return;
    }
    const credential = CookieAuthCredential.fromCookies(cookies, '');
    if (credential.sapiSid.length === 0) {
      this.cookieImportMessage = '本地校验失败：缺少 SAPISID（或 __Secure-3PAPISID）';
      return;
    }

    const session = AuthSessionManager.getInstance();
    if (!session) {
      this.cookieImportMessage = '认证模块未初始化';
      return;
    }

    session.saveCookieCredential(credential);
    AuthStateHelper.refresh();
    YoutubePlayerClientConfig.resetToAuthDefault(true);

    this.isVerifyingCookie = true;
    this.cookieImportMessage = '本地格式通过，正在向 YouTube 校验…';
    try {
      const result = await this.verifyCookieOnline();
      if (result.ok) {
        this.cookieInput = '';
        this.showCookieImport = false;
        this.cookieImportMessage = result.detail;
        this.params.onAuthChanged();
      } else {
        session.signOut();
        AuthStateHelper.refresh();
        this.cookieImportMessage = result.detail;
      }
    } finally {
      this.isVerifyingCookie = false;
    }
  }

  private onAuthToggle(enabled: boolean): void {
    if (!this.hasCredential()) {
      return;
    }
    AuthSessionManager.getInstance()?.setAuthEnabled(enabled);
    AuthStateHelper.refresh();
    const signedIn = enabled && this.hasCredential();
    YoutubePlayerClientConfig.resetToAuthDefault(signedIn);
    this.params.onAuthChanged();
  }

  private signOut(): void {
    AuthSessionManager.getInstance()?.signOut();
    AuthStateHelper.refresh();
    YoutubePlayerClientConfig.resetToAuthDefault(false);
    this.params.onAuthChanged();
  }

  private confirmSignOut(): void {
    const uiContext = this.getUIContext();
    uiContext.showAlertDialog({
      title: $r('app.string.yt_option_sign_out'),
      message: $r('app.string.yt_confirm_sign_out'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      offset: { dx: 0, dy: -20 },
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.yt_action_cancel'),
          action: () => {}
        },
        {
          value: $r('app.string.yt_option_sign_out'),
          fontColor: $r('app.color.yourtube_text_warning'),
          action: () => {
            this.signOut();
          }
        }
      ],
      onWillDismiss: (dismissDialogAction: DismissDialogAction) => {
        if (dismissDialogAction.reason === DismissReason.PRESS_BACK
          || dismissDialogAction.reason === DismissReason.TOUCH_OUTSIDE) {
          dismissDialogAction.dismiss();
        }
      }
    });
  }

  private getHomeFeedStyleOptions(): SelectOption[] {
    return [
      $r('app.string.yt_home_feed_recommended'),
      $r('app.string.yt_home_feed_kiosk')
    ].map(label => ({ value: label } as SelectOption));
  }

  private getHomeFeedStyleIndex(): number {
    return UIConfig.normalizeHomeFeedStyle(this.uiConfig.homeFeedStyle) === 'kiosk' ? 1 : 0;
  }

  private applyHomeFeedStyle(index: number): void {
    const style = index === 1 ? 'kiosk' : 'recommended';
    if (UIConfig.normalizeHomeFeedStyle(this.uiConfig.homeFeedStyle) === style) {
      return;
    }
    this.params.updateUiConfig(cfg => {
      cfg.homeFeedStyle = style;
    });
    this.params.onHomeFeedStyleChanged();
  }

  private showToast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({
        message: message,
        duration: 2000
      });
    } catch (e) {
      // ignore
    }
  }

  private openExportPicker(): void {
    this.backupPickerController = new CustomDialogController({
      builder: BackupItemPickerDialog({
        title: $r('app.string.yt_backup_export_title'),
        selected: [...ALL_BACKUP_ITEM_KEYS],
        onCancel: () => {},
        onConfirm: (selected: BackupItemKey[]) => {
          this.handleExport(selected);
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center
    });
    this.backupPickerController.open();
  }

  private async handleExport(selected: BackupItemKey[]): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    try {
      const backup = DataBackupManager.buildBackup(selected);
      await DataBackupManager.saveBackupToFile(backup);
      this.showToast($r('app.string.yt_backup_export_success'));
    } catch (e) {
      const message = e instanceof BackupError ? e.message : '导出失败';
      this.showToast(message);
    } finally {
      this.isBusy = false;
    }
  }

  private async openRestoreFilePicker(): Promise<void> {
    if (this.isBusy) {
      return;
    }
    this.isBusy = true;
    try {
      const backup = await DataBackupManager.loadBackupFromFile();
      this.pendingRestoreBackup = backup;
      const available = DataBackupManager.getAvailableItems(backup);
      this.restorePickerController = new CustomDialogController({
        builder: BackupItemPickerDialog({
          title: $r('app.string.yt_backup_restore_title'),
          selected: [...available],
          onCancel: () => {
            this.pendingRestoreBackup = null;
          },
          onConfirm: (selected: BackupItemKey[]) => {
            this.showRestoreConfirmDialog(selected);
          }
        }),
        autoCancel: true,
        alignment: DialogAlignment.Center
      });
      this.restorePickerController.open();
    } catch (e) {
      const message = e instanceof BackupError ? e.message : '恢复失败';
      this.showToast(message);
    } finally {
      this.isBusy = false;
    }
  }

  private showRestoreConfirmDialog(selected: BackupItemKey[]): void {
    if (!this.pendingRestoreBackup) {
      return;
    }
    const uiContext = this.getUIContext();
    uiContext.showAlertDialog({
      title: $r('app.string.yt_option_restore_data'),
      message: $r('app.string.yt_backup_confirm_restore'),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      buttonDirection: DialogButtonDirection.HORIZONTAL,
      buttons: [
        {
          value: $r('app.string.yt_action_cancel'),
          action: () => {
            this.pendingRestoreBackup = null;
          }
        },
        {
          value: $r('app.string.yt_action_confirm'),
          fontColor: $r('app.color.yourtube_text_warning'),
          action: () => {
            this.handleRestore(selected);
          }
        }
      ]
    });
  }

  private handleRestore(selected: BackupItemKey[]): void {
    if (!this.pendingRestoreBackup) {
      return;
    }
    try {
      DataBackupManager.applyBackup(this.pendingRestoreBackup, selected);
      AuthStateHelper.refresh();
      this.showToast($r('app.string.yt_backup_restore_success'));
    } catch (e) {
      const message = e instanceof BackupError ? e.message : '恢复失败';
      this.showToast(message);
    } finally {
      this.pendingRestoreBackup = null;
    }
  }

  build() {
    Column() {
      List({ space: 6 }) {
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_section_account') })
        }
        .padding({ left: 0, right: 0 })

        if (!this.hasCredential()) {
          // Single login group: Google WebView + Cookie paste (expandable).
          ListItemGroup() {
            ListItem() {
              OptionItem({
                icon: $r('sys.symbol.person_crop_circle_fill'),
                title: 'Google 账号登录',
                subtitle: '通过网页登录 YouTube / Google',
                iconColor: this.themePrimary,
                showChevron: true,
                transparentBackground: true,
                clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
                onClickAction: () => {
                  this.startLogin();
                }
              })
            }

            ListItem() {
              OptionItem({
                icon: $r('sys.symbol.doc_plaintext'),
                title: this.showCookieImport ? '收起 Cookie 登录' : 'Cookie 登录',
                subtitle: '粘贴浏览器 Cookie / EditThisCookie JSON',
                iconColor: this.themePrimary,
                showChevron: !this.showCookieImport,
                transparentBackground: true,
                clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
                onClickAction: () => {
                  this.showCookieImport = !this.showCookieImport;
                  this.cookieImportMessage = '';
                }
              })
            }

            if (this.showCookieImport) {
              ListItem() {
                Column({ space: 10 }) {
                  Text('支持 header 形式（SID=...; SAPISID=...）或 EditThisCookie / Cookie-Editor 导出的 JSON。需含 SID 与 SAPISID / __Secure-3PAPISID。')
                    .fontSize(12)
                    .fontColor($r('app.color.yourtube_text_hint'))
                    .width('100%')

                  TextArea({
                    text: this.cookieInput,
                    placeholder: 'SID=...; SAPISID=...  或  [{"name":"SID","value":"..."}, ...]'
                  })
                    .height(140)
                    .width('100%')
                    .fontSize(12)
                    .padding(10)
                    .borderRadius(12)
                    .backgroundColor($r('app.color.yourtube_bg_page'))
                    .enabled(!this.isVerifyingCookie)
                    .onChange((v: string) => {
                      this.cookieInput = v;
                    })

                  if (this.cookieImportMessage.length > 0) {
                    Text(this.cookieImportMessage)
                      .fontSize(12)
                      .fontColor((this.cookieImportMessage.indexOf('通过') >= 0
                        || this.cookieImportMessage.indexOf('成功') >= 0)
                        ? this.themePrimary
                        : $r('app.color.yourtube_text_secondary'))
                      .width('100%')
                  }

                  if (this.isVerifyingCookie) {
                    Row({ space: 8 }) {
                      LoadingProgress()
                        .width(18)
                        .height(18)
                        .color(this.themePrimary)
                      Text('正在校验 Cookie…')
                        .fontSize(13)
                        .fontColor($r('app.color.yourtube_text_secondary'))
                    }
                    .width('100%')
                    .justifyContent(FlexAlign.Center)
                    .height(44)
                  } else {
                    Button('确认导入并校验')
                      .height(44)
                      .width('100%')
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .backgroundColor(this.themePrimary)
                      .fontColor(Color.White)
                      .onClick(() => {
                        this.importCookie();
                      })
                  }
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 8, bottom: 16 })
              }
            }
          }
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .borderRadius(16)
          .clip(true)
          .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })
        } else {
          // Logged in: switch for auth-enabled (private browsing when off)
          ListItemGroup() {
            ListItem() {
              PlaybackToggleRow({
                title: this.getAccountTitle(),
                subtitle: this.getAccountSubtitle(),
                isOn: this.isAuthActive(),
                themeColor: this.themePrimary,
                transparentBackground: true,
                onChange: (val: boolean) => {
                  this.onAuthToggle(val);
                }
              })
            }
          }
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .borderRadius(16)
          .clip(true)

          ListItem() {
            Button($r('app.string.yt_option_sign_out'))
              .height(42)
              .width('100%')
              .fontSize(15)
              .fontColor(Color.White)
              .backgroundColor(this.themePrimary)
              .onClick(() => {
                this.confirmSignOut();
              })
          }
          .padding({ left: 0, right: 0, top: 8 })
        }

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_setting_home_feed_after_login') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_setting_home_feed_after_login'),
              options: this.getHomeFeedStyleOptions(),
              selectedIndex: this.getHomeFeedStyleIndex(),
              fontColor: this.themePrimary,
              transparentBackground: true,
              onChange: (index: number) => {
                this.applyHomeFeedStyle(index);
              }
            })
          }

          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_option_sync_library_on_launch'),
              subtitle: $r('app.string.yt_option_sync_library_on_launch_subtitle'),
              isOn: this.uiConfig.syncUserLibraryOnLaunch !== false,
              themeColor: this.themePrimary,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updateUiConfig(cfg => {
                  cfg.syncUserLibraryOnLaunch = val;
                });
              }
            })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(16)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_section_data_management') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            OptionItem({
              icon: $r('sys.symbol.share'),
              title: $r('app.string.yt_option_export_data'),
              subtitle: $r('app.string.yt_option_export_data_subtitle'),
              iconColor: this.themePrimary,
              clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
              transparentBackground: true,
              onClickAction: () => { this.openExportPicker(); }
            })
          }

          ListItem() {
            OptionItem({
              icon: $r('sys.symbol.download_fill'),
              title: $r('app.string.yt_option_restore_data'),
              subtitle: $r('app.string.yt_option_restore_data_subtitle'),
              iconColor: $r('app.color.yourtube_text_warning'),
              clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
              transparentBackground: true,
              onClickAction: () => { this.openRestoreFilePicker(); }
            })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(16)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, bottom: 12 })
      .edgeEffect(EdgeEffect.Spring)
      .alignListItem(ListItemAlign.Start)
      .scrollBar(BarState.Off)

      if (this.isBusy) {
        LoadingProgress()
          .width(32)
          .height(32)
          .color(this.themePrimary)
          .margin({ bottom: 16 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
