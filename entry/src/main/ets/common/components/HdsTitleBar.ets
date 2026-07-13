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
  // 沉浸光感开启时走 IMMERSIVE_GRADIENT_BLUR：标题/图标随底层内容智能反色，
  // 并从透明态白字过渡到滚动后的主文字色（系统智能反色 + 材质）。
  const useImmersiveContrast: boolean = options.materialEffect !== undefined;
  const iconStyle: HdsNavigationIconItemStyle = {
    backgroundColor: $r('app.color.yourtube_bg_surface_muted'),
    iconColor: $r('app.color.yourtube_text_primary'),
    textColor: $r('app.color.yourtube_text_primary')
  };
  const originalIconStyle: HdsNavigationIconItemStyle = useImmersiveContrast
    ? {
      backgroundColor: 'rgba(255,255,255,0.22)',
      iconColor: Color.White,
      textColor: Color.White
    }
    : iconStyle;
  const titleStyle: HdsNavigationTitleStyle = {
    mainTitleColor: $r('app.color.yourtube_text_primary'),
    subTitleColor: $r('app.color.yourtube_text_secondary'),
    mainTitleShadowColor: options.immersiveShadow ? $r('app.color.yourtube_shadow') : Color.Transparent,
    subTitleShadowColor: options.immersiveShadow ? $r('app.color.yourtube_shadow') : Color.Transparent
  };
  const originalTitleStyle: HdsNavigationTitleStyle = useImmersiveContrast
    ? {
      mainTitleColor: Color.White,
      subTitleColor: 'rgba(255,255,255,0.78)',
      mainTitleShadowColor: 'rgba(0,0,0,0.35)',
      subTitleShadowColor: 'rgba(0,0,0,0.28)'
    }
    : titleStyle;
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
    backgroundColor: useImmersiveContrast ? Color.Transparent : $r('app.color.yourtube_titlebar_bg'),
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
      menuStyle: originalIconStyle,
      backIconStyle: originalIconStyle,
      subIconStyle: originalIconStyle,
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
      scrollEffectType: useImmersiveContrast
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
