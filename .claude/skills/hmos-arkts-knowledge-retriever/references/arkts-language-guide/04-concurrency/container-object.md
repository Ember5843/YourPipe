# Container Object
<!--Kit: ArkTS-->
<!--Subsystem: CommonLibrary-->
<!--Owner: @wang_zhaoyong-->
<!--Designer: @weng-changcheng-->
<!--Tester: @kirl75; @zsw_zhushiwei-->
<!--Adviser: @ge-yafang-->

Container objects can be serialized to ensure content consistency between threads, enabling inter-thread data transfer.

Currently, the [TreeSet](../reference/apis-arkts/js-apis-treeset.md) object supports serialization.

> **NOTE**
>
> - Since API version 22, TreeSet can be used for cross-thread data transfer.
> 
> - When passing container objects across threads, only data can be transmitted, and custom methods will be lost. If custom methods are required, you need to mark them as Sendable functions using the [@Sendable decorator](arkts-sendable.md#sendable-decorator), after which the custom methods can be passed across threads.

## Example

<!-- @[example_container_obj](https://gitcode.com/openharmony/applications_app_samples/blob/master/code/DocsSample/ArkTS/ArkTsConcurrent/ConcurrentThreadCommunication/InterThreadCommunicationObjects/CommunicationObjects/entry/src/main/ets/managers/ContainerObject.ets) -->

``` TypeScript
import { taskpool, TreeSet } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

@Sendable
function sendableCompareFunc(firstValue: number, secondValue: number): boolean {
    return firstValue > secondValue;
}

@Concurrent
function treeSetTestFunc(treeSet: TreeSet<number>) {
  for (let value of treeSet) {
    console.info('value:', value);
  }
}

@Entry
@Component
struct Index {
  @State message: string = 'Hello World';

  build() {
    RelativeContainer() {
      Text(this.message)
        .id('HelloWorld')
        .fontSize(50)
        .fontWeight(FontWeight.Bold)
        .alignRules({
          center: { anchor: '__container__', align: VerticalAlign.Center },
          middle: { anchor: '__container__', align: HorizontalAlign.Center }
        })
        .onClick(() => {
          // 1. Create a test instance objA.
          let treeSet: TreeSet<number> = new TreeSet<number>(sendableCompareFunc);

          treeSet.add(1);
          treeSet.add(5);
          treeSet.add(3);
          treeSet.add(2);
          // 2. Create a task and transfer treeSet to the task. The task is transferred to the child thread through serialization.
          let task = new taskpool.Task(treeSetTestFunc, treeSet);
          // 3. Execute the task.
          taskpool.execute(task).then(() => {
            console.info('taskpool: execute task success!');
          }).catch((e: BusinessError) => {
            console.error(`taskpool: execute task: Code: ${e.code}, message: ${e.message}`);
          })
          this.message = 'success';
        })
    }
    .height('100%')
    .width('100%')
  }
}
```
