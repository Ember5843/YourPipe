/**
 * 收藏页滚动协调器：把收藏列表的 Scroller 暴露给 Index 根 HdsNavigation
 * （bindToScrollable），使标题栏滚动渐变/材质效果在收藏页同样生效。
 * 对标 features/subscription/SubscriptionScrollCoordinator。
 */
export class FavoritesScrollCoordinator {
  static readonly scroller: Scroller = new Scroller();

  private constructor() {}
}
