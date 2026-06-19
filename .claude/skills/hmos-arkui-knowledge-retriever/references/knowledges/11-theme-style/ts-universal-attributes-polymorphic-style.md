# 多态样式

设置组件不同状态下的样式。

>  **说明：**
>
>  从API version 8开始支持。后续版本如有新增内容，则采用上角标单独标记该内容的起始版本。
>
>  从API version 11开始支持另一种写法[attributeModifier](ts-universal-attributes-attribute-modifier.md)，可根据开发者需要动态设置属性。
>
>  多态样式仅支持通用属性。如果多态样式不生效，则该属性可能为组件的私有属性，例如：fontColor、[TextInput](../../04-components/basic/ts-basic-components-textinput.md)组件的[backgroundColor](./ts-universal-attributes-background.md#backgroundcolor18)等。此时，可以通过attributeModifier动态设置组件属性来解决此问题。
>
>  当前多态样式实现依赖于组件自定义节点的刷新机制。因Builder不具备独立的自定义父节点，无法直接触发刷新，致使多态样式无法直接在Builder中生效。解决方法是将多态样式封装至自定义组件内部，再将此组件置于@Builder中，以此来间接实现多态样式。示例代码可参考[示例3设置Builder多态样式](#示例3设置builder多态样式)。
>  
>  多态样式的焦点态只有在焦点激活态开启时生效。

## stateStyles

stateStyles(value: StateStyles): T

设置组件不同状态的样式。

> **说明：**
>
> 该接口不支持在[attributeModifier](ts-universal-attributes-attribute-modifier.md#attributemodifier)中调用。

**卡片能力：** 从API version 9开始，该接口支持在ArkTS卡片中使用。

**原子化服务API：** 从API version 11开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

**参数：**

| 参数名 | 类型                                | 必填 | 说明                     |
| ------ | ----------------------------------- | ---- | ------------------------ |
| value  | [StateStyles](#statestyles-1) | 是   | 设置组件不同状态的样式。 |

**返回值：**

| 类型 | 说明 |
| -------- | -------- |
| T | 返回当前组件。 |

## StateStyles

**原子化服务API：** 从API version 11开始，该接口支持在原子化服务中使用。

**系统能力：** SystemCapability.ArkUI.ArkUI.Full

| 名称 | 类型 | 只读 | 可选 | 说明 |
| -------- | -------- | -------- | -------- | -------- |
| normal | any | 否 | 是 | 组件无状态时的样式。只支持传入[@Styles](../../11-theme-style/arkts-style.md)修饰的样式代码块。<br/>**卡片能力：** 从API version 9开始，该接口支持在ArkTS卡片中使用。 |
| pressed | any | 否 | 是 | 组件按下状态的样式。只支持传入@Styles修饰的样式代码块。<br/>**卡片能力：** 从API version 9开始，该接口支持在ArkTS卡片中使用。 |
| disabled | any | 否 | 是 | 组件禁用状态的样式。只支持传入@Styles修饰的样式代码块。<br/>**卡片能力：** 从API version 9开始，该接口支持在ArkTS卡片中使用。 |
| focused | any | 否 | 是 | 组件获焦状态的样式。只支持传入@Styles修饰的样式代码块。<br/>**卡片能力：** 从API version 9开始，该接口支持在ArkTS卡片中使用。 |
| clicked | any | 否 | 是 | 组件点击状态的样式。只支持传入@Styles修饰的样式代码块。<br/>**卡片能力：** 从API version 9开始，该接口支持在ArkTS卡片中使用。 |
| selected<sup>10+</sup> | object | 否 | 是 | 组件选中状态的样式。只支持传入@style修饰的样式代码块。<br/>**卡片能力：** 从API version 10开始，该接口支持在ArkTS卡片中使用。 |

**selected选中状态说明**

- 当前多态样式的选中状态样式依赖组件选中属性值，可以使用[onClick](../event/ts-universal-events-click.md)修改属性值，或使用属性自带[$$](../../02-state-management/advanced/arkts-two-way-sync.md)双向绑定功能。

- 当前支持selected的组件及其参数/属性值：

  | 组件                                                         | 支持的参数/属性 | 起始API版本 |
  | ------------------------------------------------------------ | --------------- | ----------- |
  | [Checkbox](../../04-components/basic/ts-basic-components-checkbox.md) | select          | 10          |
  | [CheckboxGroup](../../04-components/basic/ts-basic-components-checkboxgroup.md) | selectAll       | 10          |
  | [Radio](../../04-components/basic/ts-basic-components-radio.md)  | checked         | 10          |
  | [Toggle](../../04-components/basic/ts-basic-components-toggle.md) | isOn            | 10          |
  | [ListItem](../../03-layout/grid-list/ts-container-listitem.md) | selected         | 10          |
  | GridItem | selected         | 10          |
  | [MenuItem](../../08-dialog-menu/menu/ts-basic-components-menuitem.md) | selected         | 10          |

**pressed和clicked状态说明**

- 当clicked和pressed同时在一个组件上使用时，只有后注册的状态才能生效。

## 示例

### 示例1（设置Text多态样式）

该示例展示了状态为pressed和disabled时Text组件的样式变化。

```ts
// xxx.ets
@Entry
@Component
struct StyleExample {
  @State isEnable: boolean = true

  @Styles
  pressedStyles(): void {
    .backgroundColor("#ED6F21")
    .borderRadius(10)
    .borderStyle(BorderStyle.Dashed)
    .borderWidth(2)
    .borderColor("#33000000")
    .width(120)
    .height(30)
    .opacity(1)
  }

  @Styles
  disabledStyles(): void {
    .backgroundColor("#E5E5E5")
    .borderRadius(10)
    .borderStyle(BorderStyle.Solid)
    .borderWidth(2)
    .borderColor("#2a4c1919")
    .width(90)
    .height(25)
    .opacity(1)
  }

  @Styles
  normalStyles(): void {
    .backgroundColor("#0A59F7")
    .borderRadius(10)
    .borderStyle(BorderStyle.Solid)
    .borderWidth(2)
    .borderColor("#33000000")
    .width(100)
    .height(25)
    .opacity(1)
  }

  build() {
    Flex({ direction: FlexDirection.Column, alignItems: ItemAlign.Center }) {
      Text("normal")
        .fontSize(14)
        .fontColor(Color.White)
        .opacity(0.5)
        .stateStyles({
          normal: this.normalStyles,
        })
        .margin({ bottom: 20 })
        .textAlign(TextAlign.Center)
      Text("pressed")
        .backgroundColor("#0A59F7")
        .borderRadius(20)
        .borderStyle(BorderStyle.Dotted)
        .borderWidth(2)
        .borderColor(Color.Red)
        .width(100)
        .height(25)
        .opacity(1)
        .fontSize(14)
        .fontColor(Color.White)
        .stateStyles({
          pressed: this.pressedStyles,
        })
        .margin({ bottom: 20 })
        .textAlign(TextAlign.Center)
      Text(this.isEnable == true ? "effective" : "disabled")
        .backgroundColor("#0A59F7")
        .borderRadius(20)
        .borderStyle(BorderStyle.Solid)
        .borderWidth(2)
        .borderColor(Color.Gray)
        .width(100)
        .height(25)
        .opacity(1)
        .fontSize(14)
        .fontColor(Color.White)
        .enabled(this.isEnable)
        .stateStyles({
          disabled: this.disabledStyles,
        })
        .textAlign(TextAlign.Center)
      Text("control disabled")
        .onClick(() => {
          this.isEnable = !this.isEnable
          console.info(`${this.isEnable}`)
        })
    }
    .width(350).height(300)
  }
}
```

### 示例2（设置Radio多态样式）

该示例展示了状态为selected时Radio组件的样式变化。

```ts
// xxx.ets
@Entry
@Component
struct Index {
  @State value: boolean = false
  @State value2: boolean = false

  @Styles
  normalStyles(): void{
    .backgroundColor("#E5E5E1")
  }

  @Styles
  selectStyles(): void{
    .backgroundColor("#ED6F21")
    .borderWidth(2)
  }

  build() {
    Flex({ direction: FlexDirection.Row, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center }) {
      Column() {
        Text('Radio1')
          .fontSize(25)
        Radio({ value: 'Radio1', group: 'radioGroup1' })
          .checked(this.value)
          .height(50)
          .width(50)
          .borderWidth(0)
          .borderRadius(30)
          .onClick(() => {
            this.value = !this.value
          })
          .stateStyles({
            normal: this.normalStyles,
            selected: this.selectStyles,
          })
      }
      .margin(30)

      Column() {
        Text('Radio2')
          .fontSize(25)
        Radio({ value: 'Radio2', group: 'radioGroup2' })
          .checked($$this.value2)
          .height(50)
          .width(50)
          .borderWidth(0)
          .borderRadius(30)
          .stateStyles({
            normal: this.normalStyles,
            selected: this.selectStyles,
          })
      }
      .margin(30)
    }.padding({ top: 30 })
  }
}
```

### 示例3（设置Builder多态样式）

该示例展示了状态为pressed时Builder组件的样式变化。

```ts
import { ComponentContent } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

@Component
struct Child {
  build() {
    Row()
      .zIndex(10)
      .width(200)
      .height(200)
      .stateStyles({
        normal: {
          .backgroundColor(Color.Blue)
        },
        pressed: {
          .backgroundColor(Color.Black)
        }
      })
  }
}

@Builder
function buildText() {
  Child()
}

@Entry
@Component
struct Index {
  private contentNode: ComponentContent<Object> =
    new ComponentContent(this.getUIContext(), wrapBuilder(buildText));

  build() {
    Column() {
      Button().margin({ top: 200 }).onClick((event: ClickEvent) => {
        this.getUIContext()
          .getPromptAction()
          .openCustomDialog(this.contentNode)
          .then(() => {
            console.info('OpenCustomDialog complete.')
          })
          .catch((error: BusinessError) => {
            let message = (error as BusinessError).message;
            let code = (error as BusinessError).code;
            console.error(`OpenCustomDialog args error code is ${code}, message is ${message}`);
          })
      })
    }
    .width('100%')
    .height('100%')
  }
}
```

