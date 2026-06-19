# Concurrency

Coordinate asynchronous work with `Promise`, `async`, and `await`.

Many tasks do not finish immediately. Fetching data, waiting for I/O, and scheduling later work all introduce asynchrony. At the language level, ArkTS handles these cases with promises and asynchronous functions. This chapter focuses on those core syntax features and does not cover the worker, task pool, or sendable-object model from `04-Concurrency`.

The goal of language-level concurrency is not to make code "parallel" by magic. The goal is to represent delayed results clearly, compose asynchronous operations safely, and keep failure handling close to the operations that can fail.

In this chapter, "concurrency" means coordinating asynchronous work. It does not mean that your code directly controls threads. When an `await` suspends one async function, the whole program does not stop. Only the code path that depends on that awaited result pauses, while other work can continue.

## Promises

A `Promise<T>` represents a value that will become available later:

```typescript
function loadName(): Promise<string> {
  return Promise.resolve('ArkTS');
}
```

The type parameter `T` tells you what the promise will eventually resolve to.

Promises are useful because they let a function describe future completion explicitly:

- `Promise<string>` means "a string later"
- `Promise<number>` means "a number later"
- `Promise<void>` means "completion later, no meaningful value"

## Creating a Promise

Most code consumes promises returned by APIs, but it is also useful to know how a promise is created:

```typescript
function waitAndLoadName(): Promise<string> {
  return new Promise<string>((resolve, reject) => {
    let loaded: boolean = true;

    if (loaded) {
      resolve('ArkTS');
    } else {
      reject(new Error('Could not load name'));
    }
  });
}
```

The executor passed to `new Promise<T>(...)` receives two functions:

- `resolve(value)` completes the promise successfully
- `reject(error)` completes the promise with failure

Prefer this constructor when you need to wrap an older callback-based API or explicitly describe how asynchronous completion happens.

## Consuming a Promise with `then`

Use `then()` to continue after a promise resolves:

```typescript
loadName().then((name: string): void => {
  console.info(name);
});
```

This is the most direct promise style and is useful when the continuation is short.

`then()` is a good fit when:

- the continuation is small
- the code is already promise-based
- you want a fluent chain of async transformations

## Chaining

`then()` returns a new promise, which allows sequential composition:

```typescript
function uppercasedName(): Promise<string> {
  return loadName().then((name: string): string => {
    return name.toUpperCase();
  });
}
```

Each step receives the previous step's resolved value.

Another example:

```typescript
function nameLength(): Promise<number> {
  return loadName().then((name: string): number => {
    return name.length;
  });
}
```

This pattern is useful when one asynchronous step transforms the result of another.

If a `then()` callback starts another asynchronous operation, return that promise so the chain remains connected:

```typescript
function loadGreeting(): Promise<string> {
  return loadName().then((name: string): Promise<string> => {
    return Promise.resolve(`Hello, ${name}`);
  });
}
```

Returning the promise keeps sequencing and error handling correct. The next step waits for the returned promise to settle.

## Avoid Floating Promises

Do not start async work inside `then()` and then forget to return it:

```typescript
function badLoadGreeting(): Promise<void> {
  return loadName()
    .then((name: string): void => {
      Promise.resolve(`Hello, ${name}`).then((message: string): void => {
        console.info(message);
      });
    })
    .then((): void => {
      console.info('Done');
    });
}
```

In this example, the inner promise is detached from the outer chain. The final `then()` may run before the inner work finishes. This kind of detached async work is often called a floating promise.

Prefer a flat chain:

```typescript
function goodLoadGreeting(): Promise<void> {
  return loadName()
    .then((name: string): Promise<string> => {
      return Promise.resolve(`Hello, ${name}`);
    })
    .then((message: string): void => {
      console.info(message);
    })
    .then((): void => {
      console.info('Done');
    });
}
```

## Creating Async Functions

An `async` function always returns a promise:

```typescript
async function loadCount(): Promise<number> {
  return 3;
}
```

Even when the function appears to return a plain value, the actual result type is `Promise<number>` here.

Use `async` when:

- the function awaits other promises
- the implementation should read like sequential code
- failure handling should use `try` and `catch`

## Using `await`

Inside an `async` function, `await` pauses until a promise resolves:

```typescript
async function printName(): Promise<void> {
  let name: string = await loadName();
  console.info(name);
}
```

`await` often makes asynchronous code easier to read because the steps appear in execution order.

Another example:

```typescript
async function printUppercaseName(): Promise<void> {
  let name: string = await loadName();
  console.info(name.toUpperCase());
}
```

This style is often clearer than nesting several `then()` callbacks.

An `await` only suspends the current async function. It does not block the entire program.

## Where `await` Can Appear

Use `await` only inside an `async` function:

```typescript
async function readName(): Promise<string> {
  return await loadName();
}
```

This is not valid in a synchronous function:

```typescript
function readNameLater(): Promise<string> {
  return loadName();
}
```

The synchronous function above is fine because it returns a `Promise<string>`, but it cannot use `await` directly. Mark the function `async` when the implementation needs awaited values.

## Sequential Async Work

Use `await` directly when later work depends on earlier results:

```typescript
async function printSummary(): Promise<void> {
  let name: string = await loadName();
  let count: number = await loadCount();
  console.info(`${name}: ${count}`);
}
```

This style is clear when one operation logically follows another.

Sequential waiting is the right choice when:

- the second step needs the first step's result
- the operations describe a step-by-step workflow
- readability matters more than maximizing overlap

## Running Independent Work Together

If several asynchronous tasks are independent, run them together with `Promise.all()`:

```typescript
async function loadSummary(): Promise<void> {
  let results: [string, number] = await Promise.all([
    loadName(),
    loadCount()
  ]);

  console.info(`${results[0]}: ${results[1]}`);
}
```

This avoids waiting longer than necessary.

Use `Promise.all()` when:

- the tasks do not depend on each other
- all results are needed before continuing
- the code should wait for every operation to finish successfully

This is one of the simplest ways to express useful concurrency at the language level.

If any promise inside `Promise.all()` rejects, the combined promise rejects immediately. The other operations may still continue running, but their results are not returned through that `Promise.all()` call.

## Returning Values from Async Functions

An async function can compute and return a value after awaiting other operations:

```typescript
async function resolvedNameLength(): Promise<number> {
  let name: string = await loadName();
  return name.length;
}
```

The caller still receives a promise:

```typescript
resolvedNameLength().then((length: number): void => {
  console.info(length);
});
```

This makes async functions compose naturally with both `await` and promise chains.

## Rejected Promises and Failed Async Functions

A promise may complete with failure instead of success:

```typescript
function loadUserName(id: number): Promise<string> {
  if (id <= 0) {
    return Promise.reject(new Error('Invalid user id'));
  }
  return Promise.resolve('ArkTS');
}
```

An `async` function produces the same kind of failure if it throws an `Error`:

```typescript
async function requirePositiveId(id: number): Promise<number> {
  if (id <= 0) {
    throw new Error('Invalid user id');
  }
  return id;
}
```

In ArkTS, throw only `Error` objects or derived error types. Do not throw raw strings, numbers, or other arbitrary values.

## Handling Errors in Async Code

A rejected promise behaves like an exception when awaited:

```typescript
async function showResult(task: Promise<string>): Promise<void> {
  try {
    let result: string = await task;
    console.info(result);
  } catch (error) {
    console.info('Async operation failed');
  }
}
```

This keeps async error handling close to synchronous `try`/`catch`.

If an awaited promise rejects, control moves to the nearest surrounding `catch` just like with synchronous exceptions.

This means the following failure paths fit the same model:

- `reject(new Error(...))` rejects a promise
- `return Promise.reject(new Error(...))` returns a rejected promise
- `throw new Error(...)` inside an `async` function creates a rejected promise

## Promise Rejections with `catch`

You can also handle errors directly on the promise chain:

```typescript
loadName()
  .then((name: string): void => {
    console.info(name);
  })
  .catch((error): void => {
    console.info('Promise failed');
  });
```

This is useful when writing a fluent promise chain or when the surrounding code is not itself `async`.

Use `catch()` when:

- the code already uses chained `then()`
- the error handling belongs at the end of the chain
- converting to `async`/`await` would not improve clarity

After a `catch()`, the chain can continue:

```typescript
loadUserName(-1)
  .catch((error): string => {
    return 'Anonymous';
  })
  .then((name: string): void => {
    console.info(name);
  });
```

This is useful when the program can recover with a fallback value and continue the next step with ordinary data.

## Choosing Between `then` and `await`

Both styles are valid. Choose the one that makes the flow easiest to understand.

Prefer `await` when:

- the code is sequential
- several dependent steps appear in order
- `try`/`catch` is the clearest error-handling style

Prefer `then()` when:

- the continuation is very short
- the code already forms a promise chain
- you are exposing a transformed promise directly

For example, this is often clear and compact:

```typescript
function lowercasedName(): Promise<string> {
  return loadName().then((name: string): string => {
    return name.toLowerCase();
  });
}
```

## Practical Async Patterns

### Fetch-Then-Transform

```typescript
async function printNameLength(): Promise<void> {
  let name: string = await loadName();
  console.info(name.length);
}
```

### Wait for Multiple Results

```typescript
async function printCombined(): Promise<void> {
  let values: [string, number] = await Promise.all([
    loadName(),
    loadCount()
  ]);

  console.info(`${values[0]} / ${values[1]}`);
}
```

### Handle Failure Near the Await

```typescript
async function safePrint(task: Promise<string>): Promise<void> {
  try {
    console.info(await task);
  } catch (error) {
    console.info('Could not print result');
  }
}
```

These patterns cover most day-to-day asynchronous code in a readable way.

## What to Avoid

Avoid patterns that make async control flow harder to reason about:

- forgetting to return a promise from a `then()` callback
- forgetting `await` when later code needs the resolved value
- mixing deeply nested `then()` chains with `async`/`await` in the same small function
- swallowing failures without an intentional recovery path

Keep promise chains flat unless nested error scope is the point.

## Design Guidelines for Async Code

Prefer:

- explicit `Promise<T>` return types
- short and focused async functions
- `try` and `catch` around awaited operations that may fail
- `Promise.all()` for independent work
- one async style per example unless the comparison is the point

Avoid:

- mixing many async styles in one small function
- deeply nested promise callbacks
- hiding important errors
- starting async work without making its completion path visible

## ArkTS Boundaries for This Chapter

This chapter intentionally covers only language-level asynchronous programming:

- `Promise`
- `then`
- `catch`
- `async`
- `await`

It does not cover:

- worker threads
- task pools
- sendable types
- inter-thread communication

Those topics belong to the dedicated guides in `../04-Concurrency/`.

ArkTS also does not use generator functions as a substitute for async flow. Prefer `async`/`await` and ordinary promises for multitasking-style code.

For error propagation in async code, see `error-handling.md`. For control flow around async branches, see `control-flow.md`.
