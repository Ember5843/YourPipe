# UI装饰器总览

在声明式UI开发范式中，UI是程序状态的运行结果，状态的变化会驱动UI的刷新。ArkUI提供了一套装饰器机制，使开发者能够便捷地定义和管理状态变量，实现数据与UI的联动。

ArkUI包含的V2状态管理装饰器列表如下：

| V2状态管理装饰器                                    | 装饰器说明           |
| --------------------------------------------------- | -------------------- |
| @ComponentV2 | 创建自定义组件。       |
| [@Local](../v2/arkts-new-local.md)                     | 组件内部状态。       |
| [@Param](../v2/arkts-new-param.md)                     | 组件外部输入。       |
| [@Once](../v2/arkts-new-once.md)                       | 初始化同步一次。     |
| [@Event](../v2/arkts-new-event.md)                     | 规范组件输出。       |
| [@Provider](../v2/arkts-new-provider-and-consumer.md)  | 与后代状态双向同步。 |
| [@Consumer](../v2/arkts-new-provider-and-consumer.md)  | 与祖先状态双向同步。 |
| [@Monitor](../v2/arkts-new-monitor.md)                 | 状态变量修改异步监听。   |
| [@SyncMonitor](../v2/arkts-new-syncmonitor.md)                 | 状态变量修改同步监听。   |
| [@Computed](../v2/arkts-new-computed.md)               | 计算属性。           |
| [@ObservedV2](../v2/arkts-new-observedV2-and-trace.md) | 标记类可观察。       |
| [@Trace](../v2/arkts-new-observedV2-and-trace.md)      | 标记类属性可观察。   |
| [@Type](../v2/arkts-new-type.md)                       | 标记类属性的类型。   |
| [@ReusableV2](../v2/arkts-new-reusableV2.md)           | 标记组件可复用。     |

ArkUI包含的V1状态管理装饰器列表如下：

| V1状态管理装饰器                                             | 装饰器说明                                   |
| ------------------------------------------------------------ | -------------------------------------------- |
| @Component | 创建自定义组件。                             |
| [@State](../v1/arkts-state.md)                                  | 基础状态变量。                               |
| [@Prop](../v1/arkts-prop.md)                                    | 建立父子状态单向同步。                       |
| [@Link](../v1/arkts-link.md)                                    | 建立父子状态双向同步。                       |
| [@ObjectLink](../v1/arkts-observed-and-objectlink.md)           | 嵌套类对象属性变化观察。                     |
| [@Provide](../v1/arkts-provide-and-consume.md)                  | 与后代状态双向同步。                         |
| [@Consume](../v1/arkts-provide-and-consume.md)                  | 与祖先状态双向同步。                         |
| [@Watch](../v1/arkts-watch.md)                                  | 状态变量变化监听。                           |
| @StorageLink           | 与AppStorage中对应的属性建立双向数据同步。   |
| @StorageProp            | 与AppStorage中对应的属性建立单向数据同步。   |
| @LocalStorageLink | 与LocalStorage中对应的属性建立双向数据同步。 |
| @LocalStorageProp | 与LocalStorage中对应的属性建立单向数据同步。 |
| [@Observed](../v1/arkts-observed-and-objectlink.md)             | 标记类可观察。                               |
| [@Track](arkts-track.md)                                  | 类对象属性级更新。                           |
| [@Reusable](../v1/arkts-reusable.md)                            | 标记组件可复用。                             |

ArkUI包含的通用UI装饰器列表如下：

| 通用装饰器                                         | 装饰器说明          |
| -------------------------------------------------- | ------------------- |
| [@Builder](../../10-extension/builder/arkts-builder.md)                    | 自定义构建函数。    |
| [@LocalBuilder](../v1/arkts-localBuilder.md)          | 维持组件关系。      |
| [@BuilderParam](../../10-extension/builder/arkts-builderparam.md)          | 引用@Builder函数。 |
| [@Styles](../../11-theme-style/arkts-style.md)                       | 定义组件重用样式。  |
| [@Extend](../../11-theme-style/arkts-extend.md)                      | 定义扩展组件样式。  |
| [@AnimatableExtend](../v1/arkts-animatable-extend.md) | 定义可动画属性。    |
| [@Require](../v1/arkts-require.md)                    | 校验构造传参。      |
| [@Env](../../16-window/arkts-env-system-property.md)           | 环境变量。          |
