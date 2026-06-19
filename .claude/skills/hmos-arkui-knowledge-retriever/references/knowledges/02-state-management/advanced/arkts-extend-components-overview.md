# 组件扩展概述

ArkUI使用@Builder装饰器为开发者提供代码精简方案。该装饰器通过模块化封装简化UI开发流程，并衍生出@BuilderParam、@LocalBuilder装饰器和wrapBuilder机制，构成可复用的UI结构体系。

> **说明：**
>
> @Builder装饰器是@BuilderParam装饰器、@LocalBuilder装饰器和wrapBuilder机制的基石。

## @Builder装饰器

[@Builder装饰器](../../10-extension/builder/arkts-builder.md)专为构建模块化、可复用的UI结构而设计，其内部禁止定义状态变量和调用组件生命周期方法，仅支持通过参数与调用方进行数据交互。

## @LocalBuilder装饰器

在使用@Builder实现组件间数据传递时，开发者需注意组件层级关系。组件树中的父子关系可能与状态管理的父子关系产生不一致。为此，框架提供了[@LocalBuilder装饰器](../v1/arkts-localBuilder.md)来解决这一特定问题。

## @BuilderParam装饰器

当多个场景共用同一个@Builder函数时，若需要为特定场景扩展功能（类似slot占位符机制），可通过[@BuilderParam装饰器](../../10-extension/builder/arkts-builderparam.md)实现，该装饰器专门用于接收并封装@Builder函数。

## wrapBuilder机制

当页面中存在多个不同UI结构的全局@Builder函数时，维护成本较高。框架提供了[wrapBuilder](../v1/arkts-wrapBuilder.md)机制来简化代码维护工作。

## mutableBuilder机制

当前[wrapBuilder](../v1/arkts-wrapBuilder.md)不支持二次赋值， 即动态切换@Builder, UI不会发生变化。框架提供[mutableBuilder](../v1/arkts-mutableBuilder.md)用于支持@Builder动态切换。

## @Styles装饰器

[@Styles](../../11-theme-style/arkts-style.md)用于定义组件重用样式，可将多条通用样式设置提炼成一个方法，直接在组件声明的位置调用。通过@Styles装饰器可以快速定义并复用自定义样式。

## @Extend装饰器

[@Extend](../../11-theme-style/arkts-extend.md)用于定义组件重用样式，可将指定组件的私有属性、私有事件设置提炼成一个方法，直接在组件声明的位置调用。通过@Extend装饰器可以快速定义并复用指定组件的自定义样式。

## stateStyles机制

[stateStyles](../../11-theme-style/arkts-statestyles.md)可以依据组件的内部状态的不同，快速设置不同样式。

## @AnimatableExtend装饰器

[@AnimatableExtend](../v1/arkts-animatable-extend.md)装饰器用于自定义可动画的属性方法，在这个属性方法中修改组件不可动画的属性。在动画执行过程中，通过逐帧回调函数修改不可动画属性值，让不可动画属性也能实现动画效果。也可通过逐帧回调函数修改可动画属性的值，实现逐帧布局的效果。