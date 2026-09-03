import { curves } from "@kit.ArkUI";
import { UIConfig } from './AppState';

class AnimationUtil {
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
