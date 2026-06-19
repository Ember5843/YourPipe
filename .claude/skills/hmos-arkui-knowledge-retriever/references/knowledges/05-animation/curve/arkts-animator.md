# 帧动画（ohos.animator）

帧动画具备逐帧回调的特性，便于开发者在每一帧中处理需调整的属性。通过向应用提供[AnimatorResult](../reference/apis-arkui/js-apis-animator.md#animatorresult)的onFrame属性逐帧回调，帧动画使开发者能够在应用的每一帧设置属性值，从而实现组件属性值变化的自然过渡，营造出动画效果。帧动画接口详情可参考[@ohos.animator (动画)](../reference/apis-arkui/js-apis-animator.md)。

与属性动画相比，帧动画能让开发者实时感知动画进程，即时调整UI值，具备事件即时响应和可暂停的优势，但在性能上略逊于属性动画。当属性动画能满足需求时，建议优先采用属性动画接口实现。属性动画接口可参考[实现属性动画](../property/arkts-attribute-animation-apis.md)。

| 名称 | 实现方式 | 事件响应方式 | 可暂停 | 性能 |
| -------- | -------- | -------- | -------- |-------- |
| 帧动画（ohos.animator） | 开发者可每帧修改UI侧属性值，UI侧属性实时更新 | 实时响应 | 是 | 较差 |
| 属性动画 | UI侧只计算动画最终状态，动画过程为渲染值在改变，UI侧一直为动画最终状态，不感知实时渲染值 | 按最终状态响应 | 否 | 较好 |

如图所示，帧动画在动画过程中即可实时响应，而属性动画按最终状态响应。

## 使用帧动画实现动画效果

使用如下步骤可以创建一个简单的animator，并且在每个帧回调中打印当前插值。

1. 引入相关依赖。

   
   ``` TypeScript
   import { AnimatorOptions, AnimatorResult } from '@kit.ArkUI';
   ```

2. 创建执行动画的对象。

   
   ``` TypeScript
   // 创建动画的初始参数
   let options: AnimatorOptions = {
     duration: 1500,
     easing: 'friction',
     delay: 0,
     fill: 'forwards',
     direction: 'normal',
     iterations: 2,
     // 动画onFrame 插值首帧值
     begin: 200.0,
     // 动画onFrame 插值尾帧值
     end: 400.0
   };
   let result: AnimatorResult | undefined = this.getUIContext().createAnimator(options);
   // 设置接收到帧时回调，动画播放过程中每帧会调用onFrame回调
   result.onFrame = (value: number) => {
     hilog.info(DOMAIN, TAG, 'current value is :' + value);
   
   }
   ```

3. 播放动画。

   
   ``` TypeScript
   // 播放动画
   result.play();
   ```

4. 动画执行完成后手动释放AnimatorResult对象。

   
   ``` TypeScript
   // 释放动画对象
   result = undefined;
   ```

## 使用帧动画实现小球抛物运动

1. 引入相关依赖。

   
   ``` TypeScript
   import { AnimatorOptions, AnimatorResult } from '@kit.ArkUI';
   ```

2. 定义要做动画的组件。

   
   ``` TypeScript
   Button()
     .width(60)
     .height(60)
     .translate({ x: this.translateX, y: this.translateY })
   ```

3. 在onPageShow中创建AnimatorResult对象。

   
   ``` TypeScript
   onPageShow(): void {
     // 创建animatorResult对象
     this.animatorResult = this.getUIContext().createAnimator(this.animatorOption);
     this.animatorResult.onFrame = (progress: number) => {
       this.translateX = progress;
       if (progress > this.topWidth && this.translateY < this.bottomHeight) {
         this.translateY = Math.pow(progress - this.topWidth, 2) * this.g;
       }
     }
     // 动画取消时执行方法
     this.animatorResult.onCancel = () => {
       // 请将$r('app.string.cancel')替换为实际资源文件，在本示例中该资源文件的value值为"取消"
       this.animatorStatus = $r('app.string.cancel');
     }
     // 动画完成时执行方法
     this.animatorResult.onFinish = () => {
       // 请将$r('app.string.complete')替换为实际资源文件，在本示例中该资源文件的value值为"完成"
       this.animatorStatus = $r('app.string.complete');
     }
     // 动画重复播放时执行方法
     this.animatorResult.onRepeat = () => {
       // 'repeat'资源文件中的value值为'动画重复播放'
       hilog.info(DOMAIN, TAG, this.manager.getStringByNameSync('repeat'));
     }
   }
   ```

4. 定义动画播放，重置，暂停的按钮。

   
   ``` TypeScript
   // 请将$r('app.string.play')替换为实际资源文件，在本示例中该资源文件的value值为"播放"
   Button($r('app.string.play')).onClick(() => {
     this.animatorResult?.play();
     // 请将$r('app.string.playing')替换为实际资源文件，在本示例中该资源文件的value值为"播放中"
     this.animatorStatus = $r('app.string.playing');
   }).width(80).height(35)
   // 请将$r('app.string.reset')替换为实际资源文件，在本示例中该资源文件的value值为"重置"
   Button($r('app.string.reset')).onClick(() => {
     this.translateX = 0;
     this.translateY = 0;
   }).width(80).height(35)
   // 请将$r('app.string.pause')替换为实际资源文件，在本示例中该资源文件的value值为"暂停"
   Button($r('app.string.pause')).onClick(() => {
     this.animatorResult?.pause();
     // 请将$r('app.string.pause')替换为实际资源文件，在本示例中该资源文件的value值为"暂停"
     this.animatorStatus = $r('app.string.pause');
   }).width(80).height(35)
   ```

5. 在页面隐藏或销毁的生命周期中释放动画对象，避免内存泄漏。

   
   ``` TypeScript
   onPageHide(): void {
     this.animatorResult = undefined;
   }
   ```

完整示例如下。  

``` TypeScript
import { AnimatorOptions, AnimatorResult } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG: string = '[AnimatorTest]';

@Entry
@Component
struct Index {
  private context = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private manager = this.context.resourceManager;
  @State animatorResult: AnimatorResult | undefined = undefined;
  // 'create'资源文件中的value值为'创建'
  @State animatorStatus: string = 'create';
  begin: number = 0;
  end: number = 300;
  topWidth: number = 150;
  bottomHeight: number = 100;
  // 自由落体运动的加速度系数
  g: number = 0.18;
  animatorOption: AnimatorOptions = {
    duration: 4000,
    delay: 0,
    easing: 'linear',
    iterations: 1,
    fill: "forwards",
    direction: 'normal',
    begin: this.begin,
    end: this.end
  };
  @State translateX: number = 0;
  @State translateY: number = 0;

  onPageShow(): void {
    this.animatorResult = this.getUIContext().createAnimator(this.animatorOption);
    this.animatorResult.onFrame = (progress: number) => {
      this.translateX = progress;
      if (progress > this.topWidth && this.translateY < this.bottomHeight) {
        this.translateY = Math.pow(progress - this.topWidth, 2) * this.g;
      }
    }
    this.animatorResult.onCancel = () => {
      // 'cancel'资源文件中的value值为'取消'
      this.animatorStatus = 'cancel';
    }
    this.animatorResult.onFinish = () => {
      // 'complete'资源文件中的value值为'完成'
      this.animatorStatus = 'complete';
    }
    this.animatorResult.onRepeat = () => {
      // 'repeat'资源文件中的value值为'动画重复播放'
      hilog.info(DOMAIN, TAG, this.manager.getStringByNameSync('repeat'));
    }
  }

  onPageHide(): void {
    this.animatorResult = undefined;
  }

  build() {
    Column() {
      Column({ space: 30 }) {
        // 请将$r('app.string.play')替换为实际资源文件，在本示例中该资源文件的value值为"播放"
        Button($r('app.string.play')).onClick(() => {
          this.animatorResult?.play();
          // 'playing'资源文件中的value值为'播放中'
          this.animatorStatus = 'playing';
        }).width(80).height(35)
        // 请将$r('app.string.reset')替换为实际资源文件，在本示例中该资源文件的value值为"重置"
        Button($r('app.string.reset')).onClick(() => {
          this.translateX = 0;
          this.translateY = 0;
        }).width(80).height(35)
        // 请将$r('app.string.pause')替换为实际资源文件，在本示例中该资源文件的value值为"暂停"
        Button($r('app.string.pause')).onClick(() => {
          this.animatorResult?.pause();
          // 'pause'资源文件中的value值为'暂停'
          this.animatorStatus = 'pause';
        }).width(80).height(35)
      }.width('100%').height('25%')

      Stack() {
        Button()
          .width(60)
          .height(60)
          .translate({ x: this.translateX, y: this.translateY })
      }
      .width('100%')
      .height('45%')
      .align(Alignment.Start)
      // 'animatorStatus'资源文件中的value值为'当前动画状态为:'
      Text(this.manager.getStringByNameSync('animatorStatus') + this.manager.getStringByNameSync(this.animatorStatus))
    }.width('100%').height('100%')
  }
}
```

