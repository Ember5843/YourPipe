import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { OptionItem } from '../../common/components/OptionItem';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import { UIConfig } from '../../common/AppState';
import { resourceManager } from '@kit.LocalizationKit';
import {
  APPGALLERY_TEST_URL,
  GITHUB_REPO_URL,
  UpdateCheckResult,
  UpdateChecker
} from '../../common/UpdateChecker';
import { showUpdateAvailableDialog, showUpdateMessageDialog } from '../../common/UpdatePrompt';
import { getAppVersion } from '../../common/AppVersion';
import { openExternalUrl } from '../../common/utils/ExternalLinkUtil';
import { AppLog } from '../../common/AppLog';

const logger = AppLog.getInstance('OptionsUpdatePage');

interface UpdatePageParams {
  updateUiConfig: (mutator: (cfg: UIConfig) => void) => void;
}

@Component
export struct OptionsUpdatePage {
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @Prop params: UpdatePageParams = {
    updateUiConfig: () => {}
  };

  @State checking: boolean = false;
  @State result: UpdateCheckResult | null = null;

  aboutToAppear(): void {
    this.result = UpdateChecker.getLastResult();
  }

  private rm(): resourceManager.ResourceManager {
    return getContext().resourceManager;
  }

  private statusText(): string {
    const result = this.result;
    if (!result) {
      return this.rm().getStringSync($r('app.string.yt_update_never_checked').id);
    }
    if (result.status === 'upToDate') {
      return this.rm().getStringSync($r('app.string.yt_update_up_to_date').id);
    }
    if (result.status === 'updateAvailable') {
      return this.rm().getStringSync($r('app.string.yt_update_available').id)
        + ` v${result.remoteVersionName}`;
    }
    if (result.rateLimited) {
      return this.rm().getStringSync($r('app.string.yt_update_rate_limited').id);
    }
    return this.rm().getStringSync($r('app.string.yt_update_check_failed').id);
  }

  private statusTimeText(): string {
    if (!this.result || this.result.checkedAt <= 0) {
      return '';
    }
    return new Date(this.result.checkedAt).toLocaleString();
  }

  private async checkNow(): Promise<void> {
    if (this.checking) {
      return;
    }
    if (!this.uiConfig.checkGithubUpdates) {
      showUpdateMessageDialog(this.getUIContext(),
        $r('app.string.yt_update_page_title'),
        $r('app.string.yt_update_disabled_hint'));
      return;
    }
    this.checking = true;
    logger.info('manual update check requested');
    try {
      const result = await UpdateChecker.check('manual');
      this.result = result;
      if (result.status === 'updateAvailable') {
        showUpdateAvailableDialog(this.getUIContext(), result);
      } else if (result.status === 'upToDate') {
        showUpdateMessageDialog(this.getUIContext(),
          $r('app.string.yt_update_page_title'),
          $r('app.string.yt_update_up_to_date'));
      } else {
        showUpdateMessageDialog(this.getUIContext(),
          $r('app.string.yt_update_page_title'),
          result.rateLimited
            ? $r('app.string.yt_update_rate_limited')
            : $r('app.string.yt_update_check_failed'));
      }
    } finally {
      this.checking = false;
    }
  }

  private openLink(url: string, name: string): void {
    openExternalUrl(
      this.getUIContext(),
      url,
      name,
      $r('app.string.yt_about_link_unavailable'),
      $r('app.string.yt_about_link_failed')
    );
  }

  @Builder
  ActionLink(icon: Resource, title: ResourceStr, url: string, name: string) {
    OptionItem({
      icon: icon,
      title: title,
      iconColor: this.themePrimary,
      transparentBackground: true,
      showChevron: true,
      onClickAction: () => this.openLink(url, name)
    })
  }

  build() {
    List({ space: 6 }) {
      ListItem() {
        PlaybackSectionTitle({ title: $r('app.string.yt_update_page_title') })
      }
      .padding({ left: 16, right: 16, top: 8 })

      ListItem() {
        Column() {
          PlaybackToggleRow({
            title: $r('app.string.yt_update_enable'),
            subtitle: $r('app.string.yt_update_enable_desc'),
            isOn: this.uiConfig.checkGithubUpdates,
            themeColor: this.themePrimary,
            transparentBackground: true,
            onChange: (value: boolean) => {
              logger.info(`check github updates=${value}`);
              this.params.updateUiConfig((cfg: UIConfig) => {
                cfg.checkGithubUpdates = value;
              });
            }
          })
          if (this.uiConfig.checkGithubUpdates) {
            Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
            PlaybackToggleRow({
              title: $r('app.string.yt_update_on_startup'),
              subtitle: $r('app.string.yt_update_on_startup_desc'),
              isOn: this.uiConfig.checkUpdatesOnStartup,
              themeColor: this.themePrimary,
              transparentBackground: true,
              onChange: (value: boolean) => {
                logger.info(`check updates on startup=${value}`);
                this.params.updateUiConfig((cfg: UIConfig) => {
                  cfg.checkUpdatesOnStartup = value;
                });
              }
            })
          }
        }
        .width('100%')
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
      }
      .padding({ left: 16, right: 16 })

      ListItem() {
        PlaybackSectionTitle({ title: $r('app.string.yt_update_last_check') })
      }
      .padding({ left: 16, right: 16, top: 8 })

      ListItem() {
        Column({ space: 10 }) {
          Row() {
            Column({ space: 2 }) {
              Text($r('app.string.yt_update_current_version'))
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_hint'))
              Text(`v${getAppVersion().versionName} (${getAppVersion().versionCode})`)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.yourtube_text_primary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Button(this.checking ? $r('app.string.yt_update_checking') : $r('app.string.yt_update_check_now'))
              .fontSize(13)
              .height(36)
              .padding({ left: 16, right: 16 })
              .backgroundColor(this.themePrimary)
              .fontColor($r('app.color.yourtube_text_inverse'))
              .enabled(!this.checking)
              .onClick(() => this.checkNow())
          }
          .width('100%')

          Divider().color($r('app.color.yourtube_divider'))

          Column({ space: 2 }) {
            Text(this.statusText())
              .fontSize(13)
              .fontColor(this.result && this.result.status === 'updateAvailable'
                ? this.themePrimary
                : $r('app.color.yourtube_text_secondary'))
            if (this.statusTimeText().length > 0) {
              Text(this.statusTimeText())
                .fontSize(11)
                .fontColor($r('app.color.yourtube_text_hint'))
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          if (!this.uiConfig.checkGithubUpdates) {
            Text($r('app.string.yt_update_disabled_hint'))
              .fontSize(11)
              .fontColor($r('app.color.yourtube_text_hint'))
              .width('100%')
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
      }
      .padding({ left: 16, right: 16 })

      if (this.result && this.result.status === 'updateAvailable') {
        ListItem() {
          Column({ space: 10 }) {
            Text($r('app.string.yt_update_available'))
              .fontSize(15)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.themePrimary)
            Text(`v${this.result.remoteVersionName}`
              + (this.result.remoteVersionCode > 0 ? ` (${this.result.remoteVersionCode})` : ''))
              .fontSize(13)
              .fontColor($r('app.color.yourtube_text_primary'))
            if (this.result.publishedAt.length > 0) {
              Text(this.result.publishedAt)
                .fontSize(11)
                .fontColor($r('app.color.yourtube_text_hint'))
            }
            if (this.result.notes.length > 0) {
              Text(this.result.notes)
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_secondary'))
                .lineHeight(18)
                .maxLines(8)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            Row({ space: 10 }) {
              Button($r('app.string.yt_update_open_github'))
                .fontSize(12)
                .height(34)
                .layoutWeight(1)
                .backgroundColor(this.themePrimary)
                .fontColor($r('app.color.yourtube_text_inverse'))
                .onClick(() => this.openLink(this.result!.releaseUrl, 'release'))
              Button($r('app.string.yt_update_open_appgallery'))
                .fontSize(12)
                .height(34)
                .layoutWeight(1)
                .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
                .fontColor($r('app.color.yourtube_text_primary'))
                .border({ width: 1, color: $r('app.color.yourtube_divider') })
                .onClick(() => this.openLink(APPGALLERY_TEST_URL, 'appgallery'))
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .alignItems(HorizontalAlign.Start)
          .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
          .borderRadius(SECTION_CARD_RADIUS)
          .clip(true)
        }
        .padding({ left: 16, right: 16 })
      }

      ListItem() {
        PlaybackSectionTitle({ title: $r('app.string.yt_update_links') })
      }
      .padding({ left: 16, right: 16, top: 8 })

      ListItem() {
        Column() {
          this.ActionLink($r('sys.symbol.doc_plaintext'),
            $r('app.string.yt_about_github_repo'), GITHUB_REPO_URL, 'github_repo')
          Divider().color($r('app.color.yourtube_divider')).margin({ left: 16, right: 16 })
          this.ActionLink($r('sys.symbol.star_fill'),
            $r('app.string.yt_update_open_appgallery'), APPGALLERY_TEST_URL, 'appgallery')
        }
        .width('100%')
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
      }
      .padding({ left: 16, right: 16 })

      ListItem() {
        Column().height(24)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ top: 4 })
  }
}
