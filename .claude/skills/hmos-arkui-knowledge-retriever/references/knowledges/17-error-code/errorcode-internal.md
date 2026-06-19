# 接口调用异常错误码

> **说明：**
>
> 以下仅介绍本模块特有错误码，通用错误码请参考通用错误码。

## 100001 接口调用异常错误码

**错误信息**

作为@ohos.animator的错误码时，错误信息为：The specified page is not found or the object property list is not obtained.

作为@ohos.promptAction和[UIContext](../07-navigation/uicontext/arkts-apis-uicontext-uicontext.md)的错误码时，错误信息为：Internal error.

作为@ohos.router的错误码时，错误信息为：Internal error. UI execution context is not found.

作为[Navigation](../07-navigation/navigation/ts-basic-components-navigation.md)路由框架的错误码时，错误信息为：Internal error. Create NavDestination failed, probably caused by wrong UIContext.

作为@ohos.arkui.componentSnapshot的错误码时，错误信息为：The builder is not a valid build function.

**错误描述**

作为@ohos.animator和@ohos.promptAction的错误码时，出现了开发者解决不了的内部异常错误，会报此错误码，并描述具体是哪种内部错误。

作为@ohos.router的错误码时，该错误码为string类型。

作为[Navigation](../07-navigation/navigation/ts-basic-components-navigation.md)路由框架的错误码时，该错误码为number类型。

作为@ohos.arkui.componentSnapshot的错误码时，该错误码在内部状态出现异常时被触发。

作为[UIContext](../07-navigation/uicontext/arkts-apis-uicontext-uicontext.md)的错误时，出现了开发者解决不了的内部异常错误，系统会产生此错误码。

**可能原因**

作为@ohos.animator、@ohos.router和[Navigation](../07-navigation/navigation/ts-basic-components-navigation.md)路由框架的错误码时，可能原因为：未成功获取渲染引擎，解析参数失败等。

作为@ohos.promptAction的错误码时，可能原因为：未成功获取渲染引擎、解析参数失败或者UI上下文不明确等问题。

作为@ohos.arkui.componentSnapshot的错误码时，可能原因为：无法获取正确的UI实例、空指针异常、UI实例内部状态校验异常、组件未上树无法查询到节点、截图尺寸超过硬件限制（硬件限制可能根据不同硬件平台有所不同）等。

作为[UIContext](../07-navigation/uicontext/arkts-apis-uicontext-uicontext.md)的错误时，可能原因为：内存不足或JS虚拟机异常等因素可能导致UI实例创建失败。

**处理步骤**

针对UI上下文不明确问题，可以使用UIContext中的接口进行替换，详细说明可参考[使用UI上下文接口操作界面](../07-navigation/uicontext/arkts-global-interface.md)。

