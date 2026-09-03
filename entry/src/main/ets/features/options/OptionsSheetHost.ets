import { AppLog } from '../../common/AppLog';
import { customAnimationUtil } from '../../common/AnimationUtil';
import { NetworkProxyConfig } from '../../common/NetworkProxyConfig';
import { LanguagePickerItem } from '../../common/components/LanguagePickerDialog';
import { LanguagePickerPage } from '../../common/components/LanguagePickerPage';
import { LogPage } from '../../common/components/LogPage';
import { AboutPage, OpenSourcePage, AiModelsPage, ChangelogPage } from '../../common/components/AboutPage';
import { buildTitleMenu, buildSheetTitleBar } from '../../common/components/HdsTitleBar';
import { UIConfig, YourtubeDarkMode } from '../../common/AppState';
import { COLOR_PRESETS } from '../../common/ThemeManager';
import { PlaybackConfig, VideoQualityCap } from '../../common/PlaybackConfig';
import { OptionsMainPage } from './OptionsMainPage';
import { OptionsAppearancePage } from './OptionsAppearancePage';
import { OptionsPlaybackPage } from './OptionsPlaybackPage';
import { OptionsLanguageAndRegionPage } from './OptionsLanguageAndRegionPage';
import { OptionsRecoveryPage } from './OptionsRecoveryPage';
import { OptionsDataAccountPage } from './OptionsDataAccountPage';
import { OptionsNetworkPage } from './OptionsNetworkPage';
// [DISABLED] P3：import { OptionsAiTranslatePage } from './OptionsAiTranslatePage';
import { HelpGuidePage } from '../help/HelpGuidePage';
import { WebViewLoginPage } from '../auth/WebViewLoginPage';
import { DeviceQrLoginPage } from '../auth/DeviceQrLoginPage';
import {
  HdsNavigation,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  HdsNavigationTitleMode
} from '@kit.UIDesignKit';

const logger = AppLog.getInstance('OptionsSheetHost');

/**
 * Index 侧 bindSheet.onDisappear 需要清栈，但 optionsNavStack 归
 * OptionsSheetHost 持有；host 挂载时把实现注册进来（sheet 弹出必在挂载之后，
 * 默认值不会被真实触发）。
 */
export class OptionsSheetActions {
  clearPath: () => void = () => {};
}

/** OptionsSheetHost 入参（单对象 @Prop，与 OptionsMainPageParams 同模式）。 */
export interface OptionsSheetHostParams {
  actions: OptionsSheetActions;
  appLangItems: LanguagePickerItem[];
  contentLangItems: LanguagePickerItem[];
  contentCountryItems: LanguagePickerItem[];
  onClose: () => void;
  updateUiConfig: (mutator: (cfg: UIConfig) => void) => void;
  updatePlaybackConfig: (mutator: (cfg: PlaybackConfig) => void) => void;
  applyLanguageSelection: (languageCode: string) => void;
  applyDarkModeSelection: (mode: YourtubeDarkMode) => void;
  reloadHomeForSearchLocaleChange: () => void;
  refreshHomeAfterAuthChange: () => void;
  handleLoginSuccess: () => void;
  onPlayerClientChanged: (guest: string, auth: string) => void;
  onResetSettings: () => void;
  onClearAllData: () => void;
}

/**
 * Options sheet 宿主：单个内层 HdsNavigation(optionsNavStack) + 各 options 子页
 * destination（原 Index.OptionsPanel / OptionsPageMap 纯迁移）。涉及 Index 状态
 * 的动作（关 sheet、重置/清数据确认弹窗、登录后置动作、首页刷新）全部经
 * params 回调回 Index。
 */
@Component
export struct OptionsSheetHost {
  @Prop params: OptionsSheetHostParams = {
    actions: new OptionsSheetActions(),
    appLangItems: [] as LanguagePickerItem[],
    contentLangItems: [] as LanguagePickerItem[],
    contentCountryItems: [] as LanguagePickerItem[],
    onClose: () => {},
    updateUiConfig: () => {},
    updatePlaybackConfig: () => {},
    applyLanguageSelection: () => {},
    applyDarkModeSelection: () => {},
    reloadHomeForSearchLocaleChange: () => {},
    refreshHomeAfterAuthChange: () => {},
    handleLoginSuccess: () => {},
    onPlayerClientChanged: () => {},
    onResetSettings: () => {},
    onClearAllData: () => {}
  };
  @StorageLink('uiConfig') uiConfig: UIConfig = new UIConfig();
  @StorageProp('themePrimaryColor') themePrimary: string = COLOR_PRESETS[0].primary;
  @State optionsNavStack: NavPathStack = new NavPathStack();
  @State optionsDepth: number = 0;
  private webViewLoginBackHandler: (() => boolean) | null = null;

  aboutToAppear() {
    this.params.actions.clearPath = () => {
      this.clearOptionsPath();
    };
  }

  private pushOptionsPath(name: string): void {
    this.optionsNavStack.pushPathByName(name, null);
    this.optionsDepth = this.optionsNavStack.size();
  }

  private popOptionsPath(): void {
    this.optionsNavStack.pop();
    this.optionsDepth = Math.max(0, this.optionsDepth - 1);
  }

  private clearOptionsPath(): void {
    this.optionsNavStack.clear();
    this.optionsDepth = 0;
  }

  private getQualityDisplay(quality: VideoQualityCap): ResourceStr {
    switch (quality) {
      case 'best': return $r('app.string.yt_quality_best');
      case '4320p': return '8K (4320p)';
      case '2160p': return '4K (2160p)';
      case '1440p': return '2K (1440p)';
      default: return quality;
    }
  }

  build() {
    // 超宽窗口（2in1/TV 横屏）下限制选项页最大宽度并居中，避免整行拉满全宽
    Column() {
      HdsNavigation(this.optionsNavStack) {
        OptionsMainPage({
            params: {
              clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
              appLangItems: this.params.appLangItems,
              contentLangItems: this.params.contentLangItems,
              contentCountryItems: this.params.contentCountryItems,
              onDataAccountClick: () => { this.pushOptionsPath('data_account'); },
              onLanguageClick: () => { this.pushOptionsPath('language'); },
              onPlaybackClick: () => { this.pushOptionsPath('playback'); },
              onNetworkClick: () => { this.pushOptionsPath('network'); },
              // [DISABLED] P3：onAiTranslateClick: () => { this.pushOptionsPath('ai_translate'); },
              onAppearanceClick: () => { this.pushOptionsPath('appearance'); },
              onLogClick: () => { this.pushOptionsPath('log_page'); },
              onHelpClick: () => { this.pushOptionsPath('help_page'); },
              onRecoveryClick: () => { this.pushOptionsPath('recovery'); },
              onAboutClick: () => { this.pushOptionsPath('about_page'); }
            }
          })
          .width('100%')
          .height('100%')
      }
      .mode(NavigationMode.Stack)
      .navDestination(this.OptionsPageMap)
      .titleMode(HdsNavigationTitleMode.MINI)
      // 隐藏 HdsNavigation 自带的返回键：一级菜单（栈空）不需要返回，
      // 子页返回由 OptionsNavScaffold 的自定义 backIcon 承担
      .hideBackButton(true)
      .titleBar(buildSheetTitleBar({
        title: $r('app.string.yt_option_title'),
        onBack: this.optionsDepth > 0 ? () => {
          this.popOptionsPath();
        } : undefined,
        menus: [
          buildTitleMenu($r('sys.symbol.xmark'), $r('app.string.yt_action_close'), () => {
            this.params.onClose();
          })
        ]
      }))
      .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
      .clip(true)
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: 720 })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  OptionsPageMap(name: string) {
    if (name === 'help_page') {
      OptionsNavScaffold({
        title: $r('app.string.yt_option_help'),
        onBack: () => { this.popOptionsPath(); }
      }) {
        HelpGuidePage({
          params: {
            mode: 'fromSettings',
            onResetSettings: () => {
              this.params.onResetSettings();
            },
            onFinish: () => {
              this.popOptionsPath();
            }
          }
        })
      }
    } else if (name === 'language') {
      OptionsNavScaffold({
        title: $r('app.string.yt_section_language_region'),
        onBack: () => { this.popOptionsPath(); }
      }) {
          OptionsLanguageAndRegionPage({
            params: {
              appLangItems: this.params.appLangItems,
              contentLangItems: this.params.contentLangItems,
              contentCountryItems: this.params.contentCountryItems,
              themeColor: this.themePrimary,
              clickEffectEnabled: customAnimationUtil.isClickEffect(this.uiConfig),
              updateUiConfig: this.params.updateUiConfig,
              reloadHomeForSearchLocaleChange: this.params.reloadHomeForSearchLocaleChange,
              applyLanguageSelection: this.params.applyLanguageSelection
            }
          })
      }
    } else if (name === 'ai_translate') {
      // [DISABLED] P3 AI 字幕设置页 destination（入口已禁用，本分支不可达；代码保留）：
      // OptionsNavScaffold({
      //   title: $r('app.string.yt_option_ai_subtitle'),
      //   onBack: () => { this.popOptionsPath(); }
      // }) {
      //   OptionsAiTranslatePage({
      //     params: {
      //       themeColor: this.themePrimary
      //     }
      //   })
      // }
    } else if (name === 'data_account') {
      OptionsNavScaffold({
        title: $r('app.string.yt_option_data_account'),
        onBack: () => { this.popOptionsPath(); }
      }) {
        OptionsDataAccountPage({
          params: {
            onLoginClick: () => { this.pushOptionsPath('webview_login'); },
            onDeviceQrLoginClick: () => { this.pushOptionsPath('device_qr_login'); },
            updateUiConfig: this.params.updateUiConfig,
            onHomeFeedStyleChanged: () => { this.params.refreshHomeAfterAuthChange(); },
            onAuthChanged: () => { this.params.refreshHomeAfterAuthChange(); },
            onLoginSuccess: () => { this.params.handleLoginSuccess(); }
          }
        })
      }
    } else if (name === 'device_qr_login') {
      OptionsNavScaffold({
        title: $r('app.string.yt_device_qr_sign_in'),
        onBack: () => { this.popOptionsPath(); }
      }) {
        DeviceQrLoginPage({
          onSuccess: () => {
            this.params.handleLoginSuccess();
            this.webViewLoginBackHandler = null;
            this.popOptionsPath();
            try {
              this.getUIContext().getPromptAction().showToast({
                message: $r('app.string.yt_toast_login_success'),
                duration: 2000
              });
            } catch (_e) {
              // ignore
            }
          },
          onCancel: () => {
            this.popOptionsPath();
          }
        })
      }
    } else if (name === 'webview_login') {
      OptionsNavScaffold({
        title: $r('app.string.yt_google_web_sign_in_title'),
        onBack: () => {
          // WebView 内部可消费返回（页面栈回退）；消费不了才退出登录页
          if (this.webViewLoginBackHandler && this.webViewLoginBackHandler()) {
            return;
          }
          this.webViewLoginBackHandler = null;
          this.popOptionsPath();
        }
      }) {
        WebViewLoginPage({
          onSuccess: () => {
            this.params.handleLoginSuccess();
            this.popOptionsPath();
            try {
              this.getUIContext().getPromptAction().showToast({
                message: $r('app.string.yt_toast_login_success'),
                duration: 2000
              });
              logger.info('Login success toast shown');
            } catch (error) {
              logger.warn(`Login success toast failed: ${JSON.stringify(error)}`);
            }
          },
          onCancel: () => { this.popOptionsPath(); },
          onRegisterBackHandler: (handler: () => boolean) => {
            this.webViewLoginBackHandler = handler;
          }
        })
      }
    } else if (name === 'appearance') {
      OptionsNavScaffold({
        title: $r('app.string.yt_option_appearance'),
        onBack: () => { this.popOptionsPath(); }
      }) {
          OptionsAppearancePage({
            params: {
              themeColor: this.themePrimary,
              applyDarkModeSelection: this.params.applyDarkModeSelection,
              updateUiConfig: this.params.updateUiConfig
            }
          })
      }
    } else if (name === 'network') {
      OptionsNavScaffold({
        title: $r('app.string.yt_option_network'),
        onBack: () => { this.popOptionsPath(); }
      }) {
        OptionsNetworkPage({
          params: {
            themeColor: this.themePrimary,
            onConfigChanged: (cfg: NetworkProxyConfig) => {
              AppStorage.setOrCreate('networkProxyConfig', cfg);
            }
          }
        })
      }
    } else if (name === 'app_lang') {
      LanguagePickerPage({
        title: $r('app.string.yt_setting_ui_language'),
        items: this.params.appLangItems,
        selectedCode: this.uiConfig.userLanguage,
        onSelect: (code: string) => { this.params.applyLanguageSelection(code); },
        onBack: () => { this.popOptionsPath(); }
      })
    } else if (name === 'content_lang') {
      LanguagePickerPage({
        title: $r('app.string.yt_setting_content_language'),
        items: this.params.contentLangItems,
        selectedCode: this.uiConfig.searchLanguage,
        onSelect: (code: string) => {
          this.params.updateUiConfig(cfg => cfg.searchLanguage = code === 'default' ? 'default' : code);
          this.params.reloadHomeForSearchLocaleChange();
        },
        onBack: () => { this.popOptionsPath(); }
      })
    } else if (name === 'content_country') {
      LanguagePickerPage({
        title: $r('app.string.yt_setting_content_region'),
        items: this.params.contentCountryItems,
        selectedCode: this.uiConfig.searchCountry,
        onSelect: (code: string) => {
          this.params.updateUiConfig(cfg => cfg.searchCountry = code === 'default' ? 'default' : code.toUpperCase());
          this.params.reloadHomeForSearchLocaleChange();
        },
        onBack: () => { this.popOptionsPath(); }
      })
    } else if (name === 'log_page') {
      OptionsNavScaffold({
        title: $r('app.string.yt_log_title'),
        onBack: () => { this.popOptionsPath(); }
      }) {
        LogPage({
          onBack: () => { this.popOptionsPath(); }
        })
      }
    } else if (name === 'about_page') {
      OptionsNavScaffold({
        title: $r('app.string.yt_option_about'),
        onBack: () => { this.popOptionsPath(); }
      }) {
        AboutPage({
          onNavigate: (subPage: string) => { this.pushOptionsPath(subPage); }
        })
      }
    } else if (name === 'about_open_source') {
      OptionsNavScaffold({
        title: $r('app.string.yt_about_open_source'),
        onBack: () => { this.popOptionsPath(); }
      }) {
        OpenSourcePage()
      }
    } else if (name === 'about_ai_models') {
      OptionsNavScaffold({
        title: $r('app.string.yt_about_ai_models'),
        onBack: () => { this.popOptionsPath(); }
      }) {
        AiModelsPage()
      }
    } else if (name === 'about_changelog') {
      OptionsNavScaffold({
        title: $r('app.string.yt_about_changelog'),
        onBack: () => { this.popOptionsPath(); }
      }) {
        ChangelogPage()
      }
    } else if (name === 'playback') {
      OptionsNavScaffold({
        title: $r('app.string.yt_section_playback'),
        onBack: () => { this.popOptionsPath(); }
      }) {
          OptionsPlaybackPage({
            params: {
              themeColor: this.themePrimary,
              appLangItems: this.params.appLangItems,
              updatePlaybackConfig: this.params.updatePlaybackConfig,
              updateUiConfig: this.params.updateUiConfig,
              getQualityDisplay: this.getQualityDisplay.bind(this),
              onPlayerClientChanged: this.params.onPlayerClientChanged
            }
          })
      }
    } else if (name === 'recovery') {
      OptionsNavScaffold({
        title: $r('app.string.yt_option_recovery'),
        onBack: () => { this.popOptionsPath(); }
      }) {
          OptionsRecoveryPage({
            params: {
              onResetSettingsClick: () => { this.params.onResetSettings(); },
              onClearAllDataClick: () => { this.params.onClearAllData(); }
            }
          })
      }
    }
  }
}

/**
 * Options 子页通用脚手架：HdsNavDestination + MINI 标题栏 + 返回处理。
 * OptionsPageMap 的各子页只提供标题、onBack 和正文（@BuilderParam content）。
 */
@Component
struct OptionsNavScaffold {
  @Prop title: Resource = $r('app.string.yt_option_title');
  /** 标题栏返回键与系统返回手势共用此回调 */
  onBack: () => void = () => {};
  @BuilderParam content: () => void = this.defaultContent;

  @Builder
  defaultContent() {
  }

  build() {
    HdsNavDestination() {
      this.content()
    }
    .titleMode(HdsNavDestinationTitleMode.MINI)
    .titleBar(buildSheetTitleBar({
      title: this.title,
      onBack: () => {
        this.onBack();
      }
    }))
    .backgroundColor($r('sys.color.ohos_id_color_dialog_bg'))
    .onBackPressed(() => {
      this.onBack();
      return true;
    })
  }
}
