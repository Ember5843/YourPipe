/**
 * 条式（list 模式）视频列表的宽屏多列策略。
 * 手机保持单列；大屏（平板展开态/2in1/电视）提升信息密度。
 * 阈值与 BreakpointSystem 的断点表对齐：lg=840vp。
 */
export function getWideListColumnCount(contentWidthVp: number): number {
  if (contentWidthVp >= 1500) {
    return 3;
  }
  if (contentWidthVp >= 840) {
    return 2;
  }
  return 1;
}

/** 信息流网格统一的左右边距（vp）。 */
export const GRID_SIDE_PADDING: number = 12;

/**
 * 设备宽（px）→ 信息流内容宽（vp）：
 * deviceWidthPx<=0 时按 360vp 兜底，内容宽下限 320vp，两侧各扣 sidePaddingVp。
 */
export function getFeedContentWidthVp(uiContext: UIContext, deviceWidthPx: number,
  sidePaddingVp: number = GRID_SIDE_PADDING): number {
  const widthPx = deviceWidthPx > 0 ? deviceWidthPx : uiContext.vp2px(360);
  return Math.max(320, uiContext.px2vp(widthPx) - sidePaddingVp * 2);
}

/**
 * 网格模式（grid 布局）视频卡片列数。
 * 阈值表 1440/1080/760/520 —— 原 Index / SearchPage / PlaylistDetailPage /
 * ChannelVideoTab / SubscriptionFeedPage / FavoritesPage 六处逐字节复制的收口。
 * densityOffset 来自 UIConfig.homeGridDensity（紧凑 +1 / 宽松 -1 / 自动 0），
 * 在阈值基数上偏移后钳位到 [1,5]；±1 不会脱离宽度阈值表的合理区间。
 */
export function getVideoGridColumnCount(contentWidthVp: number, densityOffset: number = 0): number {
  let base: number = 1;
  if (contentWidthVp >= 1440) {
    base = 5;
  } else if (contentWidthVp >= 1080) {
    base = 4;
  } else if (contentWidthVp >= 760) {
    base = 3;
  } else if (contentWidthVp >= 520) {
    base = 2;
  }
  return Math.max(1, Math.min(5, base + densityOffset));
}
