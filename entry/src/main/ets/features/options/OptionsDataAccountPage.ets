import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { OptionItem } from '../../common/components/OptionItem';
import { BackupItemPickerDialog } from '../../common/components/BackupItemPickerDialog';
import { UIConfig } from '../../common/AppState';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { AuthAccountStatus, AuthStage } from 'youtube_core';
import { DataBackupManager, BackupError } from '../../common/DataBackupManager';
import { BackupItemKey, AppBackupData, ALL_BACKUP_ITEM_KEYS } from '../../common/model/BackupModels';
import { AuthStateHelper } from '../../common/AuthStateHelper';

interface OptionsDataAccountPageParams {
  onAccountClick: () => void;
}

@Component
export struct OptionsDataAccountPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#F1680D';
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageProp('authStatus') authStatus: AuthAccountStatus = new AuthAccountStatus();

  @Prop params: OptionsDataAccountPageParams = {
    onAccountClick: () => {}
  };

  @State isBusy: boolean = false;
  private backupPickerController: CustomDialogController | null = null;
  private restorePickerController: CustomDialogController | null = null;
  private pendingRestoreBackup: AppBackupData | null = null;

  private getAccountSubtitle(): string {
    if (this.authStatus.stage === AuthStage.SIGNED_IN) {
      return this.authStatus.authMode === 'cookie' ? '已登录 (Cookie)' : '已登录';
    }
    return '登录以获取个性化推荐';
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

        ListItem() {
          OptionItem({
            icon: $r('sys.symbol.person'),
            title: $r('app.string.yt_option_google_login'),
            subtitle: this.getAccountSubtitle(),
            iconColor: this.themePrimary,
            clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
            onClickAction: this.params.onAccountClick
          })
        }
        .padding({ left: 0, right: 0 })

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
              icon: $r('sys.symbol.arrowshape_down_to_line_fill'),
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
