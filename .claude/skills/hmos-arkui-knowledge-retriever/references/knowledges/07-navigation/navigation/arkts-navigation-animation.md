# Navigation转场动画

[Navigation](../reference/apis-arkui/arkui-ts/ts-basic-components-navigation.md)存在默认转场动画，此外也提供了自定义转场和共享元素转场能力。

## 系统默认转场

系统提供了多种默认转场类型，可以通过[NavDestination.systemTransition](../reference/apis-arkui/arkui-ts/ts-basic-components-navdestination.md#systemtransition14)接口实现，具体示例请参考[设置指定的NavDestination系统转场](../reference/apis-arkui/arkui-ts/ts-basic-components-navdestination.md#示例3设置指定的navdestination系统转场)。

> **说明：**
>
> - NavDestination的默认转场动画使用[弹簧曲线](../../05-animation/curve/arkts-spring-curve.md)，其时长与物理曲线参数有关，而且不同设备上的默认动画不同，因此默认转场动画时长不可控，不建议与业务耦合，若需要监听动画结束，建议使用[自定义转场](#自定义转场)。
> - [Dialog](../reference/apis-arkui/arkui-ts/ts-basic-components-navdestination.md#navdestinationmode枚举说明11)类型的NavDestination默认无转场动画；从API version 13开始，Dialog类型的NavDestination默认存在系统转场动画。

默认转场动画支持关闭，有两种方式：

- 全局关闭。
  
  Navigation可以通过NavPathStack提供的[disableAnimation](../reference/apis-arkui/arkui-ts/ts-basic-components-navigation.md#disableanimation11)接口，关闭或打开当前Navigation的所有转场动画。

  
  ``` TypeScript
  pageStack: NavPathStack = new NavPathStack();
  
  aboutToAppear(): void {
    this.pageStack.disableAnimation(true);
  }
  ```

- 单次关闭。
  
  NavPathStack中提供的[pushPath](../reference/apis-arkui/arkui-ts/ts-basic-components-navigation.md#pushpath10)、[pop](../reference/apis-arkui/arkui-ts/ts-basic-components-navigation.md#pop10)、[replacePath](../reference/apis-arkui/arkui-ts/ts-basic-components-navigation.md#replacepath11)等接口可以设置animated参数，该参数用于设置是否有转场动画。需要单次关闭转场动画，可以将animated置为false，设置后不影响下次转场动画。

## 自定义转场

Navigation提供了两种自定义转场接口：Navigation自定义转场、NavDestination自定义转场。

- Navigation自定义转场动画由[customNavContentTransition](../reference/apis-arkui/arkui-ts/ts-basic-components-navigation.md#customnavcontenttransition11)事件提供，适用于控制Navigation内所有页面的场景，统一转场动画效果。步骤如下，具体示例代码请参考[设置可交互转场动画](../reference/apis-arkui/arkui-ts/ts-basic-components-navigation.md#示例3设置可交互转场动画)。

  1. 实现一个自定义转场动画工具类CustomNavigationUtils，通过一个Map管理各页面的自定义动画对象CustomTransition。页面在创建时注册其自定义转场动画对象，在销毁时取消注册。
  2. 实现一个转场协议对象[NavigationAnimatedTransition](../reference/apis-arkui/arkui-ts/ts-basic-components-navigation.md#navigationanimatedtransition11)。其中，transition属性为自定义转场动画的具体实现，开发者需在此实现自己的转场动画逻辑，系统在转场开始时会调用此方法。timeout属性表示转场结束的超时时间，默认为1000ms。onTransitionEnd为转场结束时的回调。
  3. 调用customNavContentTransition方法并返回实现的转场协议对象，若返回undefined，则使用系统默认转场。

- NavDestination支持自定义转场动画，适用于控制单个页面的转场效果。通过设置[customTransition](../reference/apis-arkui/arkui-ts/ts-basic-components-navdestination.md#customtransition15)属性即可实现单个页面的自定义转场效果。步骤如下，示例代码请参考[设置NavDestination自定义转场](../reference/apis-arkui/arkui-ts/ts-basic-components-navdestination.md#示例2设置navdestination自定义转场)。

  1. 实现[NavDestination的转场代理](../reference/apis-arkui/arkui-ts/ts-basic-components-navdestination.md#navdestinationtransitiondelegate15)，针对不同的堆栈操作类型返回自定义的转场协议对象[NavDestinationTransition](../reference/apis-arkui/arkui-ts/ts-basic-components-navdestination.md#navdestinationtransition15)。其中，event是必填参数，需在此处实现自定义转场动画的逻辑，onTransitionEnd、duration、curve与delay为可选参数，分别对应动画结束后的回调、动画持续时间、动画曲线类型与开始前的延时。如果在转场代理中返回多个转场协议对象，这些动画效果将逐层叠加。
  2. 通过调用NavDestination组件的customTransition属性，并传入上述实现的转场代理，完成自定义转场的设置。

> **说明：**
>
> 同时使用[customNavContentTransition](../reference/apis-arkui/arkui-ts/ts-basic-components-navigation.md#customnavcontenttransition11)和[customTransition](../reference/apis-arkui/arkui-ts/ts-basic-components-navdestination.md#customtransition15)时，customNavContentTransition优先级更高。

## 共享元素转场

NavDestination之间切换时可以通过[geometryTransition](../reference/apis-arkui/arkui-ts/ts-transition-animation-geometrytransition.md#geometrytransition)实现共享元素转场，示例如下。配置了共享元素转场的页面，同时需要关闭系统默认的转场动画，否则默认动画会与共享元素动画叠加，导致效果异常。

1. 为需要实现共享元素转场的组件添加geometryTransition属性，id参数必须在两个NavDestination之间保持一致。

   
   ``` TypeScript
   // 起始页配置共享元素id
   NavDestination() {
     Column() {
       // ...
       // 请将$r('app.media.startIcon')替换为实际资源文件
       Image($r('app.media.startIcon'))
         .geometryTransition('sharedId')
         .width(100)
         .height(100)
     }
   }.title('FromPage')
   ```

   
   ``` TypeScript
   // 目的页配置共享元素id
   NavDestination() {
     Column() {
       // 请将$r('app.media.startIcon')替换为实际资源文件
       Image($r('app.media.startIcon'))
         .geometryTransition('sharedId')
         .width(200)
         .height(200)
     }
   }
   .title('ToPage')
   ```

2. 将页面路由的操作，放到[animateTo](../reference/apis-arkui/arkts-apis-uicontext-uicontext.md#animateto)动画闭包中，配置对应的动画参数以及关闭系统默认的转场。

   
   ``` TypeScript
   NavDestination() {
     Column() {
       // $r('app.string.ToPage')需要开发者替换为实际的资源文件，资源文件中的value值为“跳转到目的页”

       Button($r('app.string.ToPage'))
         .width('80%')
         .height(40)
         .margin(20)
         .onClick(() => {
           this.getUIContext()?.animateTo({ duration: 1000 }, () => {
             this.navPathStack.pushPath({ name: 'ToPage' }, false)
           });
         })
       // ...
     }
   }.title('FromPage')
   ```
