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
  // 按钮/图标始终用主题文字色，不参与滚动反色。
  const iconStyle: HdsNavigationIconItemStyle = {
    backgroundColor: $r('app.color.yourtube_bg_surface_muted'),
    iconColor: $r('app.color.yourtube_text_primary'),
    textColor: $r('app.color.yourtube_text_primary')
  };
  // 滚动后（模糊底）用主题主/次文字色。
  const scrolledTitleStyle: HdsNavigationTitleStyle = {
    mainTitleColor: $r('app.color.yourtube_text_primary'),
    subTitleColor: $r('app.color.yourtube_text_secondary'),
    mainTitleShadowColor: options.immersiveShadow ? $r('app.color.yourtube_shadow') : Color.Transparent,
    subTitleShadowColor: options.immersiveShadow ? $r('app.color.yourtube_shadow') : Color.Transparent
  };
  // 仅标题文字：透明态白字 → 滚动后主色（IMMERSIVE_GRADIENT_BLUR 做过渡）。
  // 不改 menu/backIcon 颜色。
  const useImmersiveTitleText: boolean = options.materialEffect !== undefined;
  const originalTitleStyle: HdsNavigationTitleStyle = useImmersiveTitleText
    ? {
      mainTitleColor: Color.White,
      subTitleColor: 'rgba(255,255,255,0.80)',
      mainTitleShadowColor: 'rgba(0,0,0,0.40)',
      subTitleShadowColor: 'rgba(0,0,0,0.30)'
    }
    : scrolledTitleStyle;
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
      titleStyle: originalTitleStyle,
      menuStyle: iconStyle,
      backIconStyle: iconStyle,
      subIconStyle: iconStyle,
      dividerStyle: transparentDivider
    }
  };
  const scrollEffectStyle: HdsNavigationTitleBarStyle = {
    backgroundStyle: materialBackground,
    contentStyle: {
      titleStyle: scrolledTitleStyle,
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
      scrollEffectType: useImmersiveTitleText
        ? ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
        : ScrollEffectType.GRADIENT_BLUR
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
  opts.enableComponentSafeArea = true;
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
