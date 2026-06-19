# 设置事件回调

>**说明：**
>
>本模块首批接口从API version 12开始支持，后续版本的新增接口，采用上角标单独标记接口的起始版本。

## UICommonEvent
用于设置基础事件回调。方法入参为undefined的时候，重置对应的事件回调。
### setOnClick

setOnClick(callback: Callback\<ClickEvent> | undefined): void

设置[点击事件](../../17-api-reference/event/ts-universal-events-click.md)的回调。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名 | 类型   | 必填 | 说明                       |
| ------ | ------ | ---- | -------------------------- |
| callback  | Callback<[ClickEvent](./ts-universal-events-click.md#clickevent)> \| undefined | 是   | 点击事件的回调函数。 |

### setOnTouch

setOnTouch(callback: Callback\<TouchEvent> | undefined): void

设置[触摸事件](../../17-api-reference/event/ts-universal-events-touch.md)的回调。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名 | 类型   | 必填 | 说明                       |
| ------ | ------ | ---- | -------------------------- |
| callback  | Callback<[TouchEvent](./ts-universal-events-touch.md#touchevent对象说明)> \| undefined | 是   | 触摸事件的回调函数。 |

### setOnAppear

setOnAppear(callback: Callback\<void> | undefined): void

设置onAppear挂载显示事件的回调。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名 | 类型   | 必填 | 说明                       |
| ------ | ------ | ---- | -------------------------- |
| callback  | Callback\<void> \| undefined | 是   | 挂载显示事件的回调函数。 |

### setOnDisappear

setOnDisappear(callback: Callback\<void> | undefined): void

设置onDisAppear卸载消失事件的回调。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名 | 类型   | 必填 | 说明                       |
| ------ | ------ | ---- | -------------------------- |
| callback  | Callback\<void> \| undefined | 是   | 卸载消失事件的回调。 |

### setOnKeyEvent

setOnKeyEvent(callback: Callback\<KeyEvent> | undefined): void

设置[按键事件](../../17-api-reference/event/ts-universal-events-key.md)的回调。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名 | 类型   | 必填 | 说明                       |
| ------ | ------ | ---- | -------------------------- |
| callback  | Callback<[KeyEvent](./ts-universal-events-key.md#keyevent对象说明)>  \| undefined | 是   | 按键事件的回调函数。 |

### setOnFocus

setOnFocus(callback:  Callback\<void> | undefined): void

设置onFocus获焦事件的回调。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名 | 类型   | 必填 | 说明                       |
| ------ | ------ | ---- | -------------------------- |
| callback  | Callback\<void> \| undefined | 是   | 获焦事件的回调。 |

### setOnBlur

setOnBlur(callback: Callback\<void> | undefined): void

设置onBlur失焦事件的回调。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名 | 类型   | 必填 | 说明                       |
| ------ | ------ | ---- | -------------------------- |
| callback  | Callback\<void> \| undefined | 是   | 失焦事件的回调。 |

### setOnHover

setOnHover(callback: HoverCallback | undefined): void

设置[onHover](./ts-universal-events-hover.md#onhover)悬浮事件的回调。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名 | 类型   | 必填 | 说明                       |
| ------ | ------ | ---- | -------------------------- |
| callback  | [HoverCallback](#hovercallback)  \| undefined | 是   | 悬浮事件的回调函数。 |

### setOnMouse

setOnMouse(callback: Callback\<MouseEvent> | undefined): void

设置[onMouse](./ts-universal-mouse-key.md#onmouse)鼠标事件的回调。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名 | 类型   | 必填 | 说明                       |
| ------ | ------ | ---- | -------------------------- |
| callback  |  Callback<[MouseEvent](./ts-universal-mouse-key.md#mouseevent对象说明)>   \| undefined | 是   | 鼠标事件的回调函数。 |

### setOnSizeChange

setOnSizeChange(callback: SizeChangeCallback | undefined): void

设置onSizeChange组件区域变化事件的回调。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名 | 类型   | 必填 | 说明                       |
| ------ | ------ | ---- | -------------------------- |
| callback  | SizeChangeCallback   \| undefined | 是   | 组件区域变化事件的回调函数。 |

### setOnVisibleAreaApproximateChange

setOnVisibleAreaApproximateChange(options: VisibleAreaEventOptions, event: VisibleAreaChangeCallback | undefined): void

设置限制回调间隔的onVisibleAreaChange可见区域变化事件的回调。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名 | 类型   | 必填 | 说明                       |
| ------ | ------ | ---- | -------------------------- |
| options  | VisibleAreaEventOptions | 是   | 可见区域变化相关的参数。 |
| event  | VisibleAreaChangeCallback   \| undefined | 是   | 可见区域变化事件的回调函数。当组件可见面积与自身面积的比值接近options中设置的阈值时触发该回调。 |

>**说明：**
>
> 此接口与onVisibleAreaChange接口存在如下差异，onVisibleAreaChange在每一帧都会进行可见区域比例的计算，如果注册节点太多，系统功耗存在劣化。此接口降低了可见区域比例计算的频度，计算间隔由VisibleAreaEventOptions的expectedUpdateInterval参数决定。
>
> 当前接口的可见区域回调阈值默认包含0。例如，开发者设置回调阈值为[0.5]，实际生效的阈值为[0.0, 0.5]。

## HoverCallback

type HoverCallback = (isHover: boolean, event: HoverEvent)=> void

hover事件的回调类型。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名            | 类型            | 必填         | 说明                                       |
| ------------- | ---------------------- |---------------------| --------------------------------------- |
| isHover | boolean |  是  |是否处于hover状态，true表示处于hover状态，false表示不在hover状态。 |
| event | [HoverEvent](../../17-api-reference/event/ts-universal-events-hover.md#hoverevent10对象说明) |  是 |  获取鼠标或手写笔悬浮的位置坐标。 |