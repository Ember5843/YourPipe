import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { OptionItem } from '../../common/components/OptionItem';
import { BackupItemPickerDialog } from '../../common/components/BackupItemPickerDialog';
import { UIConfig } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { AuthAccountStatus, AuthSessionManager, AuthStage } from 'youtube_core';
import { DataBackupManager, BackupError } from '../../common/DataBackupManager';
import { BackupItemKey, AppBackupData, ALL_BACKUP_ITEM_KEYS } from '../../common/model/BackupModels';
import { AuthStateHelper } from '../../common/AuthStateHelper';

interface OptionsDataAccountPageParams {
  /** Open WebView login page directly (no intermediate Google account page). */
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

  private onAuthToggle(enabled: boolean): void {
    if (!this.hasCredential()) {
      return;
    }
    AuthSessionManager.getInstance()?.setAuthEnabled(enabled);
    AuthStateHelper.refresh();
    this.params.onAuthChanged();
  }

  private signOut(): void {
    AuthSessionManager.getInstance()?.signOut();
    AuthStateHelper.refresh();
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
          // Not logged in: row opens login flow (chevron)
          ListItem() {
            OptionItem({
              icon: $r('sys.symbol.person_crop_circle_fill'),
              title: this.getAccountTitle(),
              subtitle: this.getAccountSubtitle(),
              iconColor: this.themePrimary,
              showChevron: true,
              clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
              onClickAction: () => {
                this.startLogin();
              }
            })
          }
          .padding({ left: 0, right: 0 })
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
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(16)
        .clip(true)

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
