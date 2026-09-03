import { SelectOption } from 'mediaservice';
import { PlaybackSectionTitle } from '../../common/components/PlaybackSectionTitle';
import { PlaybackSelectRow } from '../../common/components/PlaybackSelectRow';
import { PlaybackToggleRow } from '../../common/components/PlaybackToggleRow';
import { SECTION_CARD_RADIUS } from '../../common/components/MediaCardTokens';
import {
  PlaybackConfig,
  HOLD_SPEED_VALUES, HOLD_SPEED_DELAYS, getHoldSpeedDelayDisplay,
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

  private getHoldSpeedOptions(): SelectOption[] {
    return HOLD_SPEED_VALUES.map(v => ({ value: `${v}x` } as SelectOption));
  }

  private getHoldSpeedDelayOptions(): SelectOption[] {
    return HOLD_SPEED_DELAYS.map(v => ({ value: getHoldSpeedDelayDisplay(v) } as SelectOption));
  }

  build() {
    Column() {
      List({ space: 6 }) {
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
        .backgroundColor($r('app.color.yourtube_bg_surface_muted'))
        .borderRadius(SECTION_CARD_RADIUS)
        .clip(true)
        .divider({ strokeWidth: 1, color: $r('app.color.yourtube_divider'), startMargin: 16, endMargin: 16 })

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
