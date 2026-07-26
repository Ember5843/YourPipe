/**
 * 条式（list 模式）视频列表的宽屏多列策略。
 * 手机保持单列；大屏（平板展开态/2in1/电视）提升信息密度。
 * 阈值与 BreakpointConstants 对齐：lg=840vp。
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
