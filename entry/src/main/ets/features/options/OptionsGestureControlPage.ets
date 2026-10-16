import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import {
  PlaybackConfig,
  HOLD_SPEED_VALUES, HOLD_SPEED_DELAYS, getHoldSpeedDelayDisplay,
  GESTURE_SCHEME_LABELS, getGestureSchemeDisplay,
  DOUBLE_TAP_ACTION_LABELS, getDoubleTapActionDisplay,
  DOUBLE_TAP_SEEK_SECONDS, getDoubleTapSeekDisplay,
} from '../../common/PlaybackConfig';

interface OptionsGestureControlPageParams {
  themeColor: ResourceColor;
  clickEffectEnabled: ClickEffect | null;
  updatePlaybackConfig: (updater: (cfg: PlaybackConfig) => void) => void;
}

@Component
export struct OptionsGestureControlPage {
  @StorageProp('themePrimaryColor') themePrimary: string = '#E53935';
  @StorageLink('playbackConfig') playbackConfig: PlaybackConfig = new PlaybackConfig();

  @Prop params: OptionsGestureControlPageParams = {
    themeColor: '#E53935',
    clickEffectEnabled: null,
    updatePlaybackConfig: () => {}
  };

  private getSchemeOptions(): SelectOption[] {
    return GESTURE_SCHEME_LABELS.map(s => ({ value: getGestureSchemeDisplay(s) } as SelectOption));
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

  /**
   * 结构项改动（双击动作 / 滑动组 / 长按开关）：按改动后的组合回推方案——
   * 仍与某预设一致就显示该预设，都不一致才标「自定义」。
   * 参数项（双击步长、长按倍速与触发延迟）不走这里，改它们不改变方案选择。
   * 预设应用时 Toggle 的 isOn 程序化变化也会触发 onChange，走"组合回推"而不是
   * 无条件置 custom，正是为了让它保持预设、不被误改回自定义。
   */
  private markCustom(updater: (cfg: PlaybackConfig) => void): void {
    this.params.updatePlaybackConfig(cfg => {
      updater(cfg);
      cfg.gestureScheme = PlaybackConfig.schemeForGestureConfig(cfg);
    });
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
        // ── 交互方案（预设：增强 / 经典 YouTube / 自定义） ──
        ListItem() {
          PlaybackSectionTitle({ title: $r('app.string.yt_gesture_scheme_title') })
        }
        .padding({ left: 0, right: 0 })

        ListItemGroup() {
          ListItem() {
            PlaybackSelectRow({
              title: $r('app.string.yt_gesture_scheme_label'),
              options: this.getSchemeOptions(),
              selectedIndex: GESTURE_SCHEME_LABELS.indexOf(this.playbackConfig.gestureScheme),
              fontColor: this.params.themeColor,
              transparentBackground: true,
              onChange: (index: number) => {
                const scheme = GESTURE_SCHEME_LABELS[index];
                // 程序化回显 / 重复选择：不再重复应用（避免自触发回环）
                if (scheme === this.playbackConfig.gestureScheme) {
                  return;
                }
                this.params.updatePlaybackConfig(cfg => PlaybackConfig.applyGesturePreset(cfg, scheme));
              }
            })
          }

          ListItem() {
            Row() {
              Text($r('app.string.yt_gesture_scheme_subtitle'))
                .fontSize(12)
                .fontColor($r('app.color.yourtube_text_quaternary'))
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 8, bottom: 10 })
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
                this.markCustom(cfg => cfg.doubleTapAction = action);
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
                  // 步长是方案的调节参数：改动它不改变方案选择（不标记自定义）
                  const secs = DOUBLE_TAP_SEEK_SECONDS[index];
                  this.params.updatePlaybackConfig(cfg => cfg.doubleTapSeekSeconds = secs);
                }
              })
            }
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

        // ── 分项开关（滑动组 / 长按组） ──
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
                this.markCustom(cfg => cfg.gestureSeekEnabled = val);
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
                this.markCustom(cfg => cfg.gestureBrightnessEnabled = val);
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
                this.markCustom(cfg => cfg.gestureVolumeEnabled = val);
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
                this.markCustom(cfg => cfg.holdSpeedEnabled = val);
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
                  // 参数项：不参与方案判定（改它不改变方案选择）
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
                  // 参数项：不参与方案判定
                  this.params.updatePlaybackConfig(cfg => cfg.holdSpeedDelayMs = v);
                }
              })
            }
          }
        }
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
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
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
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
