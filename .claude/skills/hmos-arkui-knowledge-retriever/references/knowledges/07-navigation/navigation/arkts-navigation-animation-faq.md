# Navigation动画常见问题

## Dialog类型NavDestination蒙层动画不流畅

**问题现象**

使用[NavDestinationMode.DIALOG](../reference/apis-arkui/arkui-ts/ts-basic-components-navdestination.md#navdestinationmode枚举说明11)默认转场动画，出现如下2个问题：

- 将蒙层背景色设置在页面上：pop页面的时候蒙层没有马上消失，而是等内容下滑退出后才消失。

- 将蒙层背景色设置在内容区域：蒙层一起从上向下退出。

期望退出时蒙层渐隐，同时内容区域向下退出。

**解决措施**

在[onWillAppear](../reference/apis-arkui/arkui-ts/ts-basic-components-navdestination.md#onwillappear12)、[onWillDisappear](../reference/apis-arkui/arkui-ts/ts-basic-components-navdestination.md#onwilldisappear12)生命周期执行背景色动画，示例如下：

``` TypeScript
@Builder
export function DialogNavDestinationBuilder() {
  DialogNavDestination();
}

@Component
export struct DialogNavDestination {
  stack: NavPathStack = AppStorage.get<NavPathStack>('basicNavigationStack')!;
  @State backColor: ResourceColor = '#0000000';

  build() {
    NavDestination() {
      Stack() {
        Text('Dialog')
          .fontSize(44)
          .backgroundColor(Color.White)
      }
      .width('100%')
      .height('100%')
    }
    .hideTitleBar(true)
    .backgroundColor(this.backColor)
    .mode(NavDestinationMode.DIALOG)
    .onWillAppear(() => {
      //启动时候蒙层渐现
      this.getUIContext().animateTo({ duration:450 }, () => {
        this.backColor = '#66000000';
      });
    })
    .onWillDisappear(() => {
      // 消失时候蒙层渐隐
      this.getUIContext().animateTo({ duration: 450 }, () => {
        this.backColor = '#00000000';
      });
    })
  }
}
```

## router、navigation动画冲突

**问题现象**

router跳到navigation页面，navigation在aboutToAppear回调里马上push一个NavDestination页面，这样会导致page和NavDestination页面同时显示动画，效果不好。

**解决措施**

关闭aboutToAppear中push的动画：

``` TypeScript
@Entry
@Component
struct NavigationPage {
  navStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    AppStorage.setOrCreate<NavPathStack>('basicNavigationStack', this.navStack);
    this.navStack.pushPath({ name: 'animation-BasicNavDestination' }, false); // 关闭本次push动画即可
  }

  build() {
    Navigation(this.navStack) {
      // ...
    }
  }
}
```

## pop、push同时进行却执行pop动画

**问题现象**

先pop栈顶页面，再马上push一个页面，动画效果是栈顶页面pop的动画，并不是PageOne的push动画。

``` TypeScript
this.stack.pop();
this.stack.pushPath({ name: 'animation-BasicNavDestination' });
```

**解决措施**

首先在一次操作中，不管调用了多少次pop、push接口，Navigation会计算最终结果，并且只做一次动画。

当前Navigation页面切换的动画会以操作前的栈顶页面为主，如果栈顶页面在操作后不在栈中，则执行pop动画，若在栈中则执行push动画。

例如，假设当前栈顶是`PageTop`，先执行pop将`PageTop`移除再执行push将`PageNew`入栈，本次操作完成后`PageTop`页面已不在栈中，所以最终执行的动画是pop动画。

如果想移除页面的同时push另一个页面并且执行push动画，可以将push的页面设置为NEW_INSTANCE，默认执行push动画：

``` TypeScript
this.stack.pop();
this.stack.pushPath({ name: 'animation-BasicNavDestination' }, { launchMode: LaunchMode.NEW_INSTANCE });
```

## 跳转动画是否有结束回调

当前系统动画并没有提供动画结束回调，仅自定义转场动画提供了结束回调，需要自行实现[自定义转场动画](./arkts-navigation-animation.md#自定义转场)，相关接口：[NavDestinationTransition](../reference/apis-arkui/arkui-ts/ts-basic-components-navdestination.md#navdestinationtransition15)、 [NavigationAnimatedTransition](../reference/apis-arkui/arkui-ts/ts-basic-components-navigation.md#navigationanimatedtransition11)。

## 如何实现Navigation和NavDestination之间的共享元素转场

目前仅NavDestination间的跳转支持共享元素转场动效，NavBar与NavDestination间的跳转系统暂不支持共享元素动效。

NavDestination的共享元素转场需要配合[geometryTransition](../reference/apis-arkui/arkui-ts/ts-transition-animation-geometrytransition.md)接口实现，并且：

- 需要[关闭转场](arkts-navigation-animation.md)。
- 跳转接口需要在[animateTo](../reference/apis-arkui/arkts-apis-uicontext-uicontext.md#animateto)动画闭包内执行。
- 给内容组件设置[geometryTransition](../reference/apis-arkui/arkui-ts/ts-transition-animation-geometrytransition.md)属性，不要设置到NavDestination上。

示例请参考：[共享元素转场](./arkts-navigation-animation.md#共享元素转场)。

## 给NavDestination设置zIndex后跳转动画异常

[zIndex](../reference/apis-arkui/arkui-ts/ts-universal-attributes-z-order.md#zindex)用于修改组件显示层级，给NavDestination设置该属性会覆盖系统设置的层级，导致动画被打乱。因此不建议给NavDestination设置zIndex。

此外也不建议设置如：[transition](../reference/apis-arkui/arkui-ts/ts-transition-animation-component.md#transition)、[geometryTransition](../reference/apis-arkui/arkui-ts/ts-transition-animation-geometrytransition.md)、[sharedTransition](../reference/apis-arkui/arkui-ts/ts-transition-animation-shared-elements.md#sharedtransition)、[animation](../reference/apis-arkui/arkui-ts/ts-animatorproperty.md)等特殊属性，可能与系统默认动画产生冲突。如果有业务需要设置这些属性，建议将这些属性设置在NavDestination的内容节点上，也可以达到相同效果。
