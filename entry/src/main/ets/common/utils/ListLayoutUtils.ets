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
 */
export function getVideoGridColumnCount(contentWidthVp: number): number {
  if (contentWidthVp >= 1440) {
    return 5;
  }
  if (contentWidthVp >= 1080) {
    return 4;
  }
  if (contentWidthVp >= 760) {
    return 3;
  }
  if (contentWidthVp >= 520) {
    return 2;
  }
  return 1;
}
