# 菜单概述

菜单是一种用于给用户提供可执行的操作的弹窗，一般用于鼠标右键弹窗、点击弹窗等。

## 使用场景

| 接口|使用场景  |
| ----------| ----------------------------------- |
| [菜单控制 (Menu)](arkts-popup-and-menu-components-menu.md) | 用于需要给指定的组件绑定用户可执行的操作时，例如长按图标展示操作选项等。 |
| [不依赖UI组件的全局菜单 (openMenu)](arkts-popup-and-menu-components-uicontext-menu.md) | 用于在无法直接访问UI组件的场景向用户提供可执行操作，例如在事件回调中展示操作选项等。 |

## 规格约束

* [bindMenu](../reference/apis-arkui/arkui-ts/ts-universal-attributes-menu.md#bindmenu11)通过调用isShow参数或[bindContextMenu](../reference/apis-arkui/arkui-ts/ts-universal-attributes-menu.md#bindcontextmenu12)调用isShown参数弹出时，需要等待页面全部构建完成才能展示。因此isShow或isShown不能在页面构建中设置为true，否则会导致menu弹窗显示位置及形状错误。
* openMenu的弹出需要传入有效的[TargetInfo](../reference/apis-arkui/arkts-apis-uicontext-i.md#targetinfo18)，否则无法弹出气泡。
* 其他规格约束，具体可参考[菜单控制](../reference/apis-arkui/arkui-ts/ts-universal-attributes-menu.md)、[openMenu](../reference/apis-arkui/arkts-apis-uicontext-promptaction.md#openmenu18)说明。

## 生命周期

正常时序依次为：aboutToAppear>>onWillAppear>>onAppear>>onDidAppear>>aboutToDisappear>>onWillDisappear>>onDisappear>>onDidDisappear。

| 名称| 类型 | 说明 |
| --- | --- | --- |
| aboutToAppear  | () =>  void | 菜单显示动效前的事件回调。 |
| onAppear | () =>  void | 菜单弹出后的事件回调。 |
| aboutToDisappear | () =>  void | 菜单退出动效前的事件回调。 |
| onDisappear  | () =>  void | 菜单消失后的事件回调。 |
| onWillAppear | [Callback&lt;void&gt;](../reference/apis-arkui/arkui-ts/ts-types.md#callback12) | 菜单显示动效前的事件回调。<br />**说明：** aboutToAppear是初始化时触发调用，onWillAppear是在动画执行前触发调用，onWillAppear在aboutToAppear之后执行。|
| onDidAppear | [Callback&lt;void&gt;](../reference/apis-arkui/arkui-ts/ts-types.md#callback12) |  菜单弹出后的事件回调。<br />**说明：**<br />1. 快速点击按钮时，菜单会快速弹出、消失，此时onWillDisappear可能会在onDidAppear前生效。<br />2. 当菜单入场动效未完成时关闭菜单，该回调不会触发。<br/>3. onAppear和onDidAppear触发时机相同，onDidAppear在onAppear后生效。|
| onWillDisappear | [Callback&lt;void&gt;](../reference/apis-arkui/arkui-ts/ts-types.md#callback12) | 菜单退出动效前的事件回调。<br />**说明：**<br />1. 快速点击按钮时，菜单会快速弹出、消失，此时onWillDisappear可能会在onDidAppear前生效。<br/>2. aboutToDisappear和onWillDisappear触发时机相同，onWillDisappear在aboutToDisappear后生效。|
| onDidDisappear | [Callback&lt;void&gt;](../reference/apis-arkui/arkui-ts/ts-types.md#callback12) | 菜单消失后的事件回调。<br />**说明：** onDisappear和onDidDisappear触发时机相同，onDidDisappear在onDisappear后生效。|
