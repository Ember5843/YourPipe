/**
 * 本地页滚动协调器：把本地页外层 Scroll 的 Scroller 暴露给 Index 根
 * HdsNavigation（bindToScrollable），使标题栏滚动渐变/材质效果在本地页
 * 同样生效。对标 features/subscription/SubscriptionScrollCoordinator。
 */
export class LocalScrollCoordinator {
  static readonly scroller: Scroller = new Scroller();

  private constructor() {}
}
