# 内置对象的迁移

本文档主要介绍组件内置对象从V1向V2的迁移，涉及如下装饰器。

| V1装饰器名称/场景 | V2装饰器名称 |
| -------- | -------- |
| 滚动组件场景 | [makeObserved](../v2/arkts-new-makeObserved.md) |
| [Modifier](../../10-extension/custom-component/arkts-user-defined-modifier.md) | [makeObserved](../v2/arkts-new-makeObserved.md)、[@ObservedV2](../v2/arkts-new-observedV2-and-trace.md)、[@Trace](../v2/arkts-new-observedV2-and-trace.md) |

## 滚动组件

### List

开发者可以通过[ChildrenMainSize](../../reference/apis-arkui/arkui-ts/ts-container-list.md#childrenmainsize12)来设置[List](../../reference/apis-arkui/arkui-ts/ts-container-list.md)的子组件在主轴方向的大小信息。

V1：

在状态管理V1中，可以通过[@State](../v1/arkts-state.md)装饰观察其api调用。

具体示例如下：

``` TypeScript
@Entry
@Component
struct ListExample {
  private arr: Array<number> = new Array(10).fill(0);
  private scroller: ListScroller = new ListScroller();
  @State listSpace: number = 10;
  @State listChildrenSize: ChildrenMainSize = new ChildrenMainSize(100);

  build() {
    Column() {
      Button('change Default').onClick(() => {
        this.listChildrenSize.childDefaultSize += 10;
      })

      Button('splice 5').onClick(() => {
        this.listChildrenSize.splice(0, 5, [100, 100, 100, 100, 100]);
      })

      Button('update 5').onClick(() => {
        this.listChildrenSize.update(0, 200);
      })

      List({ space: this.listSpace, scroller: this.scroller }) {
        ForEach(this.arr, (item: number) => {
          ListItem() {
            Text(`item-` + item)
          }.backgroundColor(Color.Pink)
        })
      }
      .childrenMainSize(this.listChildrenSize) // 10
    }
  }
}
```

V2：

在状态管理V2中，[@Local](../v2/arkts-new-local.md)只能观察本身的变化，无法观察第一层的变化，而由于ChildrenMainSize定义在List组件框架中，开发者无法使用[@Trace](../v2/arkts-new-observedV2-and-trace.md)来标注ChildrenMainSize属性。可以使用[makeObserved](../v2/arkts-new-makeObserved.md)替代。从API version 22开始，可以无需使用makeObserved，直接使用@Local标注的ChildrenMainSize设置List的子组件在主轴方向的大小信息。

具体示例如下：

``` TypeScript
import { UIUtils } from '@kit.ArkUI';

@Entry
@ComponentV2
struct ListExample {
  private arr: Array<number> = new Array(10).fill(0);
  private scroller: ListScroller = new ListScroller();
  listSpace: number = 10;
  // 使用makeObserved的能力来观测ChildrenMainSize
  listChildrenSize: ChildrenMainSize = UIUtils.makeObserved(new ChildrenMainSize(100));

  build() {
    Column() {
      Button('change Default').onClick(() => {
        this.listChildrenSize.childDefaultSize += 10;
      })

      Button('splice 5').onClick(() => {
        this.listChildrenSize.splice(0, 5, [100, 100, 100, 100, 100]);
      })

      Button('update 5').onClick(() => {
        this.listChildrenSize.update(0, 200);
      })

      List({ space: this.listSpace, scroller: this.scroller }) {
        ForEach(this.arr, (item: number) => {
          ListItem() {
            Text(`item-` + item)
          }.backgroundColor(Color.Pink)
        })
      }
      .childrenMainSize(this.listChildrenSize) // 10
    }
  }
}
```

### WaterFlow

开发者可以通过[WaterFlowSections](../../reference/apis-arkui/arkui-ts/ts-container-waterflow.md#waterflowsections12)来设置WaterFlow瀑布流分组信息。

需要注意的是，数组arr的长度需要与WaterFlowSections的所有SectionOptions的itemsCount总和一致，否则WaterFlow无法处理，导致UI不刷新。

以下两个示例请按照`push option` -> `splice option` -> `update option`的顺序进行点击。

V1：

在状态管理V1中，可以通过[@State](../v1/arkts-state.md)装饰观察其api调用。

具体示例如下：

``` TypeScript
@Entry
@Component
struct WaterFlowSample {
  @State colors: Color[] = [Color.Red, Color.Orange, Color.Yellow, Color.Green, Color.Blue, Color.Pink];
  @State sections: WaterFlowSections = new WaterFlowSections();
  scroller: Scroller = new Scroller();
  @State private arr: Array<number> = new Array(9).fill(0);
  oneColumnSection: SectionOptions = {
    itemsCount: 4,
    crossCount: 1,
    columnsGap: '5vp',
    rowsGap: 10,
  };
  twoColumnSection: SectionOptions = {
    itemsCount: 2,
    crossCount: 2,
  };
  lastSection: SectionOptions = {
    itemsCount: 3,
    crossCount: 3,
  };

  aboutToAppear(): void {
    let sectionOptions: SectionOptions[] = [this.oneColumnSection, this.twoColumnSection, this.lastSection];
    this.sections.splice(0, 0, sectionOptions);
  }

  build() {
    Column() {
      Text(`${this.arr.length}`)

      Button('push option').onClick(() => {
        let section: SectionOptions = {
          itemsCount: 1,
          crossCount: 1,
        };
        this.sections.push(section);
        this.arr.push(100);
      })

      Button('splice option').onClick(() => {
        let section: SectionOptions = {
          itemsCount: 8,
          crossCount: 2,
        };
        this.sections.splice(0, this.arr.length, [section]);
        this.arr = new Array(8).fill(10);
      })

      Button('update option').onClick(() => {
        let section: SectionOptions = {
          itemsCount: 8,
          crossCount: 2,
        };
        this.sections.update(1, section);
        this.arr = new Array(16).fill(1);
      })

      WaterFlow({ scroller: this.scroller, sections: this.sections }) {
        ForEach(this.arr, (item: number) => {
          FlowItem() {
            Text(`${item}`)
              .border({ width: 1 })
              .backgroundColor(this.colors[item % 6])
              .height(30)
              .width(50)
          }
        })
      }
    }
  }
}
```

V2：

在状态管理V2中，[@Local](../v2/arkts-new-local.md)只能观察本身的变化，无法观察第一层的变化，由于WaterFlowSections定义在框架中，开发者无法使用[@Trace](../v2/arkts-new-observedV2-and-trace.md)标注其属性，此时可以使用[makeObserved](../v2/arkts-new-makeObserved.md)替代。

具体示例如下：

``` TypeScript
import { UIUtils } from '@kit.ArkUI';

@Entry
@ComponentV2
struct WaterFlowSample {
  colors: Color[] = [Color.Red, Color.Orange, Color.Yellow, Color.Green, Color.Blue, Color.Pink];
  // 使用makeObserved的能力来观测WaterFlowSections
  sections: WaterFlowSections = UIUtils.makeObserved(new WaterFlowSections());
  scroller: Scroller = new Scroller();
  @Local private arr: Array<number> = new Array(9).fill(0);
  oneColumnSection: SectionOptions = {
    itemsCount: 4,
    crossCount: 1,
    columnsGap: '5vp',
    rowsGap: 10,
  };
  twoColumnSection: SectionOptions = {
    itemsCount: 2,
    crossCount: 2,
  };
  lastSection: SectionOptions = {
    itemsCount: 3,
    crossCount: 3,
  };

  aboutToAppear(): void {
    let sectionOptions: SectionOptions[] = [this.oneColumnSection, this.twoColumnSection, this.lastSection];
    this.sections.splice(0, 0, sectionOptions);
  }

  build() {
    Column() {
      Text(`${this.arr.length}`)

      Button('push option').onClick(() => {
        let section: SectionOptions = {
          itemsCount: 1,
          crossCount: 1,
        };
        this.sections.push(section);
        this.arr.push(100);
      })

      Button('splice option').onClick(() => {
        let section: SectionOptions = {
          itemsCount: 8,
          crossCount: 2,
        };
        this.sections.splice(0, this.arr.length, [section]);
        this.arr = new Array(8).fill(10);
      })

      Button('update option').onClick(() => {
        let section: SectionOptions = {
          itemsCount: 8,
          crossCount: 2,
        };
        this.sections.update(1, section);
        this.arr = new Array(16).fill(1);
      })

      WaterFlow({ scroller: this.scroller, sections: this.sections }) {
        ForEach(this.arr, (item: number) => {
          FlowItem() {
            Text(`${item}`)
              .border({ width: 1 })
              .backgroundColor(this.colors[item % 6])
              .height(30)
              .width(50)
          }
        })
      }
    }
  }
}
```

## Modifier

### attributeModifier

开发者可以通过[attributeModifier](../../reference/apis-arkui/arkui-ts/ts-universal-attributes-attribute-modifier.md#attributemodifier)动态设置组件的属性方法。

V1：

在状态管理V1中，可以通过[@State](../v1/arkts-state.md)装饰观察其变化。

具体示例如下：

``` TypeScript
class MyButtonModifier implements AttributeModifier<ButtonAttribute> {
  public isDark: boolean = false;

  applyNormalAttribute(instance: ButtonAttribute): void {
    if (this.isDark) {
      instance.backgroundColor(Color.Black);
    } else {
      instance.backgroundColor(Color.Red);
    }
  }
}

@Entry
@Component
struct AttributeDemo {
  @State modifier: MyButtonModifier = new MyButtonModifier();

  build() {
    Row() {
      Column() {
        Button('Button')
          .attributeModifier(this.modifier)
          .onClick(() => {
            this.modifier.isDark = !this.modifier.isDark;
          })
      }
      .width('100%')
    }
    .height('100%')
  }
}
```

V2：

在状态管理V2中，[@Local](../v2/arkts-new-local.md)只能观察本身的变化，无法观察第一层的变化，如果要观察attributeModifier的属性变化，可以使用[makeObserved](../v2/arkts-new-makeObserved.md)替代。

具体示例如下：

``` TypeScript
import { UIUtils } from '@kit.ArkUI';

class MyButtonModifier implements AttributeModifier<ButtonAttribute> {
  public isDark: boolean = false;

  applyNormalAttribute(instance: ButtonAttribute): void {
    if (this.isDark) {
      instance.backgroundColor(Color.Black);
    } else {
      instance.backgroundColor(Color.Red);
    }
  }
}

@Entry
@ComponentV2
struct AttributeDemo {
  // 使用makeObserved的能力观测attributeModifier的属性this.modifier
  modifier: MyButtonModifier = UIUtils.makeObserved(new MyButtonModifier());

  build() {
    Row() {
      Column() {
        Button('Button')
          .attributeModifier(this.modifier)
          .onClick(() => {
            this.modifier.isDark = !this.modifier.isDark;
          })
      }
      .width('100%')
    }
    .height('100%')
  }
}
```

### CommonModifier

动态设置组件的属性类。以[CommonModifier](../../reference/apis-arkui/arkui-ts/ts-universal-attributes-attribute-modifier.md#自定义modifier)为例。

V1：

在状态管理V1中，可以通过[@State](../v1/arkts-state.md)装饰观察其变化。

具体实例如下：

``` TypeScript
import { CommonModifier } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;

class MyModifier extends CommonModifier {
  applyNormalAttribute(instance: CommonAttribute): void {
    super.applyNormalAttribute?.(instance);
  }

  public setGroup1(): void {
    this.borderStyle(BorderStyle.Dotted);
    this.borderWidth(8);
  }

  public setGroup2(): void {
    this.borderStyle(BorderStyle.Dashed);
    this.borderWidth(8);
  }
}

@Component
struct MyImage1 {
  @Link modifier: CommonModifier;

  build() {
    // 此处'app.media.app_icon'仅作示例，请开发者自行替换，否则imageSource创建失败会导致后续无法正常执行。
    Image($r('app.media.app_icon'))
      .attributeModifier(this.modifier as MyModifier)
  }
}

@Entry
@Component
struct Index {
  @State myModifier: CommonModifier = new MyModifier().width(100).height(100).margin(10);
  index: number = 0;

  build() {
    Column() {
      Button($r('app.string.EntryAbility_label'))
        .margin(10)
        .onClick(() => {
          hilog.info(DOMAIN, 'testTag', 'Modifier', 'onClick');
          this.index++;
          if (this.index % 2 === 1) {
            (this.myModifier as MyModifier).setGroup1();
            hilog.info(DOMAIN, 'testTag', 'Modifier', 'setGroup1');
          } else {
            (this.myModifier as MyModifier).setGroup2();
            hilog.info(DOMAIN, 'testTag', 'Modifier', 'setGroup2');
          }
        })

      MyImage1({ modifier: this.myModifier })
    }
    .width('100%')
  }
}
```

V2：

在状态管理V2中，[@Local](../v2/arkts-new-local.md)只能观察本身的变化，无法观察第一层的变化，又因为[CommonModifier](../../reference/apis-arkui/arkui-ts/ts-universal-attributes-attribute-modifier.md#自定义modifier)在框架内是通过其属性触发刷新，此时可以使用[makeObserved](../v2/arkts-new-makeObserved.md)替代。

具体示例如下：

``` TypeScript
import { UIUtils, CommonModifier } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;

class MyModifier extends CommonModifier {
  applyNormalAttribute(instance: CommonAttribute): void {
    super.applyNormalAttribute?.(instance);
  }

  public setGroup1(): void {
    this.borderStyle(BorderStyle.Dotted);
    this.borderWidth(8);
  }

  public setGroup2(): void {
    this.borderStyle(BorderStyle.Dashed);
    this.borderWidth(8);
  }
}

@ComponentV2
struct MyImage1 {
  @Param @Require modifier: CommonModifier;

  build() {
    // 此处'app.media.app_icon'仅作示例，请开发者自行替换，否则imageSource创建失败会导致后续无法正常执行。
    Image($r('app.media.app_icon'))
      .attributeModifier(this.modifier as MyModifier)
  }
}

@Entry
@ComponentV2
struct Index {
  // 使用makeObserved的能力来观测CommonModifier
  @Local myModifier: CommonModifier = UIUtils.makeObserved(new MyModifier().width(100).height(100).margin(10));
  index: number = 0;

  build() {
    Column() {
      Button($r('app.string.EntryAbility_label'))
        .margin(10)
        .onClick(() => {
          hilog.info(DOMAIN, 'testTag', 'Modifier', 'onClick');
          this.index++;
          if (this.index % 2 === 1) {
            (this.myModifier as MyModifier).setGroup1();
            hilog.info(DOMAIN, 'testTag', 'Modifier', 'setGroup1');
          } else {
            (this.myModifier as MyModifier).setGroup2();
            hilog.info(DOMAIN, 'testTag', 'Modifier', 'setGroup2');
          }
        })

      MyImage1({ modifier: this.myModifier })
    }
    .width('100%')
  }
}
```

### 组件Modifier

动态设置组件的属性类。以Text组件为例。

V1：

在状态管理V1中，可以通过[@State](../v1/arkts-state.md)装饰观察其变化。

具体示例如下：

``` TypeScript
import { TextModifier } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;

class MyModifier extends TextModifier {
  applyNormalAttribute(instance: TextModifier): void {
    super.applyNormalAttribute?.(instance);
  }

  public setGroup1(): void {
    this.fontSize(50);
    this.fontColor(Color.Pink);
  }

  public setGroup2(): void {
    this.fontSize(50);
    this.fontColor(Color.Gray);
  }
}

@Component
struct MyImage1 {
  @Link modifier: TextModifier;
  index: number = 0;

  build() {
    Column() {
      Text('Test')
        .attributeModifier(this.modifier as MyModifier)

      Button($r('app.string.EntryAbility_label'))
        .margin(10)
        .onClick(() => {
          hilog.info(DOMAIN, 'testTag', 'Modifier', 'onClick');
          this.index++;
          if (this.index % 2 === 1) {
            (this.modifier as MyModifier).setGroup1();
            hilog.info(DOMAIN, 'testTag', 'Modifier', 'setGroup1');
          } else {
            (this.modifier as MyModifier).setGroup2();
            hilog.info(DOMAIN, 'testTag', 'Modifier', 'setGroup2');
          }
        })
    }
  }
}

@Entry
@Component
struct Index {
  @State myModifier: TextModifier = new MyModifier().width(100).height(100).margin(10);
  index: number = 0;

  build() {
    Column() {
      MyImage1({ modifier: this.myModifier })

      Button('replace whole')
        .margin(10)
        .onClick(() => {
          this.myModifier = new MyModifier().backgroundColor(Color.Orange);
        })
    }
    .width('100%')
  }
}
```

V2：

但在状态管理V2中，[@Local](../v2/arkts-new-local.md)只能观察本身的变化，无法观察第一层的变化，此时可以使用[makeObserved](../v2/arkts-new-makeObserved.md)替代。

具体示例如下：

``` TypeScript
import { UIUtils, TextModifier } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;

class MyModifier extends TextModifier {
  applyNormalAttribute(instance: TextModifier): void {
    super.applyNormalAttribute?.(instance);
  }

  public setGroup1(): void {
    this.fontSize(50);
    this.fontColor(Color.Pink);
  }

  public setGroup2(): void {
    this.fontSize(50);
    this.fontColor(Color.Gray);
  }
}

@ComponentV2
struct MyImage1 {
  @Param @Require modifier: TextModifier;
  index: number = 0;

  build() {
    Column() {
      Text('Test')
        .attributeModifier(this.modifier as MyModifier)

      Button($r('app.string.EntryAbility_label'))
        .margin(10)
        .onClick(() => {
          hilog.info(DOMAIN, 'testTag', 'Modifier', 'onClick');
          this.index++;
          if (this.index % 2 === 1) {
            (this.modifier as MyModifier).setGroup1();
            hilog.info(DOMAIN, 'testTag', 'Modifier', 'setGroup1');
          } else {
            (this.modifier as MyModifier).setGroup2();
            hilog.info(DOMAIN, 'testTag', 'Modifier', 'setGroup2');
          }
        })
    }
  }
}

@Entry
@ComponentV2
struct Index {
  // 使用makeObserved的能力观测TextModifier
  @Local myModifier: TextModifier = UIUtils.makeObserved(new MyModifier().width(100).height(100).margin(10));
  index: number = 0;

  build() {
    Column() {
      MyImage1({ modifier: this.myModifier })

      Button('replace whole')
        .margin(10)
        .onClick(() => {
          this.myModifier = UIUtils.makeObserved(new MyModifier().backgroundColor(Color.Orange));
        })
    }
    .width('100%')
  }
}
```

### AttributeUpdater

[AttributeUpdater](../../10-extension/modifier/arkts-user-defined-extension-attributeUpdater.md)可以将属性直接设置给组件，无需标记为状态变量即可直接触发UI更新。

V1：

在状态管理V1中，开发者希望通过修改MyButtonModifier的flag来改变绑定在Button上的属性。由于状态管理V1的@State装饰器支持自身及第一层对象属性的观察能力，因此只需用@State装饰AttributeUpdater，即可监听其变化并触发属性更新。

``` TypeScript
// xxx.ets
import { AttributeUpdater } from '@kit.ArkUI';

class MyButtonModifier extends AttributeUpdater<ButtonAttribute> {
  public flag: boolean = false;

  initializeModifier(instance: ButtonAttribute): void {
    instance.backgroundColor('#ff2787d9')
      .width('50%')
      .height(30)
  }

  applyNormalAttribute(instance: ButtonAttribute): void {
    if (this.flag) {
      instance.borderWidth(2);
    } else {
      instance.borderWidth(10);
    }
  }
}

@Entry
@Component
struct Index {
  @State modifier: MyButtonModifier = new MyButtonModifier();

  build() {
    Row() {
      Column() {
        Button('Button')
          .attributeModifier(this.modifier)
        Button('Update')
          .onClick(() => {
            this.modifier.flag = !this.modifier.flag;
          })
      }
      .width('100%')
    }
    .height('100%')
  }
}
```

V2：

与状态管理V1不同，状态管理V2的@Local仅观察自身变化，因此MyButtonModifier需添加@ObservedV2装饰器，flag需要被@Trace装饰，并且需要在组件创建过程中读取flag以建立其与Button组件的联系。在AttributeUpdater场景中，需在initializeModifier中读取flag（如示例所示），否则无法建立关联。

``` TypeScript
// xxx.ets
import { AttributeUpdater } from '@kit.ArkUI';

@ObservedV2
class MyButtonModifier extends AttributeUpdater<ButtonAttribute> {
  @Trace public flag: boolean = false;

  initializeModifier(instance: ButtonAttribute): void {
    // initializeModifier会在组件初始化阶段回调，需要在这个地方触发下flag的读，使其建立Button组件的关联。
    this.flag;
    instance.backgroundColor('#ff2787d9')
      .width('50%')
      .height(30)
  }

  applyNormalAttribute(instance: ButtonAttribute): void {
    if (this.flag) {
      instance.borderWidth(2);
    } else {
      instance.borderWidth(10);
    }
  }
}

@Entry
@ComponentV2
struct Index {
  // 状态管理V2装饰器仅观察本层，即当前可以观察到modifier整体赋值的变化。
  @Local modifier: MyButtonModifier = new MyButtonModifier();

  build() {
    Row() {
      Column() {
        Button('Button')
          .attributeModifier(this.modifier)
        Button('Update')
          .onClick(() => {
            this.modifier.flag = !this.modifier.flag;
          })
      }
      .width('100%')
    }
    .height('100%')
  }
}
```
