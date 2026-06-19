# 自定义组件参数

> **说明：**
> 
> 本模块首批接口从API version 11开始支持。后续版本的新增接口，采用上角标单独标记接口的起始版本。

## ComponentOptions

自定义组件参数，用于配置是否支持组件冻结。

**卡片能力：** 从API version 11开始，该接口支持在ArkTS卡片中使用。

**原子化服务API：** 从API version 12开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

> **说明：**
>
> 从API version 11开始，支持通过此参数配置@Component组件冻结。例子可见[自定义组件冻结](../02-state-management/advanced/arkts-custom-components-freeze.md)。
>
> 从API version 12开始，支持通过此参数配置@ComponentV2组件冻结。例子可见[自定义组件冻结](../02-state-management/advanced/arkts-custom-components-freezeV2.md)。
>

| 名称 | 类型 | 只读 | 可选     | 说明   |
| ------ | ---- | ---- | ------------ | ------------ |
|freezeWhenInactive|boolean| 否   | 否   |配置自定义组件支持组件冻结。true：开启组件冻结，false：不开启组件冻结。当开发者未指定ComponentOptions时，freezeWhenInactive将使用false作为默认值。|
