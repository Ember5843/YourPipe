# Error Handling

Handle failures with `throw`, `try`, `catch`, and `finally`.

Even well-structured programs encounter failures: invalid input, unavailable resources, impossible states, and rejected asynchronous work. ArkTS models these situations with exceptions based on `Error` objects. Compared with JavaScript, ArkTS uses a stricter and more explicit style for thrown values and error-handling examples.

Good error handling is not about catching everything. It is about deciding which failures are exceptional, where they should be handled, and how much information callers need in order to respond correctly.

## Throwing Errors

Use `throw` to stop normal execution and report a failure:

```typescript
function divide(a: number, b: number): number {
  if (b === 0) {
    throw new Error('Division by zero');
  }
  return a / b;
}
```

Throw an error when the function cannot continue meaningfully.

In ArkTS, `throw` must use `Error` or a derived class. Do not throw arbitrary values such as strings or numbers.

Typical reasons to throw include:

- invalid arguments
- impossible internal state
- missing required resources
- failures that the current function cannot resolve locally

## When to Throw and When Not to Throw

Not every unusual situation should become an exception.

Throw when:

- the operation cannot produce a valid result
- continuing would leave the program in a bad state
- the caller needs to decide how to recover

Do not throw when:

- the condition is an ordinary branch in normal logic
- returning a boolean, enum, or nullable value is clearer
- the absence of data is expected and routine

For example, these are often better modeled without exceptions:

```typescript
function findFirst(items: string[]): string | null {
  if (items.length === 0) {
    return null;
  }
  return items[0];
}
```

This is normal control flow, not exceptional failure.

## Catching Errors

Wrap code in a `try` block when it may throw:

```typescript
try {
  console.info(divide(10, 0));
} catch (error) {
  console.info('Operation failed');
}
```

The `catch` block runs only when an exception escapes from the `try` block.

In ArkTS, keep the `catch` parameter untyped. Patterns such as `catch (error: unknown)` or `catch (error: any)` are not used in ArkTS examples.

Catch errors where the program can actually do something useful, such as:

- retrying
- reporting a clearer message
- returning a fallback
- cleaning up state before rethrowing

## `finally`

Use `finally` for cleanup that must happen whether or not an error occurs:

```typescript
function loadConfig(): void {
  console.info('Open resource');
  try {
    console.info('Read config');
  } finally {
    console.info('Close resource');
  }
}
```

Typical `finally` work includes:

- releasing resources
- resetting temporary state
- stopping timers
- writing final diagnostics

`finally` is about cleanup, not normal result handling.

Do not use `return`, `throw`, `break`, or `continue` inside `finally`. Those statements can hide the original control flow or replace an exception that should keep propagating.

## Custom Error Types

Create a class derived from `Error` when the program benefits from a more specific failure category:

```typescript
class ValidationError extends Error {
  constructor(message: string) {
    super(message);
  }
}
```

Custom error classes make it easier to:

- organize failure handling
- communicate intent
- distinguish one failure category from another

Another example:

```typescript
class ConfigError extends Error {
  constructor(message: string) {
    super(message);
  }
}
```

Use specific error classes when callers should react differently to different kinds of failure.

They are also useful in `catch` blocks:

```typescript
function requireName(name: string | null): string {
  if (name === null || name.trim().length === 0) {
    throw new ValidationError('Name is required');
  }
  return name;
}

try {
  requireName(null);
} catch (error) {
  if (error instanceof ValidationError) {
    console.info(error.message);
  } else {
    throw error as Error;
  }
}
```

## Validating Inputs

Throwing is common in validation code:

```typescript
function requireName(name: string | null): string {
  if (name === null || name.trim().length === 0) {
    throw new ValidationError('Name is required');
  }
  return name;
}
```

This keeps invalid data from silently spreading through the program.

Constructor validation often follows the same pattern:

```typescript
class CheckedPercentage {
  value: number;

  constructor(value: number) {
    if (value < 0 || value > 100) {
      throw new ValidationError('Percentage must be between 0 and 100');
    }
    this.value = value;
  }
}
```

## Re-throwing and Translating Errors

Sometimes one layer catches an error and raises a more domain-specific one:

```typescript
function parsePort(text: string): number {
  let value: number = Number.parseInt(text, 10);
  if (Number.isNaN(value) || value <= 0) {
    throw new ValidationError('Port must be positive');
  }
  return value;
}
```

A higher-level API may choose to translate a low-level failure into a more meaningful one:

```typescript
class StartupError extends Error {
  constructor(message: string) {
    super(message);
  }
}
```

This is useful when lower-level details are not helpful to the caller and the API should expose a clearer abstraction:

```typescript
function readPort(text: string): number {
  try {
    return parsePort(text);
  } catch (error) {
    if (error instanceof ValidationError) {
      throw new StartupError(`Invalid startup configuration: ${error.message}`);
    }
    throw error as Error;
  }
}
```

## Error Handling in Async Code

`async` functions can use `try` and `catch` around awaited operations:

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

The same control-flow ideas apply; only the source of the failure changes.

If an awaited promise rejects, control moves to the nearest surrounding `catch` just like with synchronous exceptions.

This chapter focuses on `try`/`catch` around `await`. For Promise callback styles such as `.catch()` and `.finally()`, see the concurrency chapter.

## Error Messages and API Design

Good error messages should help a caller or developer understand:

- what failed
- why it failed
- what input or state caused the problem

For example:

```typescript
function requirePositive(value: number): number {
  if (value <= 0) {
    throw new Error(`Expected a positive number, got ${value}`);
  }
  return value;
}
```

Specific messages are usually more useful than vague ones like `"Invalid input"`.

## Design Guidelines

Keep error handling useful and predictable:

- throw when normal execution cannot continue
- use clear error messages
- prefer specific error types over vague failures
- catch errors where the program can actually respond
- keep cleanup logic in `finally` when it must always run

Do not catch an error only to hide it or ignore it unless that behavior is intentional and documented.

Likewise, do not use exceptions for ordinary branching when a return value would be simpler.

## ArkTS Restrictions That Affect Error Handling

ArkTS applies stricter rules than JavaScript and TypeScript:

- `throw` must use `Error` or a derived class
- do not annotate the `catch` variable type
- avoid `any`-based error flows

### Throw `Error` Objects, Not Arbitrary Values

This is valid ArkTS style:

```typescript
throw new Error('Configuration is missing');
```

Do not teach patterns like:

```typescript
// Avoid JavaScript-style patterns such as:
// throw 'bad';
// throw 404;
```

Throwing arbitrary values such as strings or numbers should not be taught as ArkTS code. Use `Error` objects so failure paths stay structured and understandable.

### Do Not Type-Annotate the `catch` Variable

Keep `catch` simple:

```typescript
try {
  requireName(null);
} catch (error) {
  console.info('Validation failed');
}
```

Do not add a type annotation to the `catch` variable in ArkTS examples.

If you need more specific error information, narrow with `instanceof` or use a type assertion after entering the `catch` block.

### Keep `finally` Focused on Cleanup

Use `finally` to release resources and restore state, not to change the outcome of the `try` statement.

Avoid patterns like this:

```typescript
function finish(): number {
  try {
    return 1;
  } finally {
    return 2;
  }
}
```

The `return` in `finally` replaces the earlier result. Similar problems occur with `throw`, `break`, and `continue`.

These restrictions reinforce a more disciplined exception model: exceptions are explicit, structured, and tied to real failure states.

For control flow shaped by exceptions, see `control-flow.md`. For async error propagation, see `async-concurrency-overview.md`.
