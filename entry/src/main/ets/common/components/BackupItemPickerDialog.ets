import { BackupItemKey, ALL_BACKUP_ITEM_KEYS } from '../model/BackupModels';

@CustomDialog
export struct BackupItemPickerDialog {
  controller: CustomDialogController = new CustomDialogController({ builder: BackupItemPickerDialog({}) });
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  title: ResourceStr = '';
  @State selected: BackupItemKey[] = [];
  onCancel?: () => void;
  onConfirm?: (selected: BackupItemKey[]) => void;

  aboutToAppear(): void {
    if (this.selected.length === 0) {
      this.selected = [...ALL_BACKUP_ITEM_KEYS];
    }
  }

  private isSelected(key: BackupItemKey): boolean {
    return this.selected.includes(key);
  }

  private toggle(key: BackupItemKey): void {
    if (this.isSelected(key)) {
      this.selected = this.selected.filter((k) => k !== key);
    } else {
      this.selected = [...this.selected, key];
    }
  }

  private getLabel(key: BackupItemKey): ResourceStr {
    switch (key) {
      case 'settings':
        return $r('app.string.yt_backup_item_settings');
      case 'subscriptions':
        return $r('app.string.yt_backup_item_subscriptions');
      case 'subscriptionFeed':
        return $r('app.string.yt_backup_item_subscription_feed');
      case 'favorites':
        return $r('app.string.yt_backup_item_favorites');
      case 'playlists':
        return $r('app.string.yt_backup_item_playlists');
      case 'localQueues':
        return $r('app.string.yt_backup_item_local_queues');
      case 'watchHistory':
        return $r('app.string.yt_backup_item_watch_history');
      case 'searchHistory':
        return $r('app.string.yt_backup_item_search_history');
      case 'auth':
        return $r('app.string.yt_backup_item_auth');
      default:
        return '';
    }
  }

  build() {
    Column() {
      Text(this.title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.yourtube_text_primary'))
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ bottom: 16 })

      List() {
        ForEach(ALL_BACKUP_ITEM_KEYS, (key: BackupItemKey) => {
          ListItem() {
            Row({ space: 12 }) {
              Checkbox()
                .select(this.isSelected(key))
                .selectedColor(this.themePrimary)
                .width(20)
                .height(20)

              Text(this.getLabel(key))
                .fontSize(16)
                .fontColor($r('app.color.yourtube_text_primary'))
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .onClick(() => {
              this.toggle(key);
            })
          }
        }, (key: BackupItemKey) => key)
      }
      .width('100%')
      .layoutWeight(1)
      .divider({ strokeWidth: 0.5, color: $r('app.color.yourtube_divider') })

      Row({ space: 12 }) {
        Button($r('app.string.yt_action_cancel'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .fontColor($r('app.color.yourtube_text_primary'))
          .onClick(() => {
            if (this.onCancel) {
              this.onCancel();
            }
            this.controller?.close();
          })

        Button($r('app.string.yt_action_confirm'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .backgroundColor(this.themePrimary)
          .fontColor(Color.White)
          .enabled(this.selected.length > 0)
          .onClick(() => {
            if (this.onConfirm) {
              this.onConfirm([...this.selected]);
            }
            this.controller?.close();
          })
      }
      .width('100%')
      .margin({ top: 16 })
    }
    .width('100%')
    .padding(20)
  }
}
