import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { OptionItem } from '../../common/components/OptionItem';
import { BackupItemPickerDialog } from '../../common/components/BackupItemPickerDialog';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import { UIConfig } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';
import {
  AuthAccountStatus,
  AuthSessionManager,
  AuthStage,
  CookieAuthCredential
} from 'youtube_core';
import { DataBackupManager, BackupError } from '../../common/DataBackupManager';
import { BackupItemKey, AppBackupData, ALL_BACKUP_ITEM_KEYS } from '../../common/model/BackupModels';
import { AuthStateHelper } from '../../common/AuthStateHelper';
import { FeedServiceProvider } from '../../common/FeedServiceProvider';
import { PreferencesStore } from '../../common/PreferencesStore';
import { AppLog } from '../../common/AppLog';

const logger = AppLog.getInstance('OptionsDataAccountPage');

interface CookieVerifyResult {
  ok: boolean;
  detail: string;
}

interface OptionsDataAccountPageParams {
  /** Open Google WebView login (after notice dialog). */
  onLoginClick: () => void;
  /** Open SmartTube-style device / QR OAuth login. */
  onDeviceQrLoginClick: () => void;
  updateUiConfig: (updater: (cfg: UIConfig) => void) => void;
  onHomeFeedStyleChanged: () => void;
  onAuthChanged: () => void;
  /** Cookie 导入登录成功后的统一后置动作（与 WebView/QR 登录一致）。 */
  onLoginSuccess: () => void;
  /** 恢复所有配置（确认弹窗由 Index 弹出）。 */
  onResetSettings: () => void;
  /** 清除应用全部数据（确认弹窗由 Index 弹出）。 */
  onClearAllData: () => void;
}

@Component
export struct OptionsDataAccountPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageLink('authStatus') authStatus: AuthAccountStatus = new AuthAccountStatus();

  @Prop params: OptionsDataAccountPageParams = {
    onLoginClick: () => {},
    onDeviceQrLoginClick: () => {},
    updateUiConfig: () => {},
    onHomeFeedStyleChanged: () => {},
    onAuthChanged: () => {},
    onLoginSuccess: () => {},
    onResetSettings: () => {},
    onClearAllData: () => {}
  };

  @State isBusy: boolean = false;
  @State private isFeedFastMode: boolean = PreferencesStore.getString('cfg_feed_fast_mode', 'false') === 'true';
  @State private showCookieImport: boolean = false;
  @State private cookieInput: string = '';
  @State private cookieImportMessage: string = '';
  @State private cookieImportSuccess: boolean = false;
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

  private tr(resource: Resource): string {
    return getContext().resourceManager.getStringSync(resource.id);
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

  private getAccountSubtitle(): ResourceStr {
    if (!this.hasCredential()) {
      return $r('app.string.yt_auth_subtitle_sign_in');
    }
    if (this.isAuthActive()) {
      if (this.authStatus.authMode === 'cookie') {
        return $r('app.string.yt_auth_subtitle_cookie_active');
      }
      if (this.authStatus.authMode === 'both') {
        return $r('app.string.yt_auth_subtitle_cookie_active');
      }
      return $r('app.string.yt_auth_subtitle_active');
    }
    return $r('app.string.yt_auth_subtitle_incognito');
  }

  private startLogin(): void {
    const uiContext = this.getUIContext();
    uiContext.showAlertDialog({
      title: $r('app.string.yt_auth_notice_title'),
      message: $r('app.string.yt_auth_notice_message'),
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
          value: $r('app.string.yt_auth_continue_sign_in'),
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
    } catch (e) {
      logger.debug(`cookie JSON parse ignored: ${e}`);
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
          ? getContext().resourceManager.getStringSync($r('app.string.yt_cookie_verify_history').id, page.items.length)
          : this.tr($r('app.string.yt_cookie_verify_empty_history'))
      };
      return success;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      logger.warn(`cookie online verify failed: ${msg}`);
      if (msg.indexOf('Sign-in required') >= 0) {
        const failedSession: CookieVerifyResult = {
          ok: false,
          detail: this.tr($r('app.string.yt_cookie_session_inactive'))
        };
        return failedSession;
      }
      const failed: CookieVerifyResult = {
        ok: false,
        detail: getContext().resourceManager.getStringSync($r('app.string.yt_cookie_verify_failed').id, msg)
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
    this.cookieImportSuccess = false;
    if (raw.length === 0) {
      this.cookieImportMessage = this.tr($r('app.string.yt_cookie_input_required'));
      return;
    }

    const cookies = this.parseCookieInput(raw);
    if (cookies.length === 0) {
      this.cookieImportMessage = this.tr($r('app.string.yt_cookie_parse_failed'));
      return;
    }
    if (!CookieAuthCredential.hasSid(cookies) && CookieAuthCredential.parseSapiSid(cookies).length === 0) {
      this.cookieImportMessage = this.tr($r('app.string.yt_cookie_sid_missing'));
      return;
    }
    const credential = CookieAuthCredential.fromCookies(cookies, '');
    if (credential.sapiSid.length === 0) {
      this.cookieImportMessage = this.tr($r('app.string.yt_cookie_sapisid_missing'));
      return;
    }

    const session = AuthSessionManager.getInstance();
    if (!session) {
      this.cookieImportMessage = this.tr($r('app.string.yt_auth_module_unavailable'));
      return;
    }

    session.saveCookieCredential(credential);
    AuthStateHelper.refresh();
    AuthStateHelper.reconcilePlaybackClient();

    this.isVerifyingCookie = true;
    this.cookieImportMessage = this.tr($r('app.string.yt_cookie_local_validating'));
    try {
      const result = await this.verifyCookieOnline();
      if (result.ok) {
        this.cookieInput = '';
        this.showCookieImport = false;
        this.cookieImportMessage = result.detail;
        this.cookieImportSuccess = true;
        this.params.onLoginSuccess();
      } else {
        session.signOut();
        AuthStateHelper.refresh();
        this.cookieImportMessage = result.detail;
        this.cookieImportSuccess = false;
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
    AuthStateHelper.reconcilePlaybackClient();
    this.params.onAuthChanged();
  }

  private isUseAuthForUserDataActive(): boolean {
    return this.authStatus.useAuthForUserData !== false;
  }

  private onUseAuthForUserDataToggle(enabled: boolean): void {
    AuthSessionManager.getInstance()?.setUseAuthForUserData(enabled);
    AuthStateHelper.refresh();
    this.params.onAuthChanged();
  }

  private isUseAuthForPlaybackActive(): boolean {
    return this.authStatus.useAuthForPlayback !== false;
  }

  private onUseAuthForPlaybackToggle(enabled: boolean): void {
    AuthSessionManager.getInstance()?.setUseAuthForPlayback(enabled);
    AuthStateHelper.refresh();
    AuthStateHelper.reconcilePlaybackClient();
    this.params.onAuthChanged();
  }

  private signOut(): void {
    AuthSessionManager.getInstance()?.signOut();
    AuthStateHelper.refresh();
    AuthStateHelper.reconcilePlaybackClient();
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
          fontColor: this.themePrimary,
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
      const message = e instanceof BackupError ? $r(`app.string.${e.resourceKey}`) : $r('app.string.yt_backup_error_export');
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
      const message = e instanceof BackupError ? $r(`app.string.${e.resourceKey}`) : $r('app.string.yt_backup_error_restore');
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
          fontColor: this.themePrimary,
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
      const message = e instanceof BackupError ? $r(`app.string.${e.resourceKey}`) : $r('app.string.yt_backup_error_restore');
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
                title: $r('app.string.yt_google_web_sign_in'),
                subtitle: $r('app.string.yt_google_web_sign_in_subtitle'),
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
                icon: $r('sys.symbol.qrcode'),
                title: $r('app.string.yt_device_qr_sign_in'),
                subtitle: $r('app.string.yt_device_qr_sign_in_subtitle'),
                iconColor: this.themePrimary,
                showChevron: true,
                transparentBackground: true,
                clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
                onClickAction: () => {
                  this.params.onDeviceQrLoginClick();
                }
              })
            }

            ListItem() {
              OptionItem({
                icon: $r('sys.symbol.doc_plaintext'),
                title: this.showCookieImport ? $r('app.string.yt_cookie_collapse') : $r('app.string.yt_cookie_sign_in'),
                subtitle: $r('app.string.yt_cookie_import_subtitle'),
                iconColor: this.themePrimary,
                showChevron: !this.showCookieImport,
                transparentBackground: true,
                clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
                onClickAction: () => {
                  this.showCookieImport = !this.showCookieImport;
                  this.cookieImportMessage = '';
                  this.cookieImportSuccess = false;
                }
              })
            }

            if (this.showCookieImport) {
              ListItem() {
                Column({ space: 10 }) {
                  Text($r('app.string.yt_cookie_import_help'))
                    .fontSize(12)
                    .fontColor($r('app.color.yourtube_text_hint'))
                    .width('100%')

                  TextArea({
                    text: this.cookieInput,
                    placeholder: $r('app.string.yt_cookie_import_placeholder')
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
                      .fontColor(this.cookieImportSuccess
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
                      Text($r('app.string.yt_cookie_verifying'))
                        .fontSize(13)
                        .fontColor($r('app.color.yourtube_text_secondary'))
                    }
                    .width('100%')
                    .justifyContent(FlexAlign.Center)
                    .height(44)
                  } else {
                    Button($r('app.string.yt_cookie_import_confirm'))
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
          .borderRadius(SECTION_CARD_RADIUS)
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

            if (this.isAuthActive()) {
              ListItem() {
                PlaybackToggleRow({
                  title: $r('app.string.yt_option_auth_use_for_user_data'),
                  subtitle: $r('app.string.yt_option_auth_use_for_user_data_subtitle'),
                  isOn: this.isUseAuthForUserDataActive(),
                  themeColor: this.themePrimary,
                  transparentBackground: true,
                  onChange: (val: boolean) => {
                    this.onUseAuthForUserDataToggle(val);
                  }
                })
              }

              ListItem() {
                PlaybackToggleRow({
                  title: $r('app.string.yt_option_auth_use_for_playback'),
                  subtitle: $r('app.string.yt_option_auth_use_for_playback_subtitle'),
                  isOn: this.isUseAuthForPlaybackActive(),
                  themeColor: this.themePrimary,
                  transparentBackground: true,
                  onChange: (val: boolean) => {
                    this.onUseAuthForPlaybackToggle(val);
                  }
                })
              }
            }
          }
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .borderRadius(SECTION_CARD_RADIUS)
          .clip(true)
          .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

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
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_sub_feed_title') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_feed_fast_mode_title'),
              subtitle: $r('app.string.yt_feed_fast_mode_subtitle'),
              isOn: this.isFeedFastMode,
              themeColor: this.themePrimary,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.isFeedFastMode = val;
                PreferencesStore.setString('cfg_feed_fast_mode', val ? 'true' : 'false');
              }
            })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
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
              iconColor: this.themePrimary,
              clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
              transparentBackground: true,
              onClickAction: () => { this.openRestoreFilePicker(); }
            })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_option_recovery') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            OptionItem({
              icon: $r('sys.symbol.arrow_counterclockwise_clock'),
              title: $r('app.string.yt_option_reset_settings'),
              subtitle: $r('app.string.yt_option_reset_settings_subtitle'),
              iconColor: this.themePrimary,
              clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
              transparentBackground: true,
              onClickAction: () => { this.params.onResetSettings(); }
            })
          }

          ListItem() {
            OptionItem({
              icon: $r('sys.symbol.trash'),
              title: $r('app.string.yt_option_clear_all_data'),
              subtitle: $r('app.string.yt_option_clear_all_data_subtitle'),
              iconColor: this.themePrimary,
              clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
              transparentBackground: true,
              onClickAction: () => { this.params.onClearAllData(); }
            })
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
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
