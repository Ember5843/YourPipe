import { curves, UIContext } from "@kit.ArkUI";
import { UIConfig } from './AppState';

class AnimationUtil {
  /**
   * 列表增删改查（CRUD）标准非对称转场：
   * - 不自带独立 .animation()，完全跟随外层 animateListMutation（UIContext.animateTo）的弹簧曲线同步驱动；
   * - 删除时仅被删条目原地淡出微缩，下方键值未变的条目绝不销毁重建，直接平滑上移拼接补位（类似 HTML FLIP 效果）。
   */
  public listItemCrudTransition(uiConfig: UIConfig): TransitionEffect | null {
    if (!uiConfig.isAnimation) {
      return null;
    }
    const appear = TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: 12 }));
    const disappear = TransitionEffect.OPACITY
      .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 }));
    return TransitionEffect.asymmetric(appear, disappear);
  }

  /**
   * 信息流首屏有序入场转场：按真实索引自上而下微阶梯淡入上浮（彻底取代伪随机 hash 延迟），
   * 退出直出 IDENTITY 防止滚动回收时误播退场动画。
   */
  public listItemEnterOrdered(index: number, uiConfig: UIConfig): TransitionEffect | null {
    if (!uiConfig.isAnimation) {
      return null;
    }
    const delay = Math.min(Math.max(0, index), 8) * 24;
    const appear = TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: 14 }))
      .animation({ duration: 240, curve: curves.springMotion(0.35, 0.85), delay });
    return TransitionEffect.asymmetric(appear, TransitionEffect.IDENTITY);
  }

  /**
   * 用 UIContext.animateTo 包裹列表状态数组变更（增/删/移/重排），
   * 让 ArkUI 自动驱动相邻列表项平滑补位，提供清晰的视觉引导。
   */
  public animateListMutation(
    uiConfig: UIConfig | undefined,
    mutation: () => void,
    uiContext?: UIContext
  ): void {
    const enabled = uiConfig ? uiConfig.isAnimation !== false : true;
    const ctx = uiContext ?? AppStorage.get<UIContext>('uiContext');
    if (!enabled || !ctx) {
      mutation();
      return;
    }
    try {
      ctx.animateTo({ curve: curves.springMotion(0.35, 0.85) }, () => {
        mutation();
      });
    } catch (_e) {
      mutation();
    }
  }

  private getStaggerDelay(id: string): number {
    let hash = 0;
    for (let i = 0; i < id.length; i++) {
      hash = ((hash << 5) - hash) + id.charCodeAt(i);
      hash |= 0;
    }
    return Math.abs(hash) % 200 + 30;
  }

  public isScaleTran(id: string | number, uiConfig: UIConfig): TransitionEffect | null {
    if (!uiConfig.isAnimation) {
      return null;
    }
    const delay = typeof id === 'string' ? this.getStaggerDelay(id) : (id * 10 + 30);
    return TransitionEffect.OPACITY
      .combine(TransitionEffect.scale({ x: 0, y: 0 }))
      .animation({ duration: uiConfig.animationSpeed, curve: curves.springMotion(0.6, 0.8), delay });
  }

  /**
   * 仅插入方向的缩放淡入（删除直出 IDENTITY）。
   * 用于 LazyForEach 滚动容器条目：滑入视区重建时不再播"原地缩小消失"，
   * 由调用方做一次性门控（回收重建不再重放）。
   */
  public isScaleTranEnter(id: string | number, uiConfig: UIConfig): TransitionEffect | null {
    if (!uiConfig.isAnimation) {
      return null;
    }
    const delay = typeof id === 'string' ? this.getStaggerDelay(id) : (id * 10 + 30);
    const insert = TransitionEffect.OPACITY
      .combine(TransitionEffect.scale({ x: 0, y: 0 }))
      .animation({ duration: uiConfig.animationSpeed, curve: curves.springMotion(0.6, 0.8), delay });
    return TransitionEffect.asymmetric(insert, TransitionEffect.IDENTITY);
  }

  public listItemremoveTran(id: string | number, uiConfig: UIConfig): TransitionEffect | null {
    if (!uiConfig.isAnimation) {
      return null;
    }
    const delay = typeof id === 'string' ? this.getStaggerDelay(id) : (id * 10 + 30);
    return TransitionEffect.OPACITY
      .animation({ duration: uiConfig.animationSpeed, curve: curves.springMotion(0.6, 0.8), delay });
  }

  public isSlide(i: number, uiConfig: UIConfig): TransitionEffect | null {
    if (!uiConfig.isAnimation) {
      return null;
    }
    return TransitionEffect.OPACITY
      .animation({ duration: uiConfig.animationSpeed, curve: curves.springMotion(0.6, 0.8), delay: i })
      .combine(TransitionEffect.SLIDE);
  }

  public isClickEffect(uiConfig: UIConfig): ClickEffect | null {
    if (!uiConfig.isAnimation) {
      return null;
    }
    return { level: ClickEffectLevel.MIDDLE, scale: 0.95 };
  }

  public isIconEffect(uiConfig: UIConfig): SymbolEffectStrategy | null {
    if (!uiConfig.isAnimation) {
      return null;
    }
    return SymbolEffectStrategy.SCALE;
  }

  public isScaleTranIcon(i: number, uiConfig: UIConfig): TransitionEffect | null {
    if (!uiConfig.isAnimation) {
      return null;
    }
    return TransitionEffect.scale({ x: 0, y: 0 })
      .combine(TransitionEffect.rotate({ angle: 360 }))
      .animation({ duration: uiConfig.animationSpeed, curve: curves.springMotion(0.6, 0.8), delay: i * 30 + 50 });
  }

  public isClickAnimation(uiConfig: UIConfig): ICurve | null {
    if (!uiConfig.isAnimation) return null;
    return curves.springMotion(0.3, 0.8);
  }

  public isMenuTransition(uiConfig: UIConfig): TransitionEffect | null {
    if (!uiConfig.isAnimation) {
      return null;
    }
    return TransitionEffect.asymmetric(
      TransitionEffect.move(TransitionEdge.END),
      TransitionEffect.move(TransitionEdge.START)
    )
      .animation({ duration: uiConfig.animationSpeed, curve: Curve.Ease })
      .combine(TransitionEffect.OPACITY);
  }

  public tabTransition(uiConfig: UIConfig): TransitionEffect | null {
    if (!uiConfig.isAnimation) {
      return null;
    }
    return TransitionEffect.OPACITY
      .animation({ duration: 250, curve: curves.springMotion(0.3, 0.8) });
  }

  public pageTransition(uiConfig: UIConfig): TransitionEffect | null {
    if (!uiConfig.isAnimation) {
      return null;
    }
    return TransitionEffect.asymmetric(
      TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut }),
      TransitionEffect.OPACITY.animation({ duration: 300, curve: Curve.EaseInOut })
    );
  }
}

export const customAnimationUtil = new AnimationUtil();
