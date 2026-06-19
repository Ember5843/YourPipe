# Overview of ArkTS Inter-Thread Communication
<!--Kit: ArkTS-->
<!--Subsystem: CommonLibrary-->
<!--Owner: @wang_zhaoyong-->
<!--Designer: @weng-changcheng-->
<!--Tester: @kirl75; @zsw_zhushiwei-->
<!--Adviser: @ge-yafang-->

Inter-thread communication involves the exchange of data between concurrent threads. Given that ArkTS is compatible with TS/JS, its runtime is implemented using the actor model with memory isolation, similar to other JS engines.

The behavior of inter-thread communication in ArkTS varies depending on the type of data object involved. For instance, regular JS objects, ArrayBuffer objects, and SharedArrayBuffer objects each exhibit different behaviors, including serialization and deserialization, data transfer, and data sharing.

Taking JS objects as an example, inter-thread communication uses the standard Structured Clone algorithm for serialization and deserialization. This process involves converting JS objects into engine-independent data (such as strings or memory blocks) and then restoring them into new objects with the same content in another concurrent task. This typically requires deep copying, which can be less efficient. In addition to standard JS serialization and deserialization, ArkTS supports the transfer of native JS object and the sharing of [Sendable objects](arkts-sendable.md).

Currently, ArkTS provides two concurrency capabilities for inter-thread communication: TaskPool and Worker.

- Worker is the standard API for cross-thread communication in the actor model. Its usage patterns are similar to those of Web Worker or Node.js Worker.

- TaskPool provides a more powerful and user-friendly API for concurrent programming. The behavior of object passing across concurrent tasks in TaskPool is consistent with that of Worker, utilizing the standard Structured Clone algorithm. The time required for concurrent communication increases with the size of the objects involved.

Leveraging the TaskPool and Worker concurrency APIs, ArkTS supports a variety of inter-thread communication capabilities to satisfy different development needs in inter-thread communication scenarios. For example, [independent time-consuming tasks](independent-time-consuming-task.md), [multiple time-consuming tasks](multi-time-consuming-tasks.md), [communication between the TaskPool task and host thread](taskpool-communicates-with-mainthread.md), [real-time communication between the Worker thread and host thread](worker-communicates-with-mainthread.md), and [synchronous calls to host thread interfaces from Worker](worker-invoke-mainthread-interface.md). In addition, ArkTS supports cross-thread calls to ArkTS APIs from C++ threads, based on the mechanisms provided by [Node-API](../napi/napi-introduction.md).

Figure 1 Serialization and deserialization principles

![image_0000002017033808](figures/image_0000002017033808.png)
