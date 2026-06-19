# wrapBuilder：封装全局@Builder

  当在一个struct内使用多个全局@Builder函数实现UI的不同效果时，代码维护将变得非常困难，且页面不够整洁。此时，可以使用[wrapBuilder](../../reference/apis-arkui/arkui-ts/ts-universal-wrapBuilder.md)封装全局@Builder。

  在阅读本文档前，建议阅读：[@Builder](../../10-extension/builder/arkts-builder.md)。

> **说明：**
>
> 从API version 11开始支持。
>
> 从API version 12开始，wrapBuilder支持在原子化服务中使用。
>
> 从API version 22开始，推荐开发者使用[mutableBuilder](arkts-mutableBuilder.md)，支持二次赋值后刷新UI。

当@Builder方法赋值给变量或者数组后，在UI方法中无法使用。

```ts
@Builder
function builderElement() {}

let builderArr: Function[] = [builderElement];
@Builder
function testBuilder() {
  ForEach(builderArr, (item: Function) => {
    item();
  })
}
```

在上述代码中，`builderArr`是一个由@Builder方法组成的数组。在ForEach循环中取每个@Builder方法时，会出现@Builder方法在UI方法中无法使用的问题。

为了解决这一问题，引入wrapBuilder作为全局@Builder封装函数。wrapBuilder返回WrappedBuilder对象，用于[全局@Builder](../../10-extension/builder/arkts-builder.md#全局自定义构建函数)的赋值和传递。 

## 接口说明

wrapBuilder是一个模板函数，返回一个WrappedBuilder对象。

```ts
declare function wrapBuilder<Args extends Object[]>(builder: (...args: Args) => void): WrappedBuilder<Args>;
```

同时 `WrappedBuilder`对象也是一个模板类。

```ts
declare class WrappedBuilder<Args extends Object[]> {
  builder: (...args: Args) => void;

  constructor(builder: (...args: Args) => void);
}
```

> **说明：**
>
> 模板参数`Args extends Object[]`需要匹配@Builder函数参数的类型。

使用方法：

```ts
let builderVar: WrappedBuilder<[string, number]> = wrapBuilder(MyBuilder);
let builderArr: WrappedBuilder<[string, number]>[] = [wrapBuilder(MyBuilder)]; // 可以放入数组
```

## 限制条件

1. wrapBuilder方法只能传入[全局@Builder](../../10-extension/builder/arkts-builder.md#全局自定义构建函数)方法。

2. WrappedBuilder对象的builder属性方法仅限在struct内部使用。

## @Builder方法赋值给变量

使用@Builder装饰器装饰的方法`myBuilder`作为wrapBuilder的参数，然后将wrapBuilder的返回值赋值给变量`globalBuilder`，以解决@Builder方法赋值给变量后无法使用的问题。

 
 ``` TypeScript
 @Builder
 function myBuilder(value: string, size: number) {
   Text(value)
     .fontSize(size)
 }
 
 let globalBuilder: WrappedBuilder<[string, number]> = wrapBuilder(myBuilder);
 
 @Entry
 @Component
 struct TestIndex {
   @State message: string = 'Hello World';
 
   build() {
     Row() {
       Column() {
         globalBuilder.builder(this.message, 50)
       }
       .width('100%')
     }
     .height('100%')
   }
 }
 ```

## @Builder方法赋值给变量在UI语法中使用

自定义组件`IndexItem`使用ForEach进行不同@Builder函数的渲染，可以使用`builderArr`声明的wrapBuilder数组来实现不同的@Builder函数的效果。整体代码会更加整洁。

``` TypeScript
@Builder
function myBuilder0(value: string, size: number) {
  Text(value)
    .fontSize(size)
    .fontColor(Color.Blue)
}

@Builder
function yourBuilder(value: string, size: number) {
  Text(value)
    .fontSize(size)
    .fontColor(Color.Pink)
}

const builderArr: WrappedBuilder<[string, number]>[] = [wrapBuilder(myBuilder0), wrapBuilder(yourBuilder)];

@Entry
@Component
struct IndexItem {
  @Builder
  IndexItem() {
    ForEach(builderArr, (item: WrappedBuilder<[string, number]>) => {
      item.builder('Hello World', 30);
    })
  }

  build() {
    Row() {
      Column() {
        this.IndexItem();
      }
      .width('100%')
    }
    .height('100%')
  }
}
```

## @Builder方法赋值给类或者接口的属性

使用@Builder装饰器装饰的方法`MyBuilder`作为wrapBuilder的参数，然后将wrapBuilder的返回值赋值给接口`ChildOptions`中的属性，可以以数据的形式传递给其他子组件调用。

```ts
@Builder
function MyBuilder(value: string, size: number) {
  Text(value)
    .fontSize(size)
}

interface ChildOptions {
  wrappedBuilder: WrappedBuilder<[string, number]>; // 类型为WrappedBuilder的属性可以传递@Builder函数
}

@Entry
@Component
struct Index {
  childOptions: ChildOptions = {
    wrappedBuilder: wrapBuilder(MyBuilder)
  };

  build() {
    Row() {
      Column() {
        Child({ options: this.childOptions })
      }
      .width('100%')
    }
    .height('100%')
  }
}

@Component
struct Child {
  @Prop options: ChildOptions;
  build() {
    this.options.wrappedBuilder.builder('Hello', 20);
  }
}
```

## 引用传递

按引用传递参数时，状态变量的改变会引起@Builder方法内的UI刷新。

``` TypeScript
class Tmp {
  public paramA2: string = 'hello';
}

@Builder
function overBuilder(param: Tmp) {
  Column() {
    Text(`wrapBuildervalue:${param.paramA2}`)
  }
}

const wBuilder: WrappedBuilder<[Tmp]> = wrapBuilder(overBuilder);

@Entry
@Component
struct Parent {
  @State label: Tmp = new Tmp();

  build() {
    Column() {
      wBuilder.builder({ paramA2: this.label.paramA2 })
      Button('Click me').onClick(() => {
        this.label.paramA2 = 'ArkUI';
      })
    }
  }
}
```

## 常见问题

### 重复定义wrapBuilder失效

在同一个自定义组件内，同一个wrapBuilder只能初始化一次。例如，`builderObj`通过`wrapBuilder(MyBuilderFirst)`初始化后，再次对`builderObj`赋值`wrapBuilder(MyBuilderSecond)`将不会生效。

``` TypeScript
@Builder
function myBuilderFirst(value: string, size: number) {
  Text('MyBuilderFirst：' + value)
    .fontSize(size)
}

@Builder
function myBuilderSecond(value: string, size: number) {
  Text('MyBuilderSecond：' + value)
    .fontSize(size)
}

interface BuilderModel {
  globalBuilder: WrappedBuilder<[string, number]>;
}

@Entry
@Component
struct TestBuilderIndex {
  @State message: string = 'Hello World';
  @State builderObj: BuilderModel = { globalBuilder: wrapBuilder(myBuilderFirst) };

  aboutToAppear(): void {
    setTimeout(() => {
      // wrapBuilder(myBuilderSecond) 不会生效
      this.builderObj.globalBuilder = wrapBuilder(myBuilderSecond);
    }, 1000);
  }

  build() {
    Row() {
      Column() {
        this.builderObj.globalBuilder.builder(this.message, 20)
      }
      .width('100%')
    }
    .height('100%')
  }
}
```
