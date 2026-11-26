import { SelectOption } from 'mediaservice';
import { OptionItem } from '../../common/components/OptionItem';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import { UIConfig } from '../../common/AppState';
import {
  PlaybackConfig,
  HOLD_SPEED_VALUES, HOLD_SPEED_DELAYS, getHoldSpeedDelayDisplay,
  GesturePreset, GESTURE_PRESET_LABELS, getGestureSchemeDisplay,
  DOUBLE_TAP_ACTION_LABELS, getDoubleTapActionDisplay,
  DOUBLE_TAP_SEEK_SECONDS, getDoubleTapSeekDisplay,
} from '../../common/PlaybackConfig';

interface OptionsGestureControlPageParams {
  themeColor: ResourceColor;
  clickEffectEnabled: ClickEffect | null;
  updatePlaybackConfig: (updater: (cfg: PlaybackConfig) => void) => void;
  updateUiConfig: (updater: (cfg: UIConfig) => void) => void;
}

@CustomDialog
struct GesturePresetPickerDialog {
  controller?: CustomDialogController;
  onSelect?: (preset: GesturePreset) => void;

  private presetSummary(preset: GesturePreset): string {
    const t = (res: Resource): string => getContext().resourceManager.getStringSync(res.id);
    const seek = t($r('app.string.yt_gesture_double_tap_seek'));
    const playPause = t($r('app.string.yt_gesture_double_tap_playpause'));
    const swipeH = t($r('app.string.yt_playback_gesture_seek'));
    const brightness = t($r('app.string.yt_gesture_help_brightness'));
    const volume = t($r('app.string.yt_gesture_help_volume'));
    const hold = t($r('app.string.yt_playback_hold_speed'));
    const centerBtn = t($r('app.string.yt_playback_center_play_button'));
    if (preset === 'youtube') {
      return `${seek} 10s · ${hold} · ${centerBtn}`;
    }
    if (preset === 'bilibili') {
      return `${playPause} · ${swipeH} · ${brightness}/${volume} · ${hold}`;
    }
    return `${seek} 15s · ${swipeH} · ${brightness}/${volume} · ${hold}`;
  }

  build() {
    Column() {
      Text($r('app.string.yt_gesture_scheme_label'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ bottom: 12 })

      Column({ space: 8 }) {
        ForEach(GESTURE_PRESET_LABELS, (preset: GesturePreset) => {
          Row({ space: 12 }) {
            Column({ space: 4 }) {
              Text(getGestureSchemeDisplay(preset))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .width('100%')
              Text(this.presetSummary(preset))
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)

            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(18)
              .fontColor([$r('sys.color.icon_fourth')])
          }
          .width('100%')
          .padding({ left: 14, right: 12, top: 12, bottom: 12 })
          .borderRadius(12)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .onClick(() => {
            this.onSelect?.(preset);
            this.controller?.close();
          })
        }, (preset: GesturePreset) => preset)
      }
      .width('100%')

      Button($r('app.string.yt_action_cancel'))
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .width('100%')
        .height(40)
        .margin({ top: 16 })
        .backgroundColor($r('sys.color.comp_background_tertiary'))
        .fontColor($r('sys.color.font_primary'))
        .onClick(() => {
          this.controller?.close();
        })
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('sys.color.comp_background_list_card'))
    .borderRadius(20)
  }
}

@Component
export struct OptionsGestureControlPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('playbackConfig') playbackConfig: PlaybackConfig = new PlaybackConfig();
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();

  @Prop params: OptionsGestureControlPageParams = {
    themeColor: '#E53935',
    clickEffectEnabled: null,
    updatePlaybackConfig: () => {},
    updateUiConfig: () => {}
  };

  private presetDialogController: CustomDialogController | null = null;

  private openPresetDialog(): void {
    this.presetDialogController = new CustomDialogController({
      builder: GesturePresetPickerDialog({
        onSelect: (preset: GesturePreset) => {
          this.applyPreset(preset);
        }
      }),
      autoCancel: true,
      customStyle: false,
      alignment: DialogAlignment.Center
    });
    this.presetDialogController.open();
  }

  private applyPreset(preset: GesturePreset): void {
    this.params.updatePlaybackConfig(cfg => PlaybackConfig.applyGesturePreset(cfg, preset));
    const showCenter = PlaybackConfig.centerPlayButtonForPreset(preset);
    this.params.updateUiConfig(cfg => cfg.showCenterPlayButton = showCenter);
  }

  private getDoubleTapOptions(): SelectOption[] {
    return DOUBLE_TAP_ACTION_LABELS.map(s => ({ value: getDoubleTapActionDisplay(s) } as SelectOption));
  }

  private getDoubleTapSeekOptions(): SelectOption[] {
    return DOUBLE_TAP_SEEK_SECONDS.map(s => ({ value: getDoubleTapSeekDisplay(s) } as SelectOption));
  }

  private getHoldSpeedOptions(): SelectOption[] {
    return HOLD_SPEED_VALUES.map(v => ({ value: `${v}x` } as SelectOption));
  }

  private getHoldSpeedDelayOptions(): SelectOption[] {
    return HOLD_SPEED_DELAYS.map(v => ({ value: getHoldSpeedDelayDisplay(v) } as SelectOption));
  }

  /** 手势说明：按当前配置动态生成（关闭项显示「已关闭」）。 */
  private helpLines(): string[] {
    const t = (res: Resource): string => getContext().resourceManager.getStringSync(res.id);
    const off = t($r('app.string.yt_gesture_help_off'));
    const seekValue = t($r('app.string.yt_gesture_double_tap_seek'));
    const lines: string[] = [];

    lines.push(`${t($r('app.string.yt_gesture_help_single_tap'))}：`
      + t($r('app.string.yt_gesture_help_single_tap_value')));

    const action = this.playbackConfig.doubleTapAction;
    const actionValue = action === 'seek'
      ? `${seekValue} · ${this.playbackConfig.doubleTapSeekSeconds}s`
      : (action === 'playpause'
        ? t($r('app.string.yt_gesture_double_tap_playpause'))
        : t($r('app.string.yt_gesture_double_tap_off')));
    lines.push(`${t($r('app.string.yt_gesture_double_tap'))}：${actionValue}`);

    lines.push(`${t($r('app.string.yt_gesture_help_swipe_horizontal'))}：`
      + (this.playbackConfig.gestureSeekEnabled ? seekValue : off));
    lines.push(`${t($r('app.string.yt_gesture_help_swipe_left'))}：`
      + (this.playbackConfig.gestureBrightnessEnabled ? t($r('app.string.yt_gesture_help_brightness')) : off));
    lines.push(`${t($r('app.string.yt_gesture_help_swipe_right'))}：`
      + (this.playbackConfig.gestureVolumeEnabled ? t($r('app.string.yt_gesture_help_volume')) : off));
    lines.push(`${t($r('app.string.yt_gesture_help_hold'))}：`
      + (this.playbackConfig.holdSpeedEnabled
        ? `${this.playbackConfig.holdSpeedValue}x · ${getHoldSpeedDelayDisplay(this.playbackConfig.holdSpeedDelayMs)}`
        : off));
    return lines;
  }

  build() {
    Column() {
      List({ space: 6 }) {
        // ── 交互方案（一次性预设模板弹窗 + 双击动作配置，互不耦合） ──
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_gesture_scheme_title') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            OptionItem({
              title: $r('app.string.yt_gesture_scheme_label'),
              showChevron: true,
              transparentBackground: true,
              clickEffectEnabled: this.params.clickEffectEnabled,
              onClickAction: () => {
                this.openPresetDialog();
              }
            })
          }

          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_gesture_double_tap'),
              options: this.getDoubleTapOptions(),
              selectedIndex: DOUBLE_TAP_ACTION_LABELS.indexOf(this.playbackConfig.doubleTapAction),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const action = DOUBLE_TAP_ACTION_LABELS[index];
                this.params.updatePlaybackConfig(cfg => cfg.doubleTapAction = action);
              }
            })
          }

          if (this.playbackConfig.doubleTapAction === 'seek') {
            ListItem() {
              PlaybackSelectRow({
                title: $r('app.string.yt_gesture_double_tap_seek_seconds'),
                options: this.getDoubleTapSeekOptions(),
                selectedIndex: DOUBLE_TAP_SEEK_SECONDS.indexOf(this.playbackConfig.doubleTapSeekSeconds),
                fontColor: this.params.themeColor,
                transparentBackground: true,
                onChange: (index: number) => {
                  const secs = DOUBLE_TAP_SEEK_SECONDS[index];
                  this.params.updatePlaybackConfig(cfg => cfg.doubleTapSeekSeconds = secs);
                }
              })
            }
          }
        }
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        // ── 分项开关（滑动组 / 中央按钮 / 长按组） ──
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_playback_gestures') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_playback_gesture_seek'),
              subtitle: $r('app.string.yt_playback_gesture_seek_subtitle'),
              isOn: this.playbackConfig.gestureSeekEnabled,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updatePlaybackConfig(cfg => cfg.gestureSeekEnabled = val);
              }
            })
          }

          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_playback_center_play_button'),
              subtitle: $r('app.string.yt_playback_center_play_button_subtitle'),
              isOn: this.uiConfig.showCenterPlayButton,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updateUiConfig(cfg => cfg.showCenterPlayButton = val);
              }
            })
          }

          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_playback_gesture_brightness'),
              subtitle: $r('app.string.yt_playback_gesture_brightness_subtitle'),
              isOn: this.playbackConfig.gestureBrightnessEnabled,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updatePlaybackConfig(cfg => cfg.gestureBrightnessEnabled = val);
              }
            })
          }

          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_playback_gesture_volume'),
              subtitle: $r('app.string.yt_playback_gesture_volume_subtitle'),
              isOn: this.playbackConfig.gestureVolumeEnabled,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updatePlaybackConfig(cfg => cfg.gestureVolumeEnabled = val);
              }
            })
          }

          ListItem() {
            PlaybackToggleRow({
              title: $r('app.string.yt_playback_hold_speed'),
              subtitle: $r('app.string.yt_playback_hold_speed_subtitle'),
              isOn: this.playbackConfig.holdSpeedEnabled,
              themeColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (val: boolean) => {
                this.params.updatePlaybackConfig(cfg => cfg.holdSpeedEnabled = val);
              }
            })
          }

          if (this.playbackConfig.holdSpeedEnabled) {
            ListItem() {
              PlaybackSelectRow({
                title: $r('app.string.yt_playback_hold_speed_value'),
                options: this.getHoldSpeedOptions(),
                selectedIndex: HOLD_SPEED_VALUES.indexOf(this.playbackConfig.holdSpeedValue),
                fontColor: this.params.themeColor,
                transparentBackground: true,
                onChange: (index: number) => {
                  const v = HOLD_SPEED_VALUES[index];
                  this.params.updatePlaybackConfig(cfg => cfg.holdSpeedValue = v);
                }
              })
            }

            ListItem() {
              PlaybackSelectRow({
                title: $r('app.string.yt_playback_hold_speed_delay'),
                options: this.getHoldSpeedDelayOptions(),
                selectedIndex: HOLD_SPEED_DELAYS.indexOf(this.playbackConfig.holdSpeedDelayMs),
                fontColor: this.params.themeColor,
                transparentBackground: true,
                onChange: (index: number) => {
                  const v = HOLD_SPEED_DELAYS[index];
                  this.params.updatePlaybackConfig(cfg => cfg.holdSpeedDelayMs = v);
                }
              })
            }
          }
        }
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        // ── 手势说明（随当前配置动态生成） ──
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_gesture_help_title') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            Column({ space: 6 }) {
              ForEach(this.helpLines(), (line: string) => {
                Text(line)
                  .fontSize(13)
                  .fontColor($r('app.color.yourtube_text_secondary'))
                  .width('100%')
              }, (line: string) => line)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          }
        }
        .backgroundColor($r('sys.color.comp_background_list_card'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)

        ListItem() {
          Column().height(24)
        }
        .padding({ left: 0, right: 0 })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16 })
      .edgeEffect(EdgeEffect.Spring)
      .alignListItem(ListItemAlign.Start)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}
