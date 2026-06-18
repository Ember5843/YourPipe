import {
  BottomBuilderShowType,
  DividerShowType,
  HdsNavigationBackgroundStyle,
  HdsNavigationDividerStyle,
  HdsNavigationIconItemStyle,
  HdsNavigationMenuItemOptions,
  HdsNavigationMenuContentOptions,
  HdsNavigationTitle,
  HdsNavigationTitleBarStyle,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleStyle,
  hdsMaterial,
  IconStyleMode,
  ScrollEffectType,
  SystemMaterialParams,
  TitleBarContentOptions,
  TitleBarStyleOptions
} from '@kit.UIDesignKit';

export interface YourTubeTitleBarOptions {
  title: ResourceStr;
  subtitle?: ResourceStr;
  menus?: HdsNavigationMenuItemOptions[];
  onBack?: () => void;
  backIcon?: Resource;
  backLabel?: ResourceStr;
  bottomBuilder?: () => void;
  bottomHeight?: Length;
  immersiveShadow?: boolean;
  materialEffect?: SystemMaterialParams;
  avoidLayoutSafeArea?: boolean;
}

export function buildYourTubeTitleBar(options: YourTubeTitleBarOptions): HdsNavigationTitleBarOptions {
  const iconStyle: HdsNavigationIconItemStyle = {
    backgroundColor: $r('app.color.yourtube_bg_surface_muted'),
    iconColor: $r('app.color.yourtube_text_primary'),
    textColor: $r('app.color.yourtube_text_primary')
  };
  const titleStyle: HdsNavigationTitleStyle = {
    mainTitleColor: $r('app.color.yourtube_text_primary'),
    subTitleColor: $r('app.color.yourtube_text_secondary'),
    mainTitleShadowColor: options.immersiveShadow ? $r('app.color.yourtube_shadow') : Color.Transparent,
    subTitleShadowColor: options.immersiveShadow ? $r('app.color.yourtube_shadow') : Color.Transparent
  };
  const title: HdsNavigationTitle = {
    mainTitle: options.title,
    subTitle: options.subtitle
  };
  const content: TitleBarContentOptions = {
    title,
    divider: {
      showType: DividerShowType.AUTO
    }
  };

  if (options.onBack) {
    content.backIcon = {
      icon: options.backIcon ?? $r('sys.symbol.arrow_left'),
      label: options.backLabel ?? 'Back',
      action: options.onBack,
      type: IconStyleMode.NORMAL
    };
  }

  if (options.menus && options.menus.length > 0) {
    const menu: HdsNavigationMenuContentOptions = {
      value: options.menus,
      maxCount: 3
    };
    content.menu = menu;
  }

  if (options.bottomBuilder) {
    content.bottomBuilder = {
      builder: options.bottomBuilder,
      height: options.bottomHeight ?? 52,
      showType: BottomBuilderShowType.DIRECTLY_SHOW
    };
  }

  const transparentBackground: HdsNavigationBackgroundStyle = {
    backgroundColor: $r('app.color.yourtube_titlebar_bg'),
    maskExtraHeight: 0,
    blurRadius: 24
  };
  const materialBackground: HdsNavigationBackgroundStyle = {
    backgroundColor: $r('app.color.yourtube_titlebar_bg_scrolled'),
    maskExtraHeight: 0,
    blurRadius: 28
  };
  const transparentDivider: HdsNavigationDividerStyle = {
    dividerColor: Color.Transparent
  };
  const materialDivider: HdsNavigationDividerStyle = {
    dividerColor: $r('app.color.yourtube_divider')
  };
  const originalStyle: HdsNavigationTitleBarStyle = {
    backgroundStyle: transparentBackground,
    contentStyle: {
      titleStyle,
      menuStyle: iconStyle,
      backIconStyle: iconStyle,
      subIconStyle: iconStyle,
      dividerStyle: transparentDivider
    }
  };
  const scrollEffectStyle: HdsNavigationTitleBarStyle = {
    backgroundStyle: materialBackground,
    contentStyle: {
      titleStyle,
      menuStyle: iconStyle,
      backIconStyle: iconStyle,
      subIconStyle: iconStyle,
      dividerStyle: materialDivider
    }
  };
  const systemMaterialEffect: SystemMaterialParams = options.materialEffect ?? {
    materialType: hdsMaterial.MaterialType.ADAPTIVE,
    materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
  };
  const style: TitleBarStyleOptions = {
    scrollEffectOpts: {
      enableScrollEffect: true,
      scrollEffectType: ScrollEffectType.GRADIENT_BLUR
    },
    systemMaterialEffect,
    originalStyle,
    scrollEffectStyle
  };

  return {
    avoidLayoutSafeArea: options.avoidLayoutSafeArea ?? false,
    enableComponentSafeArea: false,
    style,
    content
  };
}

export function buildSheetTitleBar(options: YourTubeTitleBarOptions): HdsNavigationTitleBarOptions {
  const opts = buildYourTubeTitleBar(options);
  opts.avoidLayoutSafeArea = false;
  return opts;
}

export function buildTitleMenu(icon: Resource, label: ResourceStr, action: () => void, componentId?: string): HdsNavigationMenuItemOptions {
  return {
    content: {
      icon,
      label,
      action,
      componentId,
      type: IconStyleMode.NORMAL
    }
  };
}
